import UIKit
import WebKit
import AVFoundation
import Speech

/// 崩溃日志：写到沙盒 Documents，便于排查闪退（不会被系统清理）
enum CrashLog {
    static func write(_ s: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("babyread-crash.log")
        let line = "\(Date()) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        // 未捕获的 ObjC 异常先落盘，便于定位闪退（进程仍会结束，但留下线索）
        NSSetUncaughtExceptionHandler { ex in
            CrashLog.write("NSException \(ex.name.rawValue): \(ex.reason ?? "-")")
        }

        // 朗读要能绕过静音键：用 playback 通道，孩子上课时不会被静音开关掐掉
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                           options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            CrashLog.write("audio session init: \(error)")
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

    // 语音识别：录音文件 + 事后识别（不用 AVAudioEngine，避免 installTap 抛 ObjC 异常闪退）
    private var recognizer: SFSpeechRecognizer?
    private var recorder: AVAudioRecorder?
    private var recTask: SFSpeechRecognitionTask?
    private var recURL: URL?
    private var listenTimer: Timer?
    private let maxListenSeconds: TimeInterval = 6.0

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
        // 新的朗读打断旧的，避免排队卡住
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
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

    // MARK: - 原生语音识别（en-US，录音 → 识别）

    func nativeListen() {
        cancelListening(notify: false)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            CrashLog.write("sr session: \(error)")
            sendSR(["error": "broken"])
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard auth == .authorized else {
                    self.restorePlaybackSession()
                    self.sendSR(["error": "denied"])
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.restorePlaybackSession()
                            self.sendSR(["error": "denied"])
                            return
                        }
                        self.startRecording()
                    }
                }
            }
        }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else {
                throw NSError(domain: "babyread", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "record() returned false"])
            }
            recorder = r
            recURL = url
            listenTimer?.invalidate()
            listenTimer = Timer.scheduledTimer(withTimeInterval: maxListenSeconds, repeats: false) { [weak self] _ in
                self?.nativeStopSR()
            }
        } catch {
            CrashLog.write("sr record: \(error)")
            restorePlaybackSession()
            sendSR(["error": "broken"])
        }
    }

    func nativeStopSR() {
        listenTimer?.invalidate()
        listenTimer = nil
        guard let rec = recorder else { return }
        recorder = nil
        rec.stop()
        guard let url = recURL else {
            restorePlaybackSession()
            sendSR(["error": "no_match"])
            return
        }
        recURL = nil
        transcribe(url)
    }

    private func transcribe(_ url: URL) {
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let rec = recognizer, rec.isAvailable else {
            restorePlaybackSession()
            sendSR(["error": "broken"])
            try? FileManager.default.removeItem(at: url)
            return
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false

        var finished = false
        let finish: ([String]) -> Void = { [weak self] alts in
            guard let self = self else { return }
            finished = true
            self.recTask?.cancel()
            self.recTask = nil
            self.restorePlaybackSession()
            self.sendSR(alts.isEmpty ? ["error": "no_match"] : ["alts": alts])
            try? FileManager.default.removeItem(at: url)
        }

        recTask = rec.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                if let r = result {
                    let alts = r.transcriptions.map { $0.formattedString }
                    if r.isFinal || !alts.isEmpty { finish(alts) }
                } else if error != nil {
                    finish([])
                }
            }
        }
        // 识别超时保护：8 秒没结果按"没听清"处理，页面不会卡住
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !finished { finish([]) }
        }
    }

    private func cancelListening(notify: Bool) {
        listenTimer?.invalidate()
        listenTimer = nil
        if let r = recorder { r.stop() }
        recorder = nil
        recTask?.cancel()
        recTask = nil
        if let u = recURL { try? FileManager.default.removeItem(at: u) }
        recURL = nil
        if notify { sendSR(["error": "no_match"]) }
    }

    private func restorePlaybackSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                           options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            CrashLog.write("session restore: \(error)")
        }
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
    // 与安卓版一致：横屏启动、锁定横屏（左右两个方向都允许）
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
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
