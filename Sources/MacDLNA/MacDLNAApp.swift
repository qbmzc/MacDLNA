import SwiftUI
import AppKit

// MARK: - App Delegate for Accessory Policy

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置为后台/菜单栏应用，不显示在 Dock 中
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - DLNA Manager Coordinator

public final class DLNAManager: ObservableObject {
    public static let shared = DLNAManager()
    
    @Published public var friendlyName: String
    @Published public var localIP: String = "127.0.0.1"
    @Published public var httpPort: Int = 8585
    @Published public var isRunning: Bool = false
    
    public let uuid: String
    public let audioEngine = AudioEngine.shared
    
    private var httpServer: UPnPHTTPServer?
    private var ssdpService: SSDPService?
    
    private init() {
        self.uuid = NetworkUtils.getDeviceUUID()
        let defaultName = "MacDLNA (\(NetworkUtils.getDeviceFriendlyName()))"
        self.friendlyName = UserDefaults.standard.string(forKey: "MacDLNA_FriendlyName") ?? defaultName
        self.localIP = NetworkUtils.getPrimaryLocalIPv4() ?? "127.0.0.1"
    }
    
    public func startServices() {
        guard !isRunning else { return }
        
        // 刷新 IP
        if let ip = NetworkUtils.getPrimaryLocalIPv4() {
            self.localIP = ip
        }
        
        let server = UPnPHTTPServer(port: httpPort, uuid: uuid, friendlyName: friendlyName)
        do {
            try server.start()
            self.httpServer = server
            
            let ssdp = SSDPService(uuid: uuid, httpPort: httpPort)
            ssdp.start()
            self.ssdpService = ssdp
            
            self.isRunning = true
            audioEngine.log("DLNA DMR 服务就绪: http://\(localIP):\(httpPort)/description.xml")
        } catch {
            audioEngine.log("启动服务失败: \(error.localizedDescription)")
        }
    }
    
    public func stopServices() {
        ssdpService?.stop()
        ssdpService = nil
        httpServer?.stop()
        httpServer = nil
        isRunning = false
    }
    
    public func reannounce() {
        if let ip = NetworkUtils.getPrimaryLocalIPv4() {
            self.localIP = ip
        }
        ssdpService?.reannounce()
        audioEngine.log("重新广播 SSDP Alive 通知")
    }
    
    public func updateFriendlyName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.friendlyName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "MacDLNA_FriendlyName")
        httpServer?.friendlyName = trimmed
        reannounce()
        audioEngine.log("设备名称已更新为: \(trimmed)")
    }
}

// MARK: - SwiftUI Main Entry Point

@main
struct MacDLNAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = DLNAManager.shared
    @StateObject private var audio = AudioEngine.shared
    
    init() {
        // 立即启动 DLNA 核心服务
        DLNAManager.shared.startServices()
    }
    
    var body: some Scene {
        MenuBarExtra {
            MainMenuView(manager: manager, audio: audio)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: audio.state == .playing ? "waveform" : "hifispeaker.fill")
                if audio.state == .playing {
                    Text(audio.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar UI State ViewModel (避免 CLT 环境下缺少 SwiftUIMacros)

final class MenuUIViewModel: ObservableObject {
    @Published var isShowingLogs = false
    @Published var isEditingName = false
    @Published var tempName = ""
    @Published var isDraggingSlider = false
    @Published var sliderVal: Double = 0.0
    @Published var activeTab: Int = 0 // 0: 控制面板, 1: 实时歌词
}

// MARK: - Main Menu Bar Window View

struct MainMenuView: View {
    @ObservedObject var manager: DLNAManager
    @ObservedObject var audio: AudioEngine
    @ObservedObject var lyrics = LyricService.shared
    @StateObject private var uiState = MenuUIViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerView
            
            // 模式切换分段选择器 (控制 / 实时歌词)
            Picker("", selection: $uiState.activeTab) {
                Text("播放控制").tag(0)
                Text(lyrics.lines.isEmpty ? "实时歌词" : "实时歌词 (\(lyrics.lines.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            
            Divider()
            
            if uiState.activeTab == 0 {
                // 控制面板
                ScrollView {
                    VStack(spacing: 14) {
                        nowPlayingCard
                        
                        // 歌词快捷提示浮条
                        lyricSnippetBanner
                        
                        playbackControlCard
                        volumeCard
                        networkInfoCard
                        logAccordion
                    }
                    .padding(14)
                }
            } else {
                // 实时滚动歌词面板 (Apple Music / 网易云同款)
                lyricsView
            }
            
            Divider()
            
            // 底部操作栏
            footerView
        }
        .frame(width: 360, height: 530)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Lyric Snippet Banner (在控制页面的歌词小浮条)
    
    @ViewBuilder
    private var lyricSnippetBanner: some View {
        if !lyrics.currentLineText.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(lyrics.currentLineText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("完整歌词 >")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .contentShape(Rectangle())
            .onTapGesture {
                uiState.activeTab = 1
            }
        }
    }
    
    // MARK: - Full Lyrics View (实时同步滚动与点击点播)
    
    private var lyricsView: some View {
        VStack(spacing: 0) {
            // 顶部歌曲迷你信息
            HStack(spacing: 8) {
                if let cover = audio.coverImage {
                    Image(nsImage: cover)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .cornerRadius(4)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(audio.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(audio.artist)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                
                if lyrics.isSearching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else if !lyrics.lines.isEmpty {
                    Button(action: {
                        lyrics.fetchOnlineLyrics(title: audio.title, artist: audio.artist)
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("重新检索歌词")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // 歌词滚动列表
            if lyrics.lines.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "music.mic")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(lyrics.statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    if !lyrics.isSearching && audio.state != .noMedia {
                        Button("在线检索歌词") {
                            lyrics.fetchOnlineLyrics(title: audio.title, artist: audio.artist)
                        }
                        .font(.system(size: 11))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            Color.clear.frame(height: 40)
                            
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = (index == lyrics.currentLineIndex)
                                Text(line.text)
                                    .font(.system(size: isCurrent ? 15 : 12, weight: isCurrent ? .bold : .regular))
                                    .foregroundColor(isCurrent ? .accentColor : .secondary.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .scaleEffect(isCurrent ? 1.05 : 1.0)
                                    .animation(.easeInOut(duration: 0.25), value: isCurrent)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // 支持点击任意歌词直接 Seek 到对应时间戳
                                        audio.seek(toSeconds: line.time)
                                    }
                            }
                            
                            Color.clear.frame(height: 120)
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: lyrics.currentLineIndex) { newIndex in
                        if newIndex >= 0 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // 底部轻量迷你播放栏
            HStack(spacing: 12) {
                Text(audio.formatDuration(audio.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { audio.currentTime },
                        set: { audio.seek(toSeconds: $0) }
                    ),
                    in: 0...max(audio.duration, 1.0)
                )
                .disabled(audio.duration <= 0)
                
                TrackSkipButton(audio: audio, forward: false)
                Button(action: {
                    if audio.state == .playing {
                        audio.pause()
                    } else {
                        audio.play()
                    }
                }) {
                    Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                TrackSkipButton(audio: audio, forward: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("MacDLNA 接收器")
                    .font(.system(size: 13, weight: .bold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(manager.isRunning ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(manager.isRunning ? "服务就绪 (DMR)" : "已停止")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: {
                manager.reannounce()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("重新在局域网内广播 SSDP 设备信息")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    // MARK: - Now Playing Card
    
    private var nowPlayingCard: some View {
        HStack(spacing: 12) {
            // 专辑封面
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                
                if let cover = audio.coverImage {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .cornerRadius(8)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
            }
            
            // 歌曲信息
            VStack(alignment: .leading, spacing: 3) {
                Text(audio.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                
                Text(audio.artist)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if !audio.album.isEmpty {
                    Text(audio.album)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                
                statusBadge
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
    }
    
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Text(statusString)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.15))
                .foregroundColor(statusColor)
                .cornerRadius(4)
        }
    }
    
    private var statusString: String {
        switch audio.state {
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .stopped: return "已停止"
        case .transitioning: return "正在加载"
        case .noMedia: return "空闲待机"
        }
    }
    
    private var statusColor: Color {
        switch audio.state {
        case .playing: return .green
        case .paused: return .orange
        case .stopped: return .gray
        case .transitioning: return .blue
        case .noMedia: return .secondary
        }
    }
    
    // MARK: - Playback Controls
    
    private var playbackControlCard: some View {
        VStack(spacing: 8) {
            // 进度条
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { uiState.isDraggingSlider ? uiState.sliderVal : audio.currentTime },
                        set: { newVal in
                            uiState.isDraggingSlider = true
                            uiState.sliderVal = newVal
                        }
                    ),
                    in: 0...max(audio.duration, 1.0),
                    onEditingChanged: { editing in
                        uiState.isDraggingSlider = editing
                        if !editing {
                            audio.seek(toSeconds: uiState.sliderVal)
                        }
                    }
                )
                .disabled(audio.duration <= 0)
                
                HStack {
                    Text(audio.formatDuration(uiState.isDraggingSlider ? uiState.sliderVal : audio.currentTime))
                    Spacer()
                    Text(audio.formatDuration(audio.duration))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }
            
            // 播放/暂停/停止按钮
            HStack(spacing: 20) {
                Spacer()
                
                Button(action: {
                    audio.stop()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .disabled(audio.state == .noMedia || audio.state == .stopped)
                
                TrackSkipButton(audio: audio, forward: false)
                Button(action: {
                    if audio.state == .playing {
                        audio.pause()
                    } else {
                        audio.play()
                    }
                }) {
                    Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(audio.state == .noMedia)
                TrackSkipButton(audio: audio, forward: true)

                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.4)))
    }
    
    // MARK: - Volume Card
    
    private var volumeCard: some View {
        HStack(spacing: 10) {
            Button(action: {
                audio.isMuted.toggle()
            }) {
                Image(systemName: audio.isMuted || audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(audio.isMuted ? .red : .primary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            
            Slider(value: $audio.volume, in: 0...1.0)
            
            Text("\(Int(round(audio.volume * 100)))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor).opacity(0.4)))
    }
    
    // MARK: - Network Info Card
    
    private var networkInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("设备与网络")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            // 设备名称 (可直接修改)
            HStack {
                Text("投送设备名:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if uiState.isEditingName {
                    TextField("输入设备名", text: $uiState.tempName, onCommit: {
                        manager.updateFriendlyName(uiState.tempName)
                        uiState.isEditingName = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    
                    Button("完成") {
                        manager.updateFriendlyName(uiState.tempName)
                        uiState.isEditingName = false
                    }
                    .font(.system(size: 10))
                } else {
                    Text(manager.friendlyName)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button(action: {
                        uiState.tempName = manager.friendlyName
                        uiState.isEditingName = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            HStack {
                Text("本机 IP 地址:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("\(manager.localIP):\(manager.httpPort)")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
            }
            
            HStack {
                Text("SSDP 组播:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("239.255.255.250:1900")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.4)))
    }
    
    // MARK: - Realtime Log Accordion
    
    private var logAccordion: some View {
        DisclosureGroup(isExpanded: $uiState.isShowingLogs) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(audio.logs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(6)
            }
            .frame(height: 120)
            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        } label: {
            HStack {
                Text("活动日志 (\(audio.logs.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.4)))
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            Text("支持网易云 / QQ音乐 / BubbleUPnP")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("退出") {
                manager.stopServices()
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct TrackSkipButton: View {
    @ObservedObject var audio: AudioEngine
    let forward: Bool

    private var available: Bool { forward ? audio.canGoNext : audio.canGoPrevious }
    private var label: String { forward ? "下一曲" : "上一曲" }

    var body: some View {
        Button(action: {
            if forward { audio.next() } else { audio.previous() }
        }) {
            Image(systemName: forward ? "forward.end.fill" : "backward.end.fill")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(label)
        .help(available ? label : (forward ? "控制端尚未提供下一首" : "暂无已播放曲目"))
    }
}
