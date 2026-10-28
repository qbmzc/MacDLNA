import XCTest
@testable import MacDLNA

private final class NotifyProtocol: URLProtocol {
    static var receive: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.receive?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EventSubscriptionTests: XCTestCase {
    @MainActor
    func testInitialNotifySequenceRenewalAndUnsubscribe() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotifyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); NotifyProtocol.receive = nil }
        let events = EventSubscriptions(session: session)
        events.snapshot = { _ in "<state>PLAYING</state>" }
        let first = expectation(description: "Initial sequence zero")
        let second = expectation(description: "Changed sequence one")
        let sid = events.subscribe(path: "/AVTransport/event", callback: URL(string: "http://localhost/callback")!, timeout: 1800)
        NotifyProtocol.receive = { request in
            XCTAssertEqual(request.httpMethod, "NOTIFY")
            XCTAssertEqual(request.value(forHTTPHeaderField: "SID"), sid)
            XCTAssertEqual(request.value(forHTTPHeaderField: "NT"), "upnp:event")
            XCTAssertEqual(request.value(forHTTPHeaderField: "NTS"), "upnp:propchange")
            switch request.value(forHTTPHeaderField: "SEQ") {
            case "0": first.fulfill()
            case "1": second.fulfill()
            default: XCTFail("Unexpected event sequence")
            }
        }
        events.notifyChanges()
        XCTAssertEqual(events.subscriptions[sid]?.sequence, 0)
        XCTAssertFalse(events.subscriptions[sid]?.sending ?? true)
        events.activate(sid: sid)
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(events.renew(sid: sid, path: "/AVTransport/event", timeout: 1800))
        events.snapshot = { _ in "<state>STOPPED</state>" }
        events.notifyChanges()
        await fulfillment(of: [second], timeout: 3)
        XCTAssertFalse(events.renew(sid: sid, path: "/RenderingControl/event", timeout: 1800))
        XCTAssertTrue(events.unsubscribe(sid: sid, path: "/AVTransport/event"))
        events.notifyChanges()
        XCTAssertTrue(events.subscriptions.isEmpty)
    }

    @MainActor
    func testExpiredSubscriptionsCannotRenew() {
        let events = EventSubscriptions()
        let sid = events.subscribe(path: "/AVTransport/event", callback: URL(string: "http://localhost/callback")!, timeout: -1)
        XCTAssertFalse(events.renew(sid: sid, path: "/AVTransport/event", timeout: 1800))
        XCTAssertTrue(events.subscriptions.isEmpty)
    }

    @MainActor
    func testSubscriptionHTTPValidationAndRenewalKeepsSID() throws {
        let engine = AudioEngine(configureSystemControls: false)
        let server = UPnPHTTPServer(uuid: "test", friendlyName: "Test", engine: engine)
        func request(_ method: String, _ headers: [String: String], path: String = "/AVTransport/event") -> String {
            String(decoding: server.route(request: .init(method: method, path: path, headers: headers, body: "")), as: UTF8.self)
        }
        XCTAssertTrue(request("SUBSCRIBE", [:]).hasPrefix("HTTP/1.1 412"))
        XCTAssertTrue(request("SUBSCRIBE", [:], path: "/unknown/event").hasPrefix("HTTP/1.1 404"))
        let response = request("SUBSCRIBE", ["nt": "upnp:event", "callback": "<http://localhost:12345/callback>", "timeout": "Second-60"])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response.contains("TIMEOUT: Second-60"))
        let sidLine = try XCTUnwrap(response.components(separatedBy: "\r\n").first { $0.hasPrefix("SID: ") })
        let sid = String(sidLine.dropFirst(5))
        XCTAssertTrue(request("SUBSCRIBE", ["sid": sid]).contains(sidLine))
        XCTAssertTrue(request("SUBSCRIBE", ["sid": sid, "nt": "upnp:event"]).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(request("UNSUBSCRIBE", ["sid": sid]).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(request("SUBSCRIBE", ["sid": sid]).hasPrefix("HTTP/1.1 412"))
    }
}
