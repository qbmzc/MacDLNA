import Foundation

// Accessed only on the main thread, alongside transport state.
final class EventSubscriptions {
    struct Subscription {
        let path: String
        let callback: URL
        var expires: Date
        var sequence: UInt32 = 0
        var active = false
        var sending = false
        var pending: [String] = []
    }

    private(set) var subscriptions: [String: Subscription] = [:]
    private let session: URLSession
    var snapshot: (String) -> String = { _ in "" }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func subscribe(path: String, callback: URL, timeout: TimeInterval) -> String {
        removeExpired()
        let sid = "uuid:\(UUID().uuidString.lowercased())"
        subscriptions[sid] = Subscription(path: path, callback: callback,
                                          expires: Date().addingTimeInterval(timeout))
        return sid
    }

    func renew(sid: String, path: String, timeout: TimeInterval) -> Bool {
        removeExpired()
        guard subscriptions[sid]?.path == path else { return false }
        subscriptions[sid]?.expires = Date().addingTimeInterval(timeout)
        return true
    }

    func unsubscribe(sid: String, path: String) -> Bool {
        guard subscriptions[sid]?.path == path else { return false }
        subscriptions.removeValue(forKey: sid)
        return true
    }

    func removeAll() { subscriptions.removeAll() }

    // The initial NOTIFY must follow the successful SUBSCRIBE response.
    func activate(sid: String) {
        guard let subscription = subscriptions[sid], !subscription.active else { return }
        subscriptions[sid]?.active = true
        enqueue(snapshot(subscription.path), sid: sid)
    }

    func notifyChanges() {
        removeExpired()
        for (sid, subscription) in subscriptions where subscription.active {
            enqueue(snapshot(subscription.path), sid: sid)
        }
    }

    private func removeExpired() {
        subscriptions = subscriptions.filter { $0.value.expires > Date() }
    }

    private func enqueue(_ body: String, sid: String) {
        guard var subscription = subscriptions[sid] else { return }
        // Bound memory if a controller goes offline; retain the newest state.
        if subscription.pending.count >= 32 { subscription.pending.removeLast() }
        if subscription.pending.last != body { subscription.pending.append(body) }
        subscriptions[sid] = subscription
        sendNext(sid: sid)
    }

    private func sendNext(sid: String) {
        guard var subscription = subscriptions[sid], !subscription.sending,
              !subscription.pending.isEmpty, subscription.expires > Date() else { return }
        let body = subscription.pending.removeFirst()
        var request = URLRequest(url: subscription.callback, timeoutInterval: 5)
        request.httpMethod = "NOTIFY"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue(String(subscription.sequence), forHTTPHeaderField: "SEQ")
        request.httpBody = Data(body.utf8)
        subscription.sequence = subscription.sequence == UInt32.max ? 1 : subscription.sequence + 1
        subscription.sending = true
        subscriptions[sid] = subscription
        session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.subscriptions[sid] != nil else { return }
                if (response as? HTTPURLResponse)?.statusCode == 412 {
                    self.subscriptions.removeValue(forKey: sid)
                    return
                }
                if error != nil || !((200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)) {
                    AudioEngine.shared.log("播放状态通知未送达，等待控制端恢复连接")
                }
                self.subscriptions[sid]?.sending = false
                self.sendNext(sid: sid)
            }
        }.resume()
    }
}
