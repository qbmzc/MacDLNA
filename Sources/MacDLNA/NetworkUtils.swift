import Foundation
import Darwin

public final class NetworkUtils {
    
    /// 获取本机最优局域网真实 IPv4 地址（自动过滤 127.0.0.1、utun、awdl 等虚拟网卡）
    public static func getPrimaryLocalIPv4() -> String? {
        let interfaces = getAllActiveIPv4Interfaces()
        
        // 优先选择 en0 (通常为 Wi-Fi 或主网卡)
        if let en0 = interfaces.first(where: { $0.name == "en0" }) {
            return en0.ip
        }
        
        // 其次选择任意以 en 开头的网卡 (en1, en2 等)
        if let en = interfaces.first(where: { $0.name.hasPrefix("en") }) {
            return en.ip
        }
        
        // 兜底返回第一个有效 IPv4
        return interfaces.first?.ip
    }
    
    /// 获取所有处于 UP 且 RUNNING 状态的非虚拟网卡 IPv4 列表
    public static func getAllActiveIPv4Interfaces() -> [(name: String, ip: String)] {
        var results: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return results
        }
        defer { freeifaddrs(ifaddr) }
        
        // 忽略的虚拟或特殊网卡前缀
        let ignoredPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "p2p", "anpi", "gif", "stf"]
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            
            // 必须处于 UP 且 RUNNING 状态
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING else {
                continue
            }
            
            // 过滤回环网卡 (127.0.0.1)
            if (flags & IFF_LOOPBACK) == IFF_LOOPBACK {
                continue
            }
            
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            
            let name = String(cString: interface.ifa_name)
            
            // 过滤虚拟网卡
            let isIgnored = ignoredPrefixes.contains { name.hasPrefix($0) }
            if isIgnored {
                continue
            }
            
            var addrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            
            guard inet_ntop(AF_INET, &addrIn.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            
            let ip = String(cString: buffer)
            
            // 过滤 127.* 以及链路本地地址 169.254.*
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") {
                continue
            }
            
            results.append((name: name, ip: ip))
        }
        
        return results
    }
    
    /// 获取当前 Mac 设备的易读名称 (例如 "MacBook Pro" 或主机名)
    public static func getDeviceFriendlyName() -> String {
        if let hostName = Host.current().localizedName, !hostName.isEmpty {
            return hostName
        }
        let fallback = ProcessInfo.processInfo.hostName
        if !fallback.isEmpty {
            return fallback.replacingOccurrences(of: ".local", with: "")
        }
        return "Mac Audio Renderer"
    }
    
    /// 获取持久化的 UDN (Unique Device Name) UUID
    public static func getDeviceUUID() -> String {
        let key = "MacDLNA_Device_UUID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let newUUID = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newUUID, forKey: key)
        return newUUID
    }
}
