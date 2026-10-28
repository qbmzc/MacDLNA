import Foundation
import AVFoundation
import MediaPlayer
import AppKit
import Combine

public enum DLNATransportState: String {
    case stopped = "STOPPED"
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
}

public final class AudioEngine: ObservableObject {
    public static let shared = AudioEngine()
    
    // MARK: - Published Properties for UI
    
    @Published public private(set) var state: DLNATransportState = .noMedia
    @Published public private(set) var currentURI: String = ""
    @Published public private(set) var title: String = "等待投送..."
    @Published public private(set) var artist: String = "无"
    @Published public private(set) var album: String = ""
    @Published public private(set) var coverImage: NSImage? = nil
    @Published public private(set) var duration: Double = 0.0
    @Published public private(set) var currentTime: Double = 0.0
    @Published public var volume: Float = 0.8 {
        didSet {
            player.volume = volume
            NotificationCenter.default.post(name: Self.transportChanged, object: self)
        }
    }
    @Published public var isMuted: Bool = false {
        didSet {
            player.isMuted = isMuted
            NotificationCenter.default.post(name: Self.transportChanged, object: self)
        }
    }
    @Published public private(set) var rawMetadata: String = ""
    @Published public private(set) var logs: [String] = []
    
    @Published public private(set) var canGoNext = false
    @Published public private(set) var canGoPrevious = false
    public var nextURI: String { playbackQueue.next?.uri ?? "" }
    public var nextMetadata: String { playbackQueue.next?.metadata ?? "" }
    public var transportActions: String {
        guard !currentURI.isEmpty else { return "" }
        return (["Play", "Pause", "Stop", "Seek"] +
                (canGoNext ? ["Next"] : []) + (canGoPrevious ? ["Previous"] : [])).joined(separator: ",")
    }
    static let transportChanged = Notification.Name("MacDLNATransportChanged")
    private var playbackQueue = PlaybackQueue()
    private var shouldPlayWhenReady = true
    private var notificationTokens: [NSObjectProtocol] = []

    // All transport mutations and SOAP snapshots are serialized on the main thread.
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    public func setNextURI(uri: String, metadata: String?) {
        onMain {
            playbackQueue.setNext(uri.isEmpty ? nil : PlaybackTrack(uri: uri, metadata: metadata ?? ""))
            refreshQueueAvailability()
            log(uri.isEmpty ? "已清空下一首" : "已接收下一首，播放结束后自动续播")
            updateNowPlayingInfo()
        }
    }

    @discardableResult
    public func next() -> Bool {
        onMain {
            guard let track = playbackQueue.advance() else {
                log("无法下一曲：控制端尚未提供下一首地址")
                return false
            }
            loadTrack(track)
            return true
        }
    }

    @discardableResult
    public func previous() -> Bool {
        onMain {
            guard let track = playbackQueue.previous() else { return false }
            loadTrack(track)
            return true
        }
    }

    private func refreshQueueAvailability() {
        canGoNext = playbackQueue.next != nil
        canGoPrevious = playbackQueue.canGoPrevious
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = canGoNext
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = canGoPrevious
    }

    // MARK: - Internal Player
    
    private var player: AVPlayer
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    init(player: AVPlayer = AVPlayer(), configureSystemControls: Bool = true) {
        self.player = player
        self.player.volume = 0.8
        
        if configureSystemControls { setupRemoteCommands() }
        setupTimeObserver()
        setupNotificationObservers()
        
        log("音频引擎初始化完成 (AVPlayer + MediaPlayer)")
    }
    
    // MARK: - Logging
    
    public func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(msg)"
        
        DispatchQueue.main.async {
            self.logs.insert(line, at: 0)
            if self.logs.count > 100 {
                self.logs.removeLast()
            }
        }
        print(line)
    }
    
    // MARK: - DLNA Control Methods
    
    public func setURI(uri: String, metadata: String?) {
        onMain {
            let track = uri.isEmpty ? nil : PlaybackTrack(uri: uri, metadata: metadata ?? "")
            playbackQueue.replaceCurrent(track)
            if let track {
                loadTrack(track)
            } else {
                cleanUpCurrentItem()
                player.pause()
                player.replaceCurrentItem(with: nil)
                playerItem = nil
                shouldPlayWhenReady = false
                currentURI = ""
                rawMetadata = ""
                duration = 0
                currentTime = 0
                parseDIDLMetadata("")
                state = .noMedia
                refreshQueueAvailability()
                updateNowPlayingInfo()
            }
        }
    }

    private func loadTrack(_ track: PlaybackTrack) {
        let uri = track.uri
        let metadata: String? = track.metadata
        self.log("收到 SetAVTransportURI: \(uri)")
        self.currentURI = uri
        self.rawMetadata = metadata ?? ""
        self.currentTime = 0.0
        self.duration = 0.0
        self.shouldPlayWhenReady = true
        self.refreshQueueAvailability()

        // 解析元数据 (DIDL-Lite)
        self.parseDIDLMetadata(metadata ?? "")

        guard let url = URL(string: uri) else {
            self.log("无效的音频 URL: \(uri)")
            self.state = .noMedia
            return
        }

        self.cleanUpCurrentItem()

        // 配置请求头与 Asset
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "MacDLNA/1.0 (Macintosh; Apple Silicon) AVFoundation",
                "Accept": "*/*"
            ]
        ])
        let item = AVPlayerItem(asset: asset)
        self.playerItem = item
        self.state = .transitioning

        // 监听状态
        self.statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.playerItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    let dur = item.duration.seconds
                    if !dur.isNaN && dur > 0 {
                        self.duration = dur
                    }
                    self.log("音频流加载就绪，时长: \(self.formatDuration(self.duration))")
                    if self.shouldPlayWhenReady {
                        self.player.play()
                        self.state = .playing
                    }
                    self.updateNowPlayingInfo()
                case .failed:
                    let err = item.error?.localizedDescription ?? "未知错误"
                    self.log("音频流加载失败: \(err)")

                    // 详细 HLS / CoreMedia 诊断
                    if let errorLog = item.errorLog(), !errorLog.events.isEmpty {
                        for ev in errorLog.events {
                            self.log("HLS 报错: HTTP \(ev.errorStatusCode), \(ev.errorComment ?? "无说明")")
                        }
                    }
                    if let nsErr = item.error as NSError?,
                       let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                        self.log("底层错误: [\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)")
                    }

                    self.state = .stopped
                    self.updateNowPlayingInfo()
                default:
                    break
                }
            }
        }

        self.durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.playerItem === item else { return }
                let dur = item.duration.seconds
                if !dur.isNaN && dur > 0 {
                    self.duration = dur
                    self.updateNowPlayingInfo()
                }
            }
        }

        self.player.replaceCurrentItem(with: item)
        self.updateNowPlayingInfo()
    }

    public func play() {
        onMain { [weak self] in
            guard let self = self else { return }
            guard self.playerItem != nil else { return }
            self.shouldPlayWhenReady = true
            self.log("播放指令 (Play)")
            self.player.play()
            self.state = .playing
            self.updateNowPlayingInfo()
        }
    }
    
    public func pause() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.shouldPlayWhenReady = false
            self.log("暂停指令 (Pause)")
            self.player.pause()
            self.state = .paused
            self.updateNowPlayingInfo()
        }
    }
    
    public func stop() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.shouldPlayWhenReady = false
            self.log("停止指令 (Stop)")
            self.player.pause()
            self.player.seek(to: .zero)
            self.currentTime = 0.0
            self.state = .stopped
            LyricService.shared.updatePlaybackTime(0.0)
            self.updateNowPlayingInfo()
        }
    }
    
    public func seek(toSeconds seconds: Double) {
        onMain { [weak self] in
            guard let self = self else { return }
            let clamped = max(0, min(seconds, self.duration > 0 ? self.duration : seconds))
            self.log("进度跳转指令 (Seek to \(self.formatDuration(clamped)))")
            let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
            self.player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    self.currentTime = clamped
                    LyricService.shared.updatePlaybackTime(clamped)
                    self.updateNowPlayingInfo()
                }
            }
        }
    }
    
    public func seek(target: String) {
        let seconds = parseTimeString(target)
        seek(toSeconds: seconds)
    }
    
    public func setVolumeInt(_ vol: Int) {
        onMain { [weak self] in
            guard let self = self else { return }
            let clamped = max(0, min(100, vol))
            self.volume = Float(clamped) / 100.0
            self.log("设置音量: \(clamped)%")
        }
    }
    
    public func getVolumeInt() -> Int {
        return Int(round(volume * 100.0))
    }
    
    public func setMuteBool(_ mute: Bool) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.isMuted = mute
            self.log("设置静音: \(mute)")
        }
    }
    
    // MARK: - DIDL-Lite Metadata Parsing
    
    private func parseDIDLMetadata(_ xml: String) {
        LyricService.shared.loadLRC("")
        if xml.isEmpty {
            self.title = "未知曲目"
            self.artist = "未知艺术家"
            self.album = ""
            self.coverImage = nil
            return
        }
        
        // UPnP SOAP 中的 DIDL-Lite 元数据通常被整体转义 (&lt;DIDL-Lite...&gt;)
        let cleanXML = xml.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("&lt;") ? unescapeXML(xml) : xml
        
        let titleVal = extractTagValue(tag: "dc:title", from: cleanXML) ??
                       extractTagValue(tag: "title", from: cleanXML) ?? "未知曲目"
        let artistVal = extractTagValue(tag: "upnp:artist", from: cleanXML) ??
                        extractTagValue(tag: "dc:creator", from: cleanXML) ??
                        extractTagValue(tag: "artist", from: cleanXML) ?? "未知艺术家"
        let albumVal = extractTagValue(tag: "upnp:album", from: cleanXML) ??
                       extractTagValue(tag: "album", from: cleanXML) ?? ""
        let artURI = extractTagValue(tag: "upnp:albumArtURI", from: cleanXML) ??
                     extractTagValue(tag: "albumArtURI", from: cleanXML)
        
        // 解析 <res duration="00:03:45"...>
        if let durStr = extractAttributeValue(attr: "duration", tag: "res", from: cleanXML) {
            let dur = parseTimeString(durStr)
            if dur > 0 {
                self.duration = dur
            }
        }
        
        self.title = unescapeXML(titleVal)
        self.artist = unescapeXML(artistVal)
        self.album = unescapeXML(albumVal)
        self.coverImage = nil
        
        self.log("解析曲目: 🎵 \(self.title) - 👤 \(self.artist)\(self.album.isEmpty ? "" : " (💿 \(self.album))")")
        
        // 解析投送包中的歌词（如 QQ 音乐 / 扩展 DLNA 标签），未提供则在线智能匹配
        let lyricRaw = extractTagValue(tag: "upnp:lyrics", from: cleanXML) ??
                       extractTagValue(tag: "lyrics", from: cleanXML) ??
                       extractTagValue(tag: "song:lyric", from: cleanXML) ??
                       extractTagValue(tag: "lyric", from: cleanXML) ??
                       extractTagValue(tag: "qqmusic:lyric", from: cleanXML)
        
        if let raw = lyricRaw, !raw.isEmpty {
            if let decodedData = Data(base64Encoded: raw),
               let decodedStr = String(data: decodedData, encoding: .utf8),
               decodedStr.contains("[") {
                LyricService.shared.loadLRC(decodedStr)
            } else {
                LyricService.shared.loadLRC(unescapeXML(raw))
            }
        } else {
            LyricService.shared.fetchOnlineLyrics(title: self.title, artist: self.artist)
        }
        
        // 异步下载封面
        if let artURI = artURI, let artURL = URL(string: unescapeXML(artURI)) {
            fetchCoverArt(from: artURL)
        }
    }
    
    private func fetchCoverArt(from url: URL) {
        let requestedURI = currentURI
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, let image = NSImage(data: data) else {
                return
            }
            DispatchQueue.main.async {
                guard self.currentURI == requestedURI else { return }
                self.coverImage = image
                self.updateNowPlayingInfo()
            }
        }.resume()
    }
    
    // MARK: - System Media Center & Remote Commands
    
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        
        center.nextTrackCommand.isEnabled = false
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next() == true ? .success : .noSuchContent
        }
        center.previousTrackCommand.isEnabled = false
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous() == true ? .success : .noSuchContent
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.state == .playing {
                self.pause()
            } else {
                self.play()
            }
            return .success
        }
        
        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
        
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(toSeconds: posEvent.positionTime)
            return .success
        }
    }
    
    public func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        if !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = (state == .playing ? 1.0 : 0.0)
        
        if let image = coverImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        NotificationCenter.default.post(name: Self.transportChanged, object: self)
    }
    
    // MARK: - Observers
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = time.seconds
            if !sec.isNaN {
                self.currentTime = sec
                LyricService.shared.updatePlaybackTime(sec)
            }
        }
    }
    
    private func setupNotificationObservers() {
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let item = notification.object as? AVPlayerItem,
                  self.playerItem === item, self.state == .playing else { return }
            self.log("曲目播放完毕")
            if self.canGoNext {
                self.next()
                return
            }
            self.log("等待控制端提供下一首；当前没有缓存的下一首地址")
            self.state = .stopped
            self.currentTime = self.duration
            self.updateNowPlayingInfo()
        })
        
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self, let item = notif.object as? AVPlayerItem,
                  self.playerItem === item else { return }
            let err = notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.log("播放中断异常: \(err?.localizedDescription ?? "未知")")
            self.state = .stopped
            self.updateNowPlayingInfo()
        })
    }
    
    private func cleanUpCurrentItem() {
        statusObserver?.invalidate()
        statusObserver = nil
        durationObserver?.invalidate()
        durationObserver = nil
    }
    
    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        cleanUpCurrentItem()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }
    
    // MARK: - Time Conversion Helpers
    
    public func formatDuration(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds >= 0 else { return "00:00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    
    public func parseTimeString(_ timeStr: String) -> Double {
        // 支持 00:03:45 或 00:03:45.000 或 03:45
        let parts = timeStr.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")
        if parts.count == 3 {
            let h = Double(parts[0]) ?? 0.0
            let m = Double(parts[1]) ?? 0.0
            let s = Double(parts[2]) ?? 0.0
            return h * 3600 + m * 60 + s
        } else if parts.count == 2 {
            let m = Double(parts[0]) ?? 0.0
            let s = Double(parts[1]) ?? 0.0
            return m * 60 + s
        } else if let s = Double(timeStr) {
            return s
        }
        return 0.0
    }
    
    // MARK: - XML Helper Extraction
    
    private func extractTagValue(tag: String, from text: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange),
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
        }
        return nil
    }
    
    private func extractAttributeValue(attr: String, tag: String, from text: String) -> String? {
        let pattern = "<\(tag)[^>]*\(attr)=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange),
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
        }
        return nil
    }
    
    private func unescapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
