import Foundation

struct MascotHoloKey: Equatable, Sendable {
    let nodeID: UUID
    let info: HoloTextureRenderer.NodeInfo
}

/// One desired request per project. Old successful cards remain usable while
/// replacements load, and failure/cancellation never marks an image complete.
@MainActor
final class MascotHoloRequestCache {
    enum Action: Equatable {
        case none
        case cancel
        case render(UInt64)
    }
    private struct Entry {
        var desired: MascotHoloKey
        var completed: MascotHoloKey?
        var token: UInt64
        var pending: Bool
        var retryAfter: TimeInterval?
    }
    private var entries: [String: Entry] = [:]
    private var nextToken: UInt64 = 0

    func request(_ key: MascotHoloKey, for project: String,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Action {
        if let entry = entries[project], entry.desired == key {
            if entry.pending || entry.completed == key { return .none }
            if let retryAfter = entry.retryAfter, now < retryAfter { return .none }
        }
        nextToken &+= 1
        let completed = entries[project]?.completed
        let needsRender = completed != key
        entries[project] = Entry(desired: key, completed: completed, token: nextToken,
                                 pending: needsRender, retryAfter: nil)
        return needsRender ? .render(nextToken) : .cancel
    }

    func isCurrent(_ token: UInt64, for project: String) -> Bool {
        guard let entry = entries[project] else { return false }
        return entry.token == token && entry.pending
    }

    func isReady(nodeID: UUID, for project: String) -> Bool {
        guard let entry = entries[project] else { return false }
        return entry.desired.nodeID == nodeID && entry.completed == entry.desired && !entry.pending
    }

    @discardableResult
    func complete(_ token: UInt64, for project: String) -> Bool {
        guard isCurrent(token, for: project) else { return false }
        let desired = entries[project]?.desired
        entries[project]?.completed = desired
        entries[project]?.pending = false
        return true
    }

    func failed(_ token: UInt64, for project: String,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isCurrent(token, for: project) else { return }
        entries[project]?.pending = false
        entries[project]?.retryAfter = now + 1
    }

    func remove(_ project: String) { entries.removeValue(forKey: project) }
}
