import Foundation

struct PlaybackTrack: Equatable {
    let uri: String
    let metadata: String
}

struct PlaybackQueue {
    private(set) var current: PlaybackTrack?
    private(set) var history: [PlaybackTrack] = []
    private(set) var upcoming: [PlaybackTrack] = []

    var next: PlaybackTrack? { upcoming.first }
    var canGoPrevious: Bool { !history.isEmpty }

    mutating func replaceCurrent(_ track: PlaybackTrack?) {
        if let current, let track, current.uri != track.uri {
            remember(current)
        }
        if track == nil { history.removeAll() }
        current = track
        upcoming.removeAll()
    }

    mutating func setNext(_ track: PlaybackTrack?) {
        upcoming = track.map { [$0] } ?? []
    }

    @discardableResult
    mutating func advance() -> PlaybackTrack? {
        guard !upcoming.isEmpty else { return nil }
        if let current { remember(current) }
        current = upcoming.removeFirst()
        return current
    }

    @discardableResult
    mutating func previous() -> PlaybackTrack? {
        guard let track = history.popLast() else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = track
        return track
    }

    private mutating func remember(_ track: PlaybackTrack) {
        history.append(track)
        if history.count > 100 { history.removeFirst(history.count - 100) }
    }
}
