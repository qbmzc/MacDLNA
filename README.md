# MacDLNA - macOS 原生无依赖 DLNA 数字媒体音频接收器 (DMR)

**MacDLNA** 是一个运行在 macOS 菜单栏（Status Bar）的原生轻量级 DLNA 音频接收器（Digital Media Renderer, DMR）。
支持接收来自 Android 手机音乐应用（网易云音乐、QQ音乐、BubbleUPnP、Symfonium 等）或局域网控制点投送的无损及高清音频流，并在 Mac 上原生高保真播放。

---

## ✨ 核心特性

- **零外部第三方依赖 (Zero Dependencies)**：全部采用 macOS 系统原生系统级框架（Darwin POSIX BSD Sockets、Network.framework、AVFoundation、MediaPlayer、SwiftUI、AppKit）。
- **无完整 Xcode.app 限制**：完全支持仅安装 `Xcode Command Line Tools` 的纯命令行环境构建，采用标准 Swift Package Manager (`swift build`)。
- **纯粹的状态栏应用**：通过 `LSUIElement` 及 `NSApplication.shared.setActivationPolicy(.accessory)` 运行在菜单栏，不占用 Dock 栏空间。
- **原生系统音频与媒体中心集成**：
  - 基于 `AVPlayer` 与 `AVPlayerItem` 的流式播放引擎。
  - 深度集成 macOS 媒体中心 (`MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter`)，支持系统键盘多媒体控制键（播放/暂停/上一曲/下一曲）与控制中心媒体面板同步展示封面及元数据。
- **实时同步歌词与交互式跳转 (Lyrics)**：
  - **双重解析机制**：优先解析手机 DLNA 投送包内的歌词数据（支持 Base64 与内联 LRC）；若手机投送未携带歌词，系统自动根据歌曲名与艺术家进行毫秒级在线智能检索匹配。
  - **Apple Music 同款卡拉OK滚动面板**：当前播放行自动放大、高亮与居中滚动。
  - **点击歌词点播跳转**：在歌词面板中点击任意一行歌词，播放器将毫秒级精准 Seek 到该歌词对应的时间戳。
- **高兼容性 UPnP/DLNA 协议栈**：
  - **SSDP 服务**：基于 Darwin BSD Socket 监听 `239.255.255.250:1900`，支持多播 Alive 宣告、Byebye 宣告以及对 `M-SEARCH`（支持 `ssdp:all`、`upnp:rootdevice`、`MediaRenderer:1` 等）的单播即时响应。
  - **HTTP/SOAP 控制**：实现轻量高效的 HTTP 服务（默认端口 8585），提供完整的 `description.xml` 设备描述及 `AVTransport`、`RenderingControl`、`ConnectionManager` 三大核心服务的 SCPD 规范。
  - **DIDL-Lite 元数据全自动解析**：自动解析手机投送的歌曲名、艺术家、专辑名，并异步下载渲染高清专辑封面。
- **自适应网络网卡识别**：智能遍历网卡，自动过滤 `127.0.0.1`、`utun*` (VPN)、`awdl*`、`bridge*` 等虚拟接口，精准绑定主 Wi-Fi / 有线网络真实 IPv4。

---

## 📂 项目结构

```text
MacDLNA/
├── Package.swift               # SPM 项目定义文件 (macOS 13.0+)
├── build_app.sh                # 自动编译并封装为 MacDLNA.app 的脚本
├── README.md                   # 项目使用与架构说明
└── Sources/
    └── MacDLNA/
        ├── MacDLNAApp.swift      # @main 入口，MenuBarExtra 状态栏与卡片视图
        ├── NetworkUtils.swift    # 获取本机局域网真实 IPv4 地址 (过滤虚拟网卡)
        ├── SSDPService.swift     # Darwin BSD UDP 239.255.255.250:1900 组播、M-SEARCH 与 Alive
        ├── UPnPXMLTemplates.swift# description.xml 及三大核心服务 SCPD 静态模板
        ├── UPnPHTTPServer.swift  # Network 框架 HTTP Server、SOAP Action 路由与解析
        └── AudioEngine.swift     # AVPlayer 播放引擎、DIDL-Lite 解析与系统媒体中心同步
```

---

## 🚀 编译与构建

在当前项目目录下，直接执行提供的打包脚本：

```bash
chmod +x build_app.sh
./build_app.sh
```

脚本将自动执行：
1. `swift build -c release` 编译优化二进制程序；
2. 构造 `MacDLNA.app` 标准 Bundle 结构；
3. 生成配置了 `LSUIElement`、`NSAppTransportSecurity` 与局域网权限的 `Info.plist`；
4. 执行本地 Ad-Hoc 代码签名。

---

## 💻 运行方式

### 方式一：在后台或图形界面启动（推荐）

```bash
open MacDLNA.app
```

启动后，macOS 顶部菜单栏会出现 Hi-Fi 音箱图标。点击即可展开控制面板。

### 方式二：终端调试模式运行

若需实时查看 UPnP/DLNA 详细通信报文日志，可直接在终端中运行：

```bash
./MacDLNA.app/Contents/MacOS/MacDLNA
```

---

## 📱 手机投送使用指南

确保手机与 Mac 处于**同一 Wi-Fi / 局域网**内：

1. **网易云音乐**：
   - 播放歌曲 -> 点击播放界面下方的“...”或“投播/DLNA”图标 -> 在设备列表中选择 `MacDLNA (你的Mac名)`。
2. **QQ音乐**：
   - 播放歌曲 -> 点击播放界面“投播”图标或“设置”中的 QPlay/DLNA -> 选择 `MacDLNA`。
3. **BubbleUPnP / Symfonium / Foobar2000**：
   - 在 Renderer / Output 设备列表中选择 `MacDLNA`，点击音频即可即时推流投送。
