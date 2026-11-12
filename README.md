# 宝宝启蒙跟读 · iOS 打包（巨魔 / TrollStore 可装）

这个文件夹是一个**完整的 iOS 工程**，里面已经内置了全部网页（`App/www/index.html`）。
它会被编译成一个独立的 iPad / iPhone 应用：全屏、有图标、离线可用、支持麦克风授权。

## 为什么不能直接给你一个 ipa

ipa 里的可执行文件必须是 macOS + Xcode 编译出来的 arm64 程序，Windows 上没有这个编译链，
所以在本地没法直接产出 ipa。下面两条路都能拿到 ipa，任选其一。

## 方式一：GitHub 云端编译（不需要 Mac，推荐）

1. 注册 / 登录 [github.com](https://github.com)，右上角 **＋ → New repository** 新建仓库（Public 免费即可）。
2. 把本文件夹里的全部内容（包括隐藏的 `.github` 文件夹）上传到仓库：
   - 最省事：装 GitHub Desktop，把 `ios-app` 文件夹拖进去提交推送；
   - 或命令行：
     ```bash
     cd ios-app
     git init && git add -A && git commit -m "babyread"
     git branch -M main
     git remote add origin https://github.com/你的用户名/babyread.git
     git push -u origin main
     ```
3. 打开仓库页面 → **Actions** 标签 → 左侧 `build-ipa` → 右上 **Run workflow** → 等待约 3~5 分钟变绿。
4. 点进这次运行 → 底部 **Artifacts** 下载 `BabyRead-ipa`，解压得到 `BabyRead.ipa`。
5. 把 ipa 传到 iPad（AirDrop / 微信 / 网盘都行）→ 分享 → **TrollStore（巨魔）打开安装**。
   巨魔会自动完成永久签名，图标是一只绿底小猫。

## 方式二：有 Mac 的话

```bash
brew install xcodegen
cd ios-app
xcodegen generate
open BabyRead.xcodeproj
# Xcode 里选真机 → Product → Build；产物在 DerivedData/Build/Products/Release-iphoneos/BabyRead.app
# 打包 ipa：
mkdir Payload && cp -R BabyRead.app Payload/ && zip -r BabyRead.ipa Payload
```

## 更新网页内容

网页就一个文件：`App/www/index.html`（就是「宝宝启蒙跟读.html」的改名版）。
以后我更新了网页，把它覆盖成 `App/www/index.html`，重新跑一次编译即可。

## 常见问题

- **装上后图标是猫，打开白屏几秒**：正常，首次启动在加载内置网页。
- **自动判分（麦克风）**：App 已申请麦克风与语音识别权限（第一次跟读时系统会弹窗，请点允许）。
  WKWebView 内的网页语音识别在部分 iOS 版本上受限；如果识别不可用，应用会自动切到
  「家长放行 / 对比听」，不影响练习。
- **声音**：App 用 `AVAudioSession.playback` 播放，**静音键打开也会有声音**，适合宝宝学习。
- **屏幕**：学习期间不会自动锁屏；全屏无状态栏。
