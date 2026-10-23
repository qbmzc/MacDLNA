import Foundation
import Darwin

public final class SSDPService {
    public let uuid: String
    public let httpPort: Int
    
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.macdlna.ssdp", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    
    private let multicastIPv4 = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    
    public init(uuid: String, httpPort: Int = 8585) {
        self.uuid = uuid
        self.httpPort = httpPort
    }
    
    // MARK: - Lifecycle
    
    public func start() {
        guard !isRunning else { return }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setupSocket()
                self.isRunning = true
                AudioEngine.shared.log("SSDP 服务已启动 (监听 239.255.255.250:1900)")
                
                // 启动即刻连续广播 3 次 Alive，确保局域网控制点迅速发现
                self.broadcastBurstAlive()
                
                // 设置定时器，每 30 秒广播一次 Alive
                self.startPeriodicAliveTimer()
            } catch {
                AudioEngine.shared.log("SSDP 启动失败: \(error.localizedDescription)")
            }
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sendByebye()
            self.timer?.cancel()
            self.timer = nil
            
            if let source = self.readSource {
                source.cancel()
                self.readSource = nil
            } else if self.socketFD >= 0 {
                close(self.socketFD)
                self.socketFD = -1
            }
            self.isRunning = false
            AudioEngine.shared.log("SSDP 服务已停止")
        }
    }
    
    // MARK: - Socket Setup (Darwin BSD Sockets)
    
    private func setupSocket() throws {
        // 创建 UDP Socket
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NSError(domain: "SSDPError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 UDP Socket (errno: \(errno))"])
        }
        self.socketFD = fd
        
        // 设置非阻塞
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        // 允许端口与地址复用 (SO_REUSEADDR & SO_REUSEPORT)
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw NSError(domain: "SSDPError", code: 2, userInfo: [NSLocalizedDescriptionKey: "setsockopt SO_REUSEADDR 失败"])
        }
        
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw NSError(domain: "SSDPError", code: 3, userInfo: [NSLocalizedDescriptionKey: "setsockopt SO_REUSEPORT 失败"])
        }
        
        // 设置组播 TTL
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        
        // 允许组播回环 (IP_MULTICAST_LOOP)
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        
        // 绑定 0.0.0.0:1900
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = ssdpPort.bigEndian
        bindAddr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        
        let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "SSDPError", code: 4, userInfo: [NSLocalizedDescriptionKey: "bind 1900 端口失败 (errno: \(errno))"])
        }
        
        // 加入组播组 239.255.255.250
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(multicastIPv4)
        if let localIP = NetworkUtils.getPrimaryLocalIPv4() {
            mreq.imr_interface.s_addr = inet_addr(localIP)
            
            // 设置出口网卡 IP_MULTICAST_IF，确保报文从局域网网卡发出
            var ifAddr = in_addr()
            inet_aton(localIP, &ifAddr)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
        } else {
            mreq.imr_interface.s_addr = in_addr_t(INADDR_ANY).bigEndian
        }
        
        let joinResult = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        if joinResult != 0 {
            AudioEngine.shared.log("警告: IP_ADD_MEMBERSHIP 加入组播组返回值: \(joinResult), errno: \(errno)")
        }
        
        // 使用 DispatchSource 异步监听读取事件
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleIncomingPackets()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.readSource = source
        source.resume()
    }
    
    // MARK: - Packet Ingestion & M-SEARCH Handling
    
    private func handleIncomingPackets() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        while true {
            var clientAddr = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            
            let bytesRead = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(socketFD, &buffer, buffer.count, 0, sa, &addrLen)
                }
            }
            
            if bytesRead < 0 {
                // EWOULDBLOCK / EAGAIN 表示数据已读完
                break
            }
            guard bytesRead > 0 else { continue }
            
            guard let packet = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else {
                continue
            }
            
            // 过滤并处理 M-SEARCH
            if packet.hasPrefix("M-SEARCH") || packet.contains("M-SEARCH * HTTP/1.1") {
                handleMSearch(packet: packet, clientAddr: clientAddr, addrLen: addrLen)
            }
        }
    }
    
    private func handleMSearch(packet: String, clientAddr: sockaddr_storage, addrLen: socklen_t) {
        // 解析 Header 中的 ST (Search Target)
        var st: String?
        let lines = packet.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                if key == "ST" {
                    st = parts[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        
        guard let searchTarget = st else { return }
        
        // 匹配目标列表
        let targets = supportedTargets()
        var matchedList: [(target: String, usn: String)] = []
        
        if searchTarget == "ssdp:all" {
            matchedList = targets
        } else {
            for item in targets {
                if item.target.lowercased() == searchTarget.lowercased() {
                    matchedList.append(item)
                }
            }
        }
        
        guard !matchedList.isEmpty else { return }
        
        guard let localIP = NetworkUtils.getPrimaryLocalIPv4() else { return }
        let location = "http://\(localIP):\(httpPort)/description.xml"
        let dateString = rfc1123Date()
        
        for item in matchedList {
            let response = "HTTP/1.1 200 OK\r\n" +
                           "CACHE-CONTROL: max-age=1800\r\n" +
                           "DATE: \(dateString)\r\n" +
                           "EXT:\r\n" +
                           "LOCATION: \(location)\r\n" +
                           "SERVER: Darwin/23.0.0 UPnP/1.0 MacDLNA/1.0\r\n" +
                           "ST: \(item.target)\r\n" +
                           "USN: \(item.usn)\r\n" +
                           "BOOTID.UPNP.ORG: 1\r\n" +
                           "CONFIGID.UPNP.ORG: 1\r\n\r\n"
            
            sendUDPUnicast(dataString: response, to: clientAddr, addrLen: addrLen)
        }
    }
    
    // MARK: - Multicast Alive / Byebye Announcements
    
    public func reannounce() {
        queue.async { [weak self] in
            self?.broadcastBurstAlive()
        }
    }
    
    private func broadcastBurstAlive() {
        sendAlive()
        // 短延时再广播一次增加鲁棒性
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sendAlive()
        }
    }
    
    private func sendAlive() {
        guard let localIP = NetworkUtils.getPrimaryLocalIPv4() else { return }
        let location = "http://\(localIP):\(httpPort)/description.xml"
        
        for item in supportedTargets() {
            let notify = "NOTIFY * HTTP/1.1\r\n" +
                         "HOST: \(multicastIPv4):\(ssdpPort)\r\n" +
                         "CACHE-CONTROL: max-age=1800\r\n" +
                         "LOCATION: \(location)\r\n" +
                         "NT: \(item.target)\r\n" +
                         "NTS: ssdp:alive\r\n" +
                         "SERVER: Darwin/23.0.0 UPnP/1.0 MacDLNA/1.0\r\n" +
                         "USN: \(item.usn)\r\n" +
                         "BOOTID.UPNP.ORG: 1\r\n" +
                         "CONFIGID.UPNP.ORG: 1\r\n\r\n"
            
            sendUDPMulticast(dataString: notify)
        }
    }
    
    private func sendByebye() {
        for item in supportedTargets() {
            let notify = "NOTIFY * HTTP/1.1\r\n" +
                         "HOST: \(multicastIPv4):\(ssdpPort)\r\n" +
                         "NT: \(item.target)\r\n" +
                         "NTS: ssdp:byebye\r\n" +
                         "USN: \(item.usn)\r\n" +
                         "BOOTID.UPNP.ORG: 1\r\n" +
                         "CONFIGID.UPNP.ORG: 1\r\n\r\n"
            
            sendUDPMulticast(dataString: notify)
        }
    }
    
    private func startPeriodicAliveTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30.0, repeating: 30.0)
        t.setEventHandler { [weak self] in
            self?.sendAlive()
        }
        self.timer = t
        t.resume()
    }
    
    // MARK: - Supported Targets & USN
    
    private func supportedTargets() -> [(target: String, usn: String)] {
        let udn = "uuid:\(uuid)"
        return [
            ("upnp:rootdevice", "\(udn)::upnp:rootdevice"),
            (udn, udn),
            ("urn:schemas-upnp-org:device:MediaRenderer:1", "\(udn)::urn:schemas-upnp-org:device:MediaRenderer:1"),
            ("urn:schemas-upnp-org:service:AVTransport:1", "\(udn)::urn:schemas-upnp-org:service:AVTransport:1"),
            ("urn:schemas-upnp-org:service:RenderingControl:1", "\(udn)::urn:schemas-upnp-org:service:RenderingControl:1"),
            ("urn:schemas-upnp-org:service:ConnectionManager:1", "\(udn)::urn:schemas-upnp-org:service:ConnectionManager:1")
        ]
    }
    
    // MARK: - UDP Transmission
    
    private func sendUDPUnicast(dataString: String, to clientAddr: sockaddr_storage, addrLen: socklen_t) {
        guard socketFD >= 0, let data = dataString.data(using: .utf8) else { return }
        
        var addr = clientAddr
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(socketFD, baseAddress, data.count, 0, sa, addrLen)
                }
            }
        }
    }
    
    private func sendUDPMulticast(dataString: String) {
        guard socketFD >= 0, let data = dataString.data(using: .utf8) else { return }
        
        var mcastAddr = sockaddr_in()
        mcastAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mcastAddr.sin_family = sa_family_t(AF_INET)
        mcastAddr.sin_port = ssdpPort.bigEndian
        inet_aton(multicastIPv4, &mcastAddr.sin_addr)
        
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &mcastAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(socketFD, baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    
    private func rfc1123Date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}
