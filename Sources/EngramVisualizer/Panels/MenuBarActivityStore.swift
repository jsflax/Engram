import Combine
import EngramKit
import Lattice
import SwiftUI

/// Values, rather than live models, are the only database data read by the menu.
struct MenuBarMemory: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let project: String
    let createdAt: Date

    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor func relativeTimestamp(at now: Date) -> String {
        Self.relativeFormatter.localizedString(for: createdAt, relativeTo: now)
    }
}

@MainActor @Observable
final class MenuBarActivityStore {
    private(set) var rows: [MenuBarMemory] = []
    private(set) var projectColors: [String: Color] = [:]
    @ObservationIgnored private(set) var snapshotReadCount = 0
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored nonisolated(unsafe) private var observation: AnyCancellable?
    @ObservationIgnored nonisolated(unsafe) private var worker: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var continuation: AsyncStream<Void>.Continuation?
    nonisolated private static let unrelatedRowFields: Set<String> = [
        "lastAccessedAt", "accessCount", "embedding", "source", "expiresAt", "importance",
        "isPrivate", "authorUserId", "deletedAt", "deletedBy", "modifiedAt",
    ]

    func start(lattice: Lattice) {
        guard worker == nil else { return }
        generation &+= 1
        let generation = generation
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        // Subscribe before the first read so edits during startup cannot be lost.
        observation = lattice.observe { (logs: [AuditLog]) in
            // Audit payloads are hydrated on Lattice's background delivery
            // worker. Only the invalidation signal crosses into our worker.
            // Delivery may reorder batches; each refresh reads latest state,
            // so no event ordering or row replay is required here.
            for log in logs {
                let shouldRefresh = log.withMaterializedReads {
                    log.tableName == Memory.entityName &&
                        Self.affectsRows(operation: log.operation, changedFields: log.changedFieldsNames)
                }
                if shouldRefresh {
                    continuation.yield(())
                    break
                }
            }
        }
        let reference = lattice.sendableReference
        continuation.yield(())
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let lattice = reference.resolve() else { return }
            var isInitialRead = true
            for await _ in changes {
                // Start the first snapshot immediately; subsequent bursts get
                // one read per 100 ms, with at most one pending refresh.
                if !isInitialRead {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
                isInitialRead = false
                guard !Task.isCancelled else { break }
                let rows = Self.readRows(from: lattice)
                guard !Task.isCancelled else { break }
                await self?.publish(rows, generation: generation)
            }
        }
    }

    func stop() {
        generation &+= 1
        observation?.cancel()
        observation = nil
        continuation?.finish()
        continuation = nil
        worker?.cancel()
        worker = nil
    }

    deinit {
        observation?.cancel()
        continuation?.finish()
        worker?.cancel()
    }

    nonisolated static func affectsRows(operation: AuditLog.Operation, changedFields: [String?]?) -> Bool {
        guard operation == .update else { return true }
        // Missing/unknown metadata must refresh conservatively. Known unrelated
        // fields are common during recall; querying newest rows for every access
        // would repeatedly scan/sort the unindexed creation-date column.
        guard let changedFields else { return true }
        var hasNamedField = false
        for field in changedFields {
            // SQLite's audit trigger leaves null placeholders for unchanged
            // columns. Those are known padding, not missing field metadata.
            guard let field else { continue }
            hasNamedField = true
            if !unrelatedRowFields.contains(field) { return true }
        }
        return !hasNamedField
    }

    nonisolated static func readRows(from lattice: Lattice) -> [MenuBarMemory] {
        assert(!Thread.isMainThread, "Menu snapshots must not query on the main thread")
        // Lattice's iterator does not honor fetchLimit. The explicit SQL snapshot
        // limit also materializes all fields, avoiding per-property SQL queries.
        return lattice.objects(Memory.self)
            .sortedBy(\Memory.createdAt, order: .reverse)
            .materializedSnapshot(limit: 20)
            .compactMap { memory in
                guard let id = memory.globalId else { return nil }
                return MenuBarMemory(id: id,
                              label: extractLabel(content: memory.content, topic: memory.topic),
                              project: memory.project, createdAt: memory.createdAt)
            }
    }

    private func publish(_ rows: [MenuBarMemory], generation: UInt64) {
        guard generation == self.generation else { return }
        snapshotReadCount += 1
        guard self.rows != rows else { return }
        self.rows = rows
        projectColors = Dictionary(uniqueKeysWithValues:
            Set(rows.map(\.project)).sorted().enumerated().map {
                ($0.element, GraphView.goldenAngleColor(at: $0.offset))
            })
    }
}
