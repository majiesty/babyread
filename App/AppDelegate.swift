import UIKit
import WebKit
import AVFoundation
import Speech

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        // 朗读要能绕过静音键：用 playback 通道，孩子上课时不会被静音开关掐掉
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                           options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 忽略：拿不到音频会话也不影响界面
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var recRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var srPendingAlts: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(red: 0.929, green: 0.965, blue: 0.933, alpha: 1.0)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // 原生桥：WKWebView 不支持 Web Speech API，朗读/识别都走原生
        config.userContentController.add(NativeBridge(owner: self), name: "native")
        synthesizer.delegate = self

        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.bounces = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView = web

        // 宝宝学的时候别让屏幕自动熄灭
        UIApplication.shared.isIdleTimerDisabled = true

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") else {
            showFallback("找不到 www/index.html，请检查打包时资源是否包含在 App 内。")
            return
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// 页面加载完注入原生桥映射（与安卓壳同名的 AndroidTTS / AndroidSR）
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
        try{
          window.AndroidTTS={speak:function(t,r,p){window.webkit.messageHandlers.native.postMessage({cmd:'tts',text:String(t),rate:Number(r)||1,pitch:Number(p)||1})},stop:function(){window.webkit.messageHandlers.native.postMessage({cmd:'ttsStop'})}};
          window.AndroidSR={listen:function(){window.webkit.messageHandlers.native.postMessage({cmd:'sr'})},stop:function(){window.webkit.messageHandlers.native.postMessage({cmd:'srStop'})}};
        }catch(e){}
        """, completionHandler: nil)
    }

    // MARK: - 原生 TTS

    func nativeSpeak(text: String, rate: Double, pitch: Double) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: text.contains("。") || text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil ? "zh-CN" : "en-US")
        u.rate = Float(max(0.35, min(0.62, rate * 0.55)))
        u.pitchMultiplier = Float(max(0.5, min(2.0, pitch)))
        u.volume = 1.0
        synthesizer.speak(u)
    }

    func nativeStopTTS() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - 原生语音识别（en-US）

    func nativeListen() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            sendSR(["error": "broken"])
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard auth == .authorized else { self.sendSR(["error": "broken"]); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.beginRecognition() } else { self.sendSR(["error": "broken"]) }
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        finishRecognition(send: false)
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) }
        guard let rec = recognizer, rec.isAvailable else { sendSR(["error": "broken"]); return }

        recRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recRequest else { sendSR(["error": "broken"]); return }
        req.shouldReportPartialResults = true

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recRequest?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            sendSR(["error": "broken"]); return
        }
        srPendingAlts = []
        recTask = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let r = result {
                self.srPendingAlts = r.transcriptions.map { $0.formattedString }
                if r.isFinal { self.finishRecognition(send: true) }
            } else if error != nil {
                self.finishRecognition(send: false)
            }
        }
    }

    func nativeStopSR() {
        recRequest?.endAudio()
        finishRecognition(send: true)
    }

    private func finishRecognition(send: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recRequest = nil
        recTask?.cancel()
        recTask = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        } catch {}
        if send {
            let alts = srPendingAlts
            sendSR(alts.isEmpty ? ["error": "no_match"] : ["alts": alts])
        }
        srPendingAlts = []
    }

    private func sendSR(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("typeof window.__nativeSR==='function'&&window.__nativeSR(\(json))", completionHandler: nil)
    }

    private func jsTTS(_ type: String) {
        webView?.evaluateJavaScript("typeof window.__nativeTTS==='function'&&window.__nativeTTS({type:'\(type)'})", completionHandler: nil)
    }

    private func showFallback(_ text: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(red: 0.45, green: 0.30, blue: 0.24, alpha: 1)
        label.font = UIFont.systemFont(ofSize: 17)
        label.text = text
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8)
        ])
    }

    // MARK: - 状态栏 / 方向

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var shouldAutorotate: Bool { true }

    // MARK: - 麦克风授权（iOS 15+ 必须显式同意，否则网页拿不到麦克风）

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // 外链一律留在 App 内，避免跳出到 Safari
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}

extension WebViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        jsTTS("start")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        jsTTS("end")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        jsTTS("end")
    }
}

/// 桥消息分发：网页 postMessage → 原生 TTS / SR
final class NativeBridge: NSObject, WKScriptMessageHandler {
    private weak var owner: WebViewController?

    init(owner: WebViewController) {
        self.owner = owner
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "tts":
            owner?.nativeSpeak(text: body["text"] as? String ?? "",
                               rate: body["rate"] as? Double ?? 1.0,
                               pitch: body["pitch"] as? Double ?? 1.0)
        case "ttsStop":
            owner?.nativeStopTTS()
        case "sr":
            owner?.nativeListen()
        case "srStop":
            owner?.nativeStopSR()
        default:
            break
        }
    }
}
