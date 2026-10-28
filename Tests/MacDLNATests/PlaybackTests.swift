import XCTest
import AVFoundation
@testable import MacDLNA

final class PlaybackTests: XCTestCase {
    private func track(_ name: String) -> PlaybackTrack {
        PlaybackTrack(uri: "http://localhost/\(name).wav", metadata: name)
    }

    func testNextIsConsumedAndHistoryCanRoundTripWithoutLosingFuture() {
        var queue = PlaybackQueue()
        queue.replaceCurrent(track("A"))
        queue.setNext(track("B"))
        XCTAssertEqual(queue.advance(), track("B"))
        XCTAssertNil(queue.next)
        queue.setNext(track("C"))
        XCTAssertEqual(queue.previous(), track("A"))
        XCTAssertEqual(queue.advance(), track("B"))
        XCTAssertEqual(queue.advance(), track("C"))
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.current, track("C"))
    }

    func testControllerReplacementAndClearDiscardStaleNext() {
        var queue = PlaybackQueue()
        queue.replaceCurrent(track("A"))
        queue.setNext(track("B"))
        queue.setNext(track("C"))
        XCTAssertEqual(queue.next, track("C"))
        queue.replaceCurrent(track("D"))
        XCTAssertNil(queue.next)
        XCTAssertEqual(queue.previous(), track("A"))
        queue.setNext(nil)
        XCTAssertNil(queue.next)
        queue.replaceCurrent(nil)
        XCTAssertFalse(queue.canGoPrevious)
        XCTAssertNil(queue.current)
    }

    func testHistoryIsBoundedAndRepeatedCurrentDoesNotDuplicateHistory() {
        var queue = PlaybackQueue()
        for index in 0..<110 { queue.replaceCurrent(track(String(index))) }
        XCTAssertEqual(queue.history.count, 100)
        queue.replaceCurrent(track("109"))
        XCTAssertEqual(queue.history.count, 100)
        XCTAssertEqual(queue.previous(), track("108"))
    }

    @MainActor
    func testEndNotificationAdvancesOnceAndStopDoesNotAdvance() throws {
        let player = AVPlayer()
        let engine = AudioEngine(player: player, configureSystemControls: false)
        // No network request is needed to exercise end-of-item notifications.
        engine.setURI(uri: "file:///tmp/macdlna-test-a.wav", metadata: nil)
        let first = try XCTUnwrap(player.currentItem)
        engine.setNextURI(uri: "file:///tmp/macdlna-test-b.wav", metadata: nil)
        engine.play()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
        XCTAssertEqual(engine.currentURI, "file:///tmp/macdlna-test-b.wav")
        XCTAssertFalse(engine.canGoNext)
        XCTAssertTrue(engine.canGoPrevious)
        engine.setNextURI(uri: "file:///tmp/macdlna-test-c.wav", metadata: nil)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
        XCTAssertEqual(engine.currentURI, "file:///tmp/macdlna-test-b.wav")
        engine.stop()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        XCTAssertEqual(engine.currentURI, "file:///tmp/macdlna-test-b.wav")
        XCTAssertTrue(engine.canGoNext)
        XCTAssertTrue(engine.previous())
        XCTAssertEqual(engine.currentURI, "file:///tmp/macdlna-test-a.wav")
        XCTAssertTrue(engine.next())
        XCTAssertEqual(engine.currentURI, "file:///tmp/macdlna-test-b.wav")
        engine.setURI(uri: "", metadata: nil)
    }

    @MainActor
    func testSOAPNextMetadataEscapingAndUnavailableActions() {
        let engine = AudioEngine(configureSystemControls: false)
        let server = UPnPHTTPServer(uuid: "test", friendlyName: "Test", engine: engine)
        func soap(_ action: String, _ body: String = "") -> String {
            let request = UPnPHTTPServer.ParsedRequest(method: "POST", path: "/AVTransport/control",
                headers: ["soapaction": "urn:schemas-upnp-org:service:AVTransport:1#\(action)"], body: body)
            return String(decoding: server.route(request: request), as: UTF8.self)
        }
        XCTAssertTrue(soap("Next").contains("<errorCode>701</errorCode>"))
        XCTAssertTrue(soap("Previous").contains("<errorCode>701</errorCode>"))
        XCTAssertTrue(soap("SetNextAVTransportURI", "<InstanceID>1</InstanceID><NextURI>http://localhost/b</NextURI>").contains("<errorCode>718</errorCode>"))
        XCTAssertTrue(soap("SetNextAVTransportURI", "<NextURI>file:///etc/passwd</NextURI>").contains("<errorCode>716</errorCode>"))
        let metadata = "<DIDL-Lite><dc:title>A &amp; B</dc:title></DIDL-Lite>"
        let response = soap("SetNextAVTransportURI", "<NextURI>http://localhost/b?a=1&amp;b=2</NextURI><NextURIMetaData>\(UPnPXMLTemplates.xmlEscape(metadata))</NextURIMetaData>")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(engine.nextURI, "http://localhost/b?a=1&b=2")
        XCTAssertEqual(engine.nextMetadata, metadata)
        let info = soap("GetMediaInfo")
        XCTAssertTrue(info.contains("<NextURI>http://localhost/b?a=1&amp;b=2</NextURI>"))
        XCTAssertTrue(info.contains(UPnPXMLTemplates.xmlEscape(metadata)))
        XCTAssertTrue(soap("SetNextAVTransportURI", "<NextURI/>").hasPrefix("HTTP/1.1 200"))
        XCTAssertFalse(engine.canGoNext)
    }
}
