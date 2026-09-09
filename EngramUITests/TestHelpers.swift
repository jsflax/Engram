import Foundation
import XCTest
import EngramKit
import Lattice

// MARK: - Virtual Key Codes

enum VK {
    static let w: CGKeyCode = 13
    static let a: CGKeyCode = 0
    static let s: CGKeyCode = 1
    static let d: CGKeyCode = 2
    static let q: CGKeyCode = 12
    static let e: CGKeyCode = 14
    static let i: CGKeyCode = 34
    static let j: CGKeyCode = 38
    static let k: CGKeyCode = 40
    static let l: CGKeyCode = 37
    static let t: CGKeyCode = 17
    static let r: CGKeyCode = 15
    static let shift: CGKeyCode = 56
}

// MARK: - Shared UI Test Helpers

extension XCTestCase {

    /// Hold a single key for a specified duration using CGEvent.
    nonisolated func holdKey(_ keyCode: CGKeyCode, duration: TimeInterval) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: duration)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Hold multiple keys simultaneously for a specified duration.
    nonisolated func holdKeys(_ keyCodes: [CGKeyCode], duration: TimeInterval) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for kc in keyCodes {
            CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)?.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: duration)
        for kc in keyCodes.reversed() {
            CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)?.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Take a screenshot, save to /tmp and attach to xcresult.
    @MainActor func takeScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}

// MARK: - Statistics Helpers

/// Format a Double with 2 decimal places, right-aligned in 7 chars.
func fmt(_ v: Double) -> String { String(format: "%7.2f", v) }

/// Compute the p-th percentile from a pre-sorted array.
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
}

// MARK: - CSV Analysis Helpers

/// Parsed metal frame timing row.
struct MetalFrame {
    let idx: Int, dt: Double, wallDt: Double, total: Double
    let drain: Double, sim: Double, mascot: Double, nodes: Double, edges: Double
    let neb: Double, labels: Double, flow: Double
    let nodeCount: Int, edgeCount: Int, reason: String
}

/// Parse /tmp/metal-frame-timing.csv into structured frames.
func parseMetalFrames(path: String = "/tmp/metal-frame-timing.csv") -> [MetalFrame] {
    guard let data = FileManager.default.contents(atPath: path),
          let csv = String(data: data, encoding: .utf8) else { return [] }
    let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
    return lines.enumerated().compactMap { (i, line) in
        let c = line.components(separatedBy: ",")
        guard c.count >= 15 else { return nil }
        return MetalFrame(
            idx: i, dt: Double(c[1]) ?? 0, wallDt: Double(c[2]) ?? 0,
            total: Double(c[3]) ?? 0, drain: Double(c[4]) ?? 0,
            sim: Double(c[5]) ?? 0, mascot: Double(c[6]) ?? 0,
            nodes: Double(c[7]) ?? 0, edges: Double(c[8]) ?? 0, neb: Double(c[9]) ?? 0,
            labels: Double(c[10]) ?? 0, flow: Double(c[11]) ?? 0,
            nodeCount: Int(c[12]) ?? 0, edgeCount: Int(c[13]) ?? 0,
            reason: c[14].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Bottleneck Report

struct BottleneckSection {
    var title: String
    var lines: [String] = []
    var metalP95: Double?

    mutating func addLine(_ line: String) { lines.append(line) }
}

struct BottleneckReport {
    var sections: [BottleneckSection] = []
    var metalP95: Double? { sections.compactMap(\.metalP95).first }

    mutating func addSection(_ section: BottleneckSection) { sections.append(section) }

    func printSummary() {
        print("\n" + String(repeating: "═", count: 70))
        print("  PERFORMANCE BOTTLENECK REPORT")
        print(String(repeating: "═", count: 70))
        for section in sections {
            print("\n── \(section.title) ──")
            for line in section.lines { print(line) }
        }
        print("\n" + String(repeating: "═", count: 70) + "\n")
    }
}

// MARK: - Test Database Seeding

/// Creates a sandboxed Lattice database at the given path, seeded with test memories.
/// Returns the globalIds of the inserted memories.
@discardableResult
func seedDatabase(
    at path: String,
    project: String,
    memoryCount: Int,
    staleAge: TimeInterval,
    withSyncConfig: Bool = false
) -> [UUID] {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    var globalIds: [UUID] = []
    let now = Date()
    let topics = ["architecture", "debugging", "patterns", "conventions", "workflow",
                  "testing", "performance", "rendering", "networking", "ui-components"]
    for i in 0..<memoryCount {
        // Vary embedding so nodes get distinct positions in force simulation
        var embValues = [Float](repeating: 0, count: 384)
        for j in 0..<384 { embValues[j] = sin(Float(i * 17 + j * 3)) * 0.1 }

        let m = Memory(
            content: "Test memory \(i) for \(project): \(topics[i % topics.count]) insight about the codebase",
            topic: topics[i % topics.count],
            project: project,
            source: "e2e-test",
            embedding: Vector<Float>(embValues),
            createdAt: now.addingTimeInterval(Double(-3600 - i * 120)),
            lastAccessedAt: now.addingTimeInterval(-staleAge),
            importance: max(1, (i % 5) + 1)
        )
        try! lattice.add(m)
        if let gid = m.globalId {
            globalIds.append(gid)
        }
    }

    if withSyncConfig {
        try! lattice.add(SyncConfig(project: project, policy: .sync))
    }

    return globalIds
}

/// Seeds a database with multiple projects, returning all globalIds.
/// Creates a realistic graph with edges mirroring the live DB distribution
/// (~8.5 edges per memory: 92% summarized_by, 5% relates_to, 3% part_of).
@discardableResult
func seedMultiProjectDatabase(
    at path: String,
    projects: [(name: String, count: Int)],
    staleAge: TimeInterval,
    withSyncConfig: [String] = []
) -> [UUID] {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    var allIds: [UUID] = []
    var memoriesByProject: [String: [Memory]] = [:]
    let now = Date()
    let topics = ["architecture", "debugging", "patterns", "conventions", "workflow",
                  "testing", "performance", "rendering", "networking", "ui-components"]

    for (project, count) in projects {
        var projectMemories: [Memory] = []
        for i in 0..<count {
            var embValues = [Float](repeating: 0, count: 384)
            let seed = project.hashValue &+ i
            for j in 0..<384 { embValues[j] = sin(Float(seed &* 17 &+ j &* 3)) * 0.1 }

            let m = Memory(
                content: "[\(project)] Memory \(i): \(topics[i % topics.count]) — detailed content about \(project) codebase",
                topic: topics[i % topics.count],
                project: project,
                source: "e2e-test",
                embedding: Vector<Float>(embValues),
                createdAt: now.addingTimeInterval(Double(-7200 - i * 60)),
                lastAccessedAt: now.addingTimeInterval(-staleAge),
                importance: max(1, (i % 5) + 1)
            )
            try! lattice.add(m)
            projectMemories.append(m)
            if let gid = m.globalId { allIds.append(gid) }
        }
        memoriesByProject[project] = projectMemories
    }

    // Add edges: mirrors the real DB distribution (~8.5 edges per memory).
    // Real DB: 92% summarized_by, 5% relates_to, 3% part_of.
    // Three-tier hierarchy:
    //   Tier 1: clusters of 5 with summarized_by fan-out to hub
    //   Tier 2: every 5th hub gets a super-hub (summarized_by from sub-hubs)
    //   Tier 3: cross-cluster relates_to lattice between nearby memories
    // Plus consecutive relates_to chain and part_of clusters.
    for (_, memories) in memoriesByProject where memories.count >= 3 {
        // Consecutive relates_to chain (1 edge per memory)
        for i in 1..<memories.count {
            guard let srcGid = memories[i].globalId,
                  let tgtGid = memories[i - 1].globalId else { continue }
            try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: tgtGid, relation: .relatesTo))
        }

        // Tier 1: clusters of 5 — each member gets summarized_by to hub (~4 edges per 5 = 0.8/memory)
        let tier1Size = 5
        for clusterStart in stride(from: 0, to: memories.count, by: tier1Size) {
            guard let hubGid = memories[clusterStart].globalId else { continue }
            let clusterEnd = min(clusterStart + tier1Size, memories.count)

            for i in (clusterStart + 1)..<clusterEnd {
                guard let srcGid = memories[i].globalId else { continue }
                try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: hubGid, relation: .summarizedBy))
            }

            // part_of: first 2 non-hub members → hub
            for i in (clusterStart + 1)..<min(clusterStart + 3, clusterEnd) {
                guard let srcGid = memories[i].globalId else { continue }
                try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: hubGid, relation: .partOf))
            }
        }

        // Tier 2: super-hubs every 25 memories — each tier-1 hub → super-hub (summarized_by)
        let tier2Size = 25
        for superStart in stride(from: 0, to: memories.count, by: tier2Size) {
            guard let superGid = memories[superStart].globalId else { continue }
            // Link sub-hubs (every tier1Size within this super-cluster) to super-hub
            for subHub in stride(from: superStart + tier1Size, to: min(superStart + tier2Size, memories.count), by: tier1Size) {
                guard let subGid = memories[subHub].globalId else { continue }
                try! lattice.add(Edge(sourceGlobalId: subGid, targetGlobalId: superGid, relation: .summarizedBy))
            }
        }

        // Tier 3: cross-cluster relates_to — every 3rd memory links to one 7 positions ahead
        // This creates a denser web of connections (~0.33 extra edges/memory)
        for i in stride(from: 0, to: memories.count - 7, by: 3) {
            guard let srcGid = memories[i].globalId,
                  let tgtGid = memories[i + 7].globalId else { continue }
            try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: tgtGid, relation: .relatesTo))
        }

        // Additional summarized_by density: every 2nd memory also links to a hub 10 positions back
        // Real DB has many memories summarized by multiple hubs (re-consolidation)
        for i in stride(from: 10, to: memories.count, by: 2) {
            let hubIdx = ((i - 10) / tier1Size) * tier1Size  // nearest earlier hub
            guard let srcGid = memories[i].globalId,
                  let hubGid = memories[hubIdx].globalId else { continue }
            try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: hubGid, relation: .summarizedBy))
        }
    }

    // Cross-project edges: connect hub nodes across projects with realistic density.
    // Real DB has 100-150 cross-project edges between major project pairs.
    let projectKeys = Array(memoriesByProject.keys).sorted()
    for i in 0..<projectKeys.count {
        for j in (i + 1)..<projectKeys.count {
            guard let srcMemories = memoriesByProject[projectKeys[i]],
                  let tgtMemories = memoriesByProject[projectKeys[j]] else { continue }
            // Scale cross-project edges by project size (larger projects have more cross-links)
            let crossCount = min(40, min(srcMemories.count / 5, tgtMemories.count / 5))
            for k in 0..<max(1, crossCount) {
                let srcIdx = k * 5  // hub nodes at multiples of 5
                let tgtIdx = k * 5
                guard srcIdx < srcMemories.count, tgtIdx < tgtMemories.count,
                      let srcGid = srcMemories[srcIdx].globalId,
                      let tgtGid = tgtMemories[tgtIdx].globalId else { continue }
                try! lattice.add(Edge(sourceGlobalId: srcGid, targetGlobalId: tgtGid, relation: .relatesTo))
            }
        }
    }

    for project in withSyncConfig {
        try! lattice.add(SyncConfig(project: project, policy: .sync))
    }

    return allIds
}

/// Opens a separate Lattice connection to the DB at `path` and updates
/// `lastAccessedAt = Date()` on the specified memories. The xproc notification
/// triggers the app's localLattice → IPC → synced observer pipeline.
func triggerRecall(at path: String, globalIds: [UUID]) {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    let now = Date()
    for gid in globalIds {
        for m in lattice.objects(Memory.self).where({ $0.globalId == gid }) {
            m.lastAccessedAt = now
            m.accessCount += 1
        }
    }
}

/// Inserts N new memories into the DB at `path`. Returns their globalIds.
/// The xproc notification triggers the app's live observer → handleNodeInsert.
@discardableResult
func insertMemories(at path: String, project: String, count: Int) -> [UUID] {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    var ids: [UUID] = []
    let now = Date()
    for i in 0..<count {
        var emb = [Float](repeating: 0, count: 384)
        for j in 0..<384 { emb[j] = sin(Float(i &* 31 &+ j &* 7)) * 0.1 }
        let m = Memory(
            content: "[live-insert] \(project) memory \(i): stress test content",
            topic: "debugging",
            project: project,
            source: "perf-test",
            embedding: Vector<Float>(emb),
            createdAt: now,
            lastAccessedAt: now,
            importance: 3
        )
        try! lattice.add(m)
        if let gid = m.globalId { ids.append(gid) }
    }
    return ids
}

/// Deletes memories by globalId from the DB at `path`.
/// The xproc notification triggers the app's live observer → handleNodeDelete.
func deleteMemories(at path: String, globalIds: [UUID]) {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    for gid in globalIds {
        for m in lattice.objects(Memory.self).where({ $0.globalId == gid }) {
            lattice.delete(m)
        }
    }
}

/// Adds cross-galaxy edges between memories in different projects.
/// Useful for testing cross-galaxy edge rendering under migration.
func addCrossProjectEdges(at path: String, sourceIds: [UUID], targetIds: [UUID]) {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    let count = min(sourceIds.count, targetIds.count)
    for i in 0..<count {
        try! lattice.add(Edge(sourceGlobalId: sourceIds[i], targetGlobalId: targetIds[i], relation: .relatesTo))
    }
}

// MARK: - Preview Instrumentation Parsing

/// Parsed preview frame timing row from per-frame CSV.
struct PreviewFrame {
    let frame: Int
    let wallMs: Double
    let forceMs: Double
    let alpha: Double
    let maxSpeedSq: Double
    let minProjSep: Double
    let nodeCount: Int
    let settled: Bool
}

/// Parse preview instrumentation frames CSV.
func parsePreviewFrames(path: String) -> [PreviewFrame] {
    guard let data = FileManager.default.contents(atPath: path),
          let csv = String(data: data, encoding: .utf8) else { return [] }
    return csv.components(separatedBy: "\n").dropFirst().compactMap { line in
        let cols = line.components(separatedBy: ",")
        guard cols.count >= 8 else { return nil }
        return PreviewFrame(
            frame: Int(cols[0]) ?? 0,
            wallMs: Double(cols[1]) ?? 0,
            forceMs: Double(cols[2]) ?? 0,
            alpha: Double(cols[3]) ?? 0,
            maxSpeedSq: Double(cols[4]) ?? 0,
            minProjSep: Double(cols[5]) ?? 0,
            nodeCount: Int(cols[6]) ?? 0,
            settled: cols[7].trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        )
    }
}

/// Parse preview cluster report JSON.
func parseClusterReport(path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Glow Event Parser

struct GlowEvent {
    let timestamp: Double
    let galaxy: String
    let nodeLabel: String
    let deltaSeconds: Double
    let stalenessSeconds: Double
    let alreadyGlowing: Bool
    let glowCount: Int
}

func parseGlowLog() -> [GlowEvent] {
    let path = "/tmp/glow-log.csv"
    guard let data = FileManager.default.contents(atPath: path),
          let csv = String(data: data, encoding: .utf8) else { return [] }

    return csv.components(separatedBy: "\n").dropFirst().compactMap { line in
        let cols = line.components(separatedBy: ",")
        guard cols.count >= 9 else { return nil }
        return GlowEvent(
            timestamp: Double(cols[0]) ?? 0,
            galaxy: cols[1],
            nodeLabel: cols[2],
            deltaSeconds: Double(cols[5]) ?? 0,
            stalenessSeconds: Double(cols[6]) ?? 0,
            alreadyGlowing: cols[7].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            glowCount: Int(cols[8].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        )
    }
}
