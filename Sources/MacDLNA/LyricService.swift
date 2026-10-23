import Foundation
import Combine

public struct LyricLine: Identifiable, Equatable {
    public let id = UUID()
    public let time: Double         // 歌词所在时间戳（秒）
    public let text: String         // 歌词正文
    
    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

public final class LyricService: ObservableObject {
    public static let shared = LyricService()
    
    // MARK: - Published Properties
    
    @Published public private(set) var lines: [LyricLine] = []
    @Published public private(set) var currentLineIndex: Int = -1
    @Published public private(set) var currentLineText: String = ""
    @Published public private(set) var statusMessage: String = "暂无歌词"
    @Published public private(set) var isSearching: Bool = false
    
    private init() {}
    
    // MARK: - Reset
    
    public func reset() {
        DispatchQueue.main.async {
            self.lines = []
            self.currentLineIndex = -1
            self.currentLineText = ""
            self.statusMessage = "暂无歌词"
            self.isSearching = false
        }
    }
    
    // MARK: - Load Raw LRC
    
    public func loadLRC(_ rawLRC: String) {
        let parsed = parseLRC(rawLRC)
        DispatchQueue.main.async {
            self.lines = parsed
            self.currentLineIndex = -1
            self.currentLineText = ""
            self.statusMessage = parsed.isEmpty ? "暂无歌词" : "歌词已就绪"
            self.isSearching = false
            AudioEngine.shared.log("已加载投送歌词 (\(parsed.count) 行)")
        }
    }
    
    // MARK: - Update Current Time
    
    public func updatePlaybackTime(_ currentTime: Double) {
        guard !lines.isEmpty else {
            if currentLineIndex != -1 {
                currentLineIndex = -1
                currentLineText = ""
            }
            return
        }
        
        var foundIndex = -1
        for (index, line) in lines.enumerated() {
            if currentTime >= line.time {
                foundIndex = index
            } else {
                break
            }
        }
        
        if foundIndex != currentLineIndex {
            currentLineIndex = foundIndex
            if foundIndex >= 0 && foundIndex < lines.count {
                currentLineText = lines[foundIndex].text
            } else {
                currentLineText = ""
            }
        }
    }
    
    // MARK: - Online Lyric Search (Native HTTP Fallback)
    
    public func fetchOnlineLyrics(title: String, artist: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.replacingOccurrences(of: "无", with: "")
                                .replacingOccurrences(of: "未知艺术家", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanTitle.isEmpty,
              cleanTitle != "未知曲目",
              cleanTitle != "等待投送..." else {
            reset()
            return
        }
        
        DispatchQueue.main.async {
            self.isSearching = true
            self.statusMessage = "正在检索歌词..."
        }
        
        let queryStr = "\(cleanTitle) \(cleanArtist)".trimmingCharacters(in: .whitespaces)
        guard let encodedQuery = queryStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "http://music.163.com/api/search/get/web?csrf_token=&hlpretag=&hlposttag=&s=\(encodedQuery)&type=1&offset=0&total=true&limit=1") else {
            DispatchQueue.main.async {
                self.isSearching = false
                self.statusMessage = "暂无歌词"
            }
            return
        }
        
        URLSession.shared.dataTask(with: searchURL) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else {
                DispatchQueue.main.async {
                    self?.isSearching = false
                    self?.statusMessage = "歌词获取失败"
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let songs = result["songs"] as? [[String: Any]],
                   let firstSong = songs.first,
                   let songID = firstSong["id"] as? Int {
                    self.fetchLyricByID(songID)
                } else {
                    DispatchQueue.main.async {
                        self.isSearching = false
                        self.statusMessage = "未找到匹配歌词"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSearching = false
                    self.statusMessage = "暂无歌词"
                }
            }
        }.resume()
    }
    
    private func fetchLyricByID(_ songID: Int) {
        guard let url = URL(string: "http://music.163.com/api/song/lyric?os=osx&id=\(songID)&lv=-1&kv=-1&tv=-1") else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let lrcObj = json["lrc"] as? [String: Any],
                   let lrcText = lrcObj["lyric"] as? String {
                    let parsed = self.parseLRC(lrcText)
                    DispatchQueue.main.async {
                        self.lines = parsed
                        self.isSearching = false
                        self.statusMessage = parsed.isEmpty ? "暂无歌词" : "歌词已就绪"
                        AudioEngine.shared.log("成功匹配在线歌词: \(parsed.count) 行")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSearching = false
                    self.statusMessage = "歌词解析失败"
                }
            }
        }.resume()
    }
    
    // MARK: - LRC Parsing
    
    public func parseLRC(_ lrcContent: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let rawLines = lrcContent.components(separatedBy: .newlines)
        
        // 匹配 [mm:ss.xx] 或 [mm:ss.xxx] 或 [mm:ss]
        let pattern = "\\[(\\d{2}):(\\d{2})(?:[\\.:](\\d{2,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }
            
            // 去除所有时间标签，保留歌词内容
            let text = regex.stringByReplacingMatches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
            
            for match in matches {
                let mStr = nsLine.substring(with: match.range(at: 1))
                let sStr = nsLine.substring(with: match.range(at: 2))
                let msStr = match.range(at: 3).location != NSNotFound ? nsLine.substring(with: match.range(at: 3)) : "0"
                
                let minutes = Double(mStr) ?? 0.0
                let seconds = Double(sStr) ?? 0.0
                var ms = Double(msStr) ?? 0.0
                if msStr.count == 2 {
                    ms *= 10
                }
                let totalSec = minutes * 60.0 + seconds + ms / 1000.0
                
                result.append(LyricLine(time: totalSec, text: text))
            }
        }
        
        return result.sorted { $0.time < $1.time }
    }
}
