import Foundation
import Network

public final class UPnPHTTPServer {
    public let port: Int
    public let uuid: String
    public var friendlyName: String
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.macdlna.httpserver", qos: .userInitiated)
    private var isRunning = false
    private let events = EventSubscriptions()
    private let engine: AudioEngine
    private var eventObserver: NSObjectProtocol?
    private var pendingInitialSID: String?

    
    public init(port: Int = 8585, uuid: String, friendlyName: String, engine: AudioEngine = .shared) {
        self.engine = engine
        self.port = port
        self.uuid = uuid
        self.friendlyName = friendlyName
        events.snapshot = { [weak self] path in self?.eventBody(path: path) ?? "" }
        eventObserver = NotificationCenter.default.addObserver(
            forName: AudioEngine.transportChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let source = notification.object as? AudioEngine, source === self.engine else { return }
            self.events.notifyChanges()
        }
    }
    
    public func start() throws {
        guard !isRunning else { return }
        
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        let nwListener = try NWListener(using: parameters, on: nwPort)
        self.listener = nwListener
        
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.engine.log("HTTP 服务已启动，监听端口: \(self.port)")
            case .failed(let error):
                self.engine.log("HTTP 服务发生异常: \(error.localizedDescription)")
                self.isRunning = false
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }
        
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        nwListener.start(queue: queue)
    }
    
    deinit {
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
    }

    public func stop() {
        events.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        self.engine.log("HTTP 服务已停止")
    }
    
    // MARK: - Connection Handling
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        let buffer = Data()
        readData(connection: connection, accumulated: buffer)
    }
    
    private func readData(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            
            var currentData = accumulated
            if let content = content, !content.isEmpty {
                currentData.append(content)
            }
            
            // 尝试解析请求
            if let request = self.parseHTTPRequest(from: currentData) {
                // 请求已完整接收
                let (response, initialSID) = DispatchQueue.main.sync {
                    self.pendingInitialSID = nil
                    let response = self.route(request: request)
                    return (response, self.pendingInitialSID)
                }
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    connection.cancel()
                    guard error == nil, let initialSID else { return }
                    DispatchQueue.main.async { self?.events.activate(sid: initialSID) }
                })
            } else if error != nil || isComplete {
                // 连接结束但未构成完整请求，优雅关闭
                connection.cancel()
            } else {
                // 尚未接收完整 Header 或 Body，继续等待读取
                self.readData(connection: connection, accumulated: currentData)
            }
        }
    }
    
    private func sendResponse(connection: NWConnection, response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    // MARK: - HTTP Request Parsing
    
    struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }
    
    private func parseHTTPRequest(from data: Data) -> ParsedRequest? {
        // 查找 \r\n\r\n 边界
        let boundary = "\r\n\r\n".data(using: .utf8)!
        guard let boundaryRange = data.range(of: boundary) else {
            return nil
        }
        
        let headerData = data.subdata(in: 0..<boundaryRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        
        let reqComponents = requestLine.components(separatedBy: " ")
        guard reqComponents.count >= 2 else { return nil }
        
        let method = reqComponents[0].uppercased()
        let path = reqComponents[1]
        
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        let bodyData = data.subdata(in: boundaryRange.upperBound..<data.count)
        
        // 校验 Content-Length
        if let clStr = headers["content-length"], let expectedLen = Int(clStr) {
            if bodyData.count < expectedLen {
                return nil // Body 尚未完全传输完
            }
        }
        
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        return ParsedRequest(method: method, path: path, headers: headers, body: body)
    }
    
    // MARK: - HTTP Routing
    
    func route(request: ParsedRequest) -> Data {
        let cleanPath = request.path.components(separatedBy: "?").first ?? request.path
        
        if request.method == "SUBSCRIBE" || request.method == "UNSUBSCRIBE" {
            return handleSubscription(request: request, path: cleanPath)
        }

        // GET / HEAD 设备描述与 SCPD XML
        if request.method == "GET" || request.method == "HEAD" {
            let isHead = (request.method == "HEAD")
            let localIP = NetworkUtils.getPrimaryLocalIPv4() ?? "127.0.0.1"
            
            switch cleanPath {
            case "/description.xml", "/":
                let xml = UPnPXMLTemplates.deviceDescription(
                    friendlyName: friendlyName,
                    uuid: uuid,
                    ip: localIP,
                    port: port
                )
                return makeXMLResponse(body: isHead ? "" : xml)
                
            case "/AVTransport/scpd.xml":
                return makeXMLResponse(body: isHead ? "" : UPnPXMLTemplates.avTransportSCPD)
                
            case "/RenderingControl/scpd.xml":
                return makeXMLResponse(body: isHead ? "" : UPnPXMLTemplates.renderingControlSCPD)
                
            case "/ConnectionManager/scpd.xml":
                return makeXMLResponse(body: isHead ? "" : UPnPXMLTemplates.connectionManagerSCPD)
                
            default:
                return makeTextResponse(statusCode: 404, statusText: "Not Found", body: "404 Not Found")
            }
        }
        
        // POST SOAP 控制指令
        if request.method == "POST" {
            let soapActionHeader = request.headers["soapaction"]?.replacingOccurrences(of: "\"", with: "") ?? ""
            
            switch cleanPath {
            case "/AVTransport/control":
                return handleAVTransportSOAP(actionHeader: soapActionHeader, body: request.body)
                
            case "/RenderingControl/control":
                return handleRenderingControlSOAP(actionHeader: soapActionHeader, body: request.body)
                
            case "/ConnectionManager/control":
                return handleConnectionManagerSOAP(actionHeader: soapActionHeader, body: request.body)
                
            default:
                return makeTextResponse(statusCode: 404, statusText: "Not Found", body: "Endpoint Not Found")
            }
        }
        
        return makeTextResponse(statusCode: 405, statusText: "Method Not Allowed", body: "Method Not Allowed")
    }
    
    // MARK: - SOAP Handlers
    
    private func handleAVTransportSOAP(actionHeader: String, body: String) -> Data {
        let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"
        let action = extractSOAPActionName(actionHeader: actionHeader, body: body)
        let engine = self.engine
        if let instance = extractXMLTag(name: "InstanceID", from: body), instance != "0" {
            return makeXMLResponse(statusCode: 500, body: UPnPXMLTemplates.soapFault(code: 718, description: "Invalid InstanceID"))
        }

        switch action {
        case "SetAVTransportURI":
            let uri = extractXMLTag(name: "CurrentURI", from: body) ?? ""
            let meta = extractXMLTag(name: "CurrentURIMetaData", from: body)
            guard validMediaURI(uri) else {
                return makeXMLResponse(statusCode: 500, body: UPnPXMLTemplates.soapFault(code: 716, description: "Resource not found"))
            }
            engine.setURI(uri: uri, metadata: meta)
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "SetNextAVTransportURI":
            guard let uri = extractXMLTag(name: "NextURI", from: body), validMediaURI(uri) else {
                return makeXMLResponse(statusCode: 500, body: UPnPXMLTemplates.soapFault(code: 716, description: "Resource not found"))
            }
            engine.setNextURI(uri: uri, metadata: extractXMLTag(name: "NextURIMetaData", from: body))
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "Play":
            engine.play()
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "Pause":
            engine.pause()
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "Stop":
            engine.stop()
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "Seek":
            if let target = extractXMLTag(name: "Target", from: body) {
                engine.seek(target: target)
            }
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "Next", "Previous":
            guard action == "Next" ? engine.next() : engine.previous() else {
                return makeXMLResponse(statusCode: 500, body: UPnPXMLTemplates.soapFault(code: 701, description: "Transition not available"))
            }
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "GetTransportInfo":
            let xmlBody = """
                <CurrentTransportState>\(engine.state.rawValue)</CurrentTransportState>
                <CurrentTransportStatus>OK</CurrentTransportStatus>
                <CurrentSpeed>1</CurrentSpeed>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetPositionInfo":
            let dur = engine.formatDuration(engine.duration)
            let cur = engine.formatDuration(engine.currentTime)
            let metaEscaped = UPnPXMLTemplates.xmlEscape(engine.rawMetadata)
            let uriEscaped = UPnPXMLTemplates.xmlEscape(engine.currentURI)
            
            let xmlBody = """
                <Track>1</Track>
                <TrackDuration>\(dur)</TrackDuration>
                <TrackMetaData>\(metaEscaped)</TrackMetaData>
                <TrackURI>\(uriEscaped)</TrackURI>
                <RelTime>\(cur)</RelTime>
                <AbsTime>\(cur)</AbsTime>
                <RelCount>2147483647</RelCount>
                <AbsCount>2147483647</AbsCount>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetDeviceCapabilities":
            let xmlBody = """
                <PlayMedia>NONE,NETWORK</PlayMedia>
                <RecMedia>NOT_IMPLEMENTED</RecMedia>
                <RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetTransportSettings":
            let xmlBody = """
                <PlayMode>NORMAL</PlayMode>
                <RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetMediaInfo":
            let dur = engine.formatDuration(engine.duration)
            let metaEscaped = UPnPXMLTemplates.xmlEscape(engine.rawMetadata)
            let uriEscaped = UPnPXMLTemplates.xmlEscape(engine.currentURI)
            
            let xmlBody = """
                <NrTracks>1</NrTracks>
                <MediaDuration>\(dur)</MediaDuration>
                <CurrentURI>\(uriEscaped)</CurrentURI>
                <CurrentURIMetaData>\(metaEscaped)</CurrentURIMetaData>
                <NextURI>\(UPnPXMLTemplates.xmlEscape(engine.nextURI))</NextURI>
                <NextURIMetaData>\(UPnPXMLTemplates.xmlEscape(engine.nextMetadata))</NextURIMetaData>
                <PlayMedium>NETWORK</PlayMedium>
                <RecordMedium>NOT_IMPLEMENTED</RecordMedium>
                <WriteStatus>NOT_IMPLEMENTED</WriteStatus>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetCurrentTransportActions":
            let xmlBody = """
                <Actions>\(engine.transportActions)</Actions>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        default:
            self.engine.log("未识别的 AVTransport 指令: \(action)")
            let resp = UPnPXMLTemplates.soapFault(code: 401, description: "Invalid Action")
            return makeXMLResponse(statusCode: 500, body: resp)
        }
    }
    
    private func handleRenderingControlSOAP(actionHeader: String, body: String) -> Data {
        let serviceType = "urn:schemas-upnp-org:service:RenderingControl:1"
        let action = extractSOAPActionName(actionHeader: actionHeader, body: body)
        let engine = self.engine
        
        switch action {
        case "GetVolume":
            let xmlBody = "<CurrentVolume>\(engine.getVolumeInt())</CurrentVolume>"
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "SetVolume":
            if let volStr = extractXMLTag(name: "DesiredVolume", from: body), let vol = Int(volStr) {
                engine.setVolumeInt(vol)
            }
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        case "GetMute":
            let xmlBody = "<CurrentMute>\(engine.isMuted ? "1" : "0")</CurrentMute>"
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "SetMute":
            if let muteStr = extractXMLTag(name: "DesiredMute", from: body) {
                engine.setMuteBool(muteStr == "1" || muteStr.lowercased() == "true")
            }
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: "")
            return makeXMLResponse(body: resp)
            
        default:
            self.engine.log("未识别的 RenderingControl 指令: \(action)")
            let resp = UPnPXMLTemplates.soapFault(code: 401, description: "Invalid Action")
            return makeXMLResponse(statusCode: 500, body: resp)
        }
    }
    
    private func handleConnectionManagerSOAP(actionHeader: String, body: String) -> Data {
        let serviceType = "urn:schemas-upnp-org:service:ConnectionManager:1"
        let action = extractSOAPActionName(actionHeader: actionHeader, body: body)
        
        switch action {
        case "GetProtocolInfo":
            let sinkProtocols = Self.sinkProtocols
            let xmlBody = """
                <Source></Source>
                <Sink>\(sinkProtocols)</Sink>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetCurrentConnectionIDs":
            let xmlBody = "<ConnectionIDs>0</ConnectionIDs>"
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        case "GetCurrentConnectionInfo":
            let xmlBody = """
                <RcsID>0</RcsID>
                <AVTransportID>0</AVTransportID>
                <ProtocolInfo>http-get:*:audio/mpeg:*</ProtocolInfo>
                <PeerConnectionManager></PeerConnectionManager>
                <PeerConnectionID>-1</PeerConnectionID>
                <Direction>Input</Direction>
                <Status>OK</Status>
            """
            let resp = UPnPXMLTemplates.soapResponse(serviceType: serviceType, action: action, body: xmlBody)
            return makeXMLResponse(body: resp)
            
        default:
            self.engine.log("未识别的 ConnectionManager 指令: \(action)")
            let resp = UPnPXMLTemplates.soapFault(code: 401, description: "Invalid Action")
            return makeXMLResponse(statusCode: 500, body: resp)
        }
    }
    
    private static let sinkProtocols = [
                "http-get:*:audio/mpeg:*",
                "http-get:*:audio/mp3:*",
                "http-get:*:audio/x-mp3:*",
                "http-get:*:audio/flac:*",
                "http-get:*:audio/x-flac:*",
                "http-get:*:audio/mp4:*",
                "http-get:*:audio/m4a:*",
                "http-get:*:audio/x-m4a:*",
                "http-get:*:audio/alac:*",
                "http-get:*:audio/x-alac:*",
                "http-get:*:audio/aac:*",
                "http-get:*:audio/wav:*",
                "http-get:*:audio/x-wav:*",
                "http-get:*:audio/ogg:*",
                "http-get:*:application/ogg:*",
                "http-get:*:audio/*:*",
                "http-get:*:application/vnd.apple.mpegurl:*",
                "http-get:*:application/x-mpegURL:*",
                "http-get:*:*"
            ].joined(separator: ",")

    private func validMediaURI(_ uri: String) -> Bool {
        if uri.isEmpty { return true }
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }

    private func handleSubscription(request: ParsedRequest, path: String) -> Data {
        guard ["/AVTransport/event", "/RenderingControl/event", "/ConnectionManager/event"].contains(path) else {
            return makeTextResponse(statusCode: 404, statusText: "Not Found", body: "")
        }
        let headers = request.headers
        let timeout = min(1800, max(1, Int(headers["timeout"]?.replacingOccurrences(of: "Second-", with: "") ?? "") ?? 1800))
        let sid: String
        if let existing = headers["sid"] {
            guard headers["callback"] == nil, headers["nt"] == nil else {
                return makeTextResponse(statusCode: 400, statusText: "Bad Request", body: "")
            }
            if request.method == "UNSUBSCRIBE" {
                guard events.unsubscribe(sid: existing, path: path) else {
                    return makeTextResponse(statusCode: 412, statusText: "Precondition Failed", body: "")
                }
                return makeTextResponse(statusCode: 200, statusText: "OK", body: "")
            }
            guard events.renew(sid: existing, path: path, timeout: TimeInterval(timeout)) else {
                return makeTextResponse(statusCode: 412, statusText: "Precondition Failed", body: "")
            }
            sid = existing
        } else {
            guard request.method == "SUBSCRIBE", headers["nt"]?.lowercased() == "upnp:event",
                  let callback = headers["callback"], let start = callback.firstIndex(of: "<"),
                  let end = callback[start...].firstIndex(of: ">"),
                  let url = URL(string: String(callback[callback.index(after: start)..<end])),
                  url.scheme?.lowercased() == "http", url.host != nil,
                  url.user == nil, url.password == nil else {
                return makeTextResponse(statusCode: 412, statusText: "Precondition Failed", body: "")
            }
            sid = events.subscribe(path: path, callback: url, timeout: TimeInterval(timeout))
            pendingInitialSID = sid
            self.engine.log("已订阅播放状态: \(path)")
        }
        return Data("HTTP/1.1 200 OK\r\nSID: \(sid)\r\nTIMEOUT: Second-\(timeout)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func eventBody(path: String) -> String {
        let engine = self.engine
        func property(_ name: String, _ value: String) -> String {
            "<e:property><\(name)>\(UPnPXMLTemplates.xmlEscape(value))</\(name)></e:property>"
        }
        func variable(_ name: String, _ value: String) -> String {
            "<\(name) val=\"\(UPnPXMLTemplates.xmlEscape(value))\"/>"
        }
        let properties: String
        if path == "/AVTransport/event" {
            let values = variable("TransportState", engine.state.rawValue) +
                variable("TransportStatus", "OK") + variable("TransportPlaySpeed", "1") +
                variable("AVTransportURI", engine.currentURI) + variable("AVTransportURIMetaData", engine.rawMetadata) +
                variable("CurrentTrackURI", engine.currentURI) + variable("CurrentTrackMetaData", engine.rawMetadata) +
                variable("CurrentTrack", engine.currentURI.isEmpty ? "0" : "1") +
                variable("NumberOfTracks", engine.currentURI.isEmpty ? "0" : "1") +
                variable("CurrentTrackDuration", engine.formatDuration(engine.duration)) +
                variable("CurrentMediaDuration", engine.formatDuration(engine.duration)) +
                variable("NextAVTransportURI", engine.nextURI) + variable("NextAVTransportURIMetaData", engine.nextMetadata) +
                variable("CurrentTransportActions", engine.transportActions)
            properties = property("LastChange", "<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/AVT/\"><InstanceID val=\"0\">\(values)</InstanceID></Event>")
        } else if path == "/RenderingControl/event" {
            let values = "<Volume channel=\"Master\" val=\"\(engine.getVolumeInt())\"/><Mute channel=\"Master\" val=\"\(engine.isMuted ? 1 : 0)\"/>"
            properties = property("LastChange", "<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/RCS/\"><InstanceID val=\"0\">\(values)</InstanceID></Event>")
        } else {
            properties = property("SourceProtocolInfo", "") + property("SinkProtocolInfo", Self.sinkProtocols) + property("CurrentConnectionIDs", "0")
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(properties)</e:propertyset>"
    }

    // MARK: - SOAP Helper
    
    private func extractSOAPActionName(actionHeader: String, body: String) -> String {
        // 优先从 Header 提取: "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"
        if let hashIndex = actionHeader.lastIndex(of: "#") {
            let action = String(actionHeader[actionHeader.index(after: hashIndex)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !action.isEmpty {
                return action
            }
        }
        
        // 其次从 Body 中解析类似 <u:Play xmlns:u="...">
        let pattern = "<(?:\\w+:)?([A-Za-z0-9]+)[^>]*xmlns"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: body, options: [], range: NSRange(body.startIndex..<body.endIndex, in: body)),
           let r = Range(match.range(at: 1), in: body) {
            let extracted = String(body[r])
            if extracted != "Envelope" && extracted != "Body" {
                return extracted
            }
        }
        
        return ""
    }
    
    private func extractXMLTag(name: String, from text: String) -> String? {
        if text.range(of: "<(?:\\w+:)?\(name)\\s*/>", options: .regularExpression) != nil { return "" }
        let pattern = "<(?:\\w+:)?\(name)(?:\\s[^>]*)?>(.*?)</(?:\\w+:)?\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange),
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }
    
    // MARK: - Response Builders
    
    private func makeXMLResponse(statusCode: Int = 200, body: String) -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText = (statusCode == 200 ? "OK" : (statusCode == 500 ? "Internal Server Error" : "Error"))
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
                     "Content-Type: text/xml; charset=\"utf-8\"\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n" +
                     "Server: Darwin/23.0.0 UPnP/1.0 MacDLNA/1.0\r\n" +
                     "EXT:\r\n\r\n"
        var respData = header.data(using: .utf8)!
        respData.append(bodyData)
        return respData
    }
    
    private func makeTextResponse(statusCode: Int, statusText: String, body: String) -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
                     "Content-Type: text/plain; charset=\"utf-8\"\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var respData = header.data(using: .utf8)!
        respData.append(bodyData)
        return respData
    }
}
