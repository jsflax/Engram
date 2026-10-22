import Foundation
import Testing
@testable import EngramMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("SpawnAdmission")
struct SpawnAdmissionTests {

    private func stateDirectory() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func gate(_ dir: String, now: Date = Date(), load: Double? = 1.0,
                      alive: @escaping @Sendable (Int32) -> Bool = { _ in true }) -> SpawnAdmission {
        SpawnAdmission(stateDirectory: dir, now: { now }, loadAverage: { load },
                       processorCount: 8, isAlive: alive)
    }

    @Test func liveLearnerRefusesAnotherSpawnAndDoesNotExec() throws {
        let dir = try stateDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A learner recorded by a previous hook, with a pid that answers.
        let earlier = gate(dir, now: Date(timeIntervalSinceNow: -3600))
        let first = try earlier.admit(kind: .learner) { getpid() }
        #expect(first == .admitted(pid: getpid()))

        var executed = false
        let verdict = try gate(dir).admit(kind: .maintenance) { executed = true; return 4242 }
        #expect(!executed, "the spawn closure must not run when refused")
        guard case .refusedConcurrent(let active) = verdict else {
            Issue.record("expected refusedConcurrent, got \(verdict)"); return
        }
        #expect(active.map(\.pid) == [getpid()])
        #expect(active.map(\.kind) == [.learner])
        #expect(verdict.description.hasPrefix("skipped: concurrency"))
    }

    @Test func deadPidIsPrunedThenCooldownApplies() throws {
        let dir = try stateDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let t0 = Date()
        _ = try gate(dir, now: t0).admit(kind: .learner) { 999_999 }

        // Five minutes later the learner is gone but the 10-minute cooldown holds.
        var executed = false
        let verdict = try gate(dir, now: t0.addingTimeInterval(300), alive: { _ in false })
            .admit(kind: .learner) { executed = true; return 1 }
        #expect(!executed)
        guard case .refusedCooldown(let remaining) = verdict else {
            Issue.record("expected refusedCooldown, got \(verdict)"); return
        }
        #expect(remaining > 299 && remaining <= 300)
        #expect(verdict.description.hasPrefix("skipped: cooldown"))

        // Past the cooldown it is admitted again and recorded.
        let later = try gate(dir, now: t0.addingTimeInterval(601), alive: { _ in false })
            .admit(kind: .learner) { 7 }
        #expect(later == .admitted(pid: 7))
        #expect(gate(dir, now: t0.addingTimeInterval(602)).liveEntries().map(\.pid) == [7])
    }

    @Test func saturatedMachineRefuses() throws {
        let dir = try stateDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var executed = false
        // 8 processors × factor 2 = 16; a 1-minute load of 100 refuses.
        let verdict = try gate(dir, load: 100).admit(kind: .learner) { executed = true; return 1 }
        #expect(!executed)
        #expect(verdict == .refusedLoad(loadAverage: 100, limit: 16))
        #expect(verdict.description.hasPrefix("skipped: load average"))
        // Unknown load never blocks.
        #expect(try gate(dir, load: nil).admit(kind: .learner) { 2 } == .admitted(pid: 2))
    }

    @Test func staleEntriesArePrunedEvenWhenThePidAnswers() throws {
        let dir = try stateDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let t0 = Date()
        _ = try gate(dir, now: t0).admit(kind: .maintenance) { getpid() }
        // Four hours later a pid that still answers is treated as reused.
        let verdict = try gate(dir, now: t0.addingTimeInterval(4 * 3600)).admit(kind: .learner) { 3 }
        #expect(verdict == .admitted(pid: 3))
    }

    @Test func spawnedCommandRunsClaudeUnderNice() {
        let command = claudeSubprocessShellCommand(
            prompt: "p", systemPrompt: "s", allowedTools: "mcp__memory__*", model: "sonnet",
            logPath: "/tmp/fixture.log")
        #expect(command.contains("/usr/bin/nice -n 10 claude -p 'p'"))
        #expect(!command.contains("; claude -p"))
    }

    @Test func envGuardSelectsTheKind() {
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_LEARNER") == .learner)
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_MAINTENANCE") == .maintenance)
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_SYNC_RECONCILIATION") == .reconciliation)
        #expect(SpawnOutcome.kind(forEnvGuard: "OTHER") == .other)
    }
}
