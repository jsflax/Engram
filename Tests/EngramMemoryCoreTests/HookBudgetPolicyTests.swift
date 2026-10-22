import Foundation
import Testing
@testable import EngramMemoryCore

@Suite("HookBudgetPolicy")
struct HookBudgetPolicyTests {

    @Test func secondaryAttachesStandDownPastFortyPercent() {
        // A fake clock: 7 s of a 15 s budget already spent on hub open + embedder.
        #expect(!HookBudgetPolicy.shouldAttachSecondary(elapsed: 7, budget: 15))
        #expect(HookBudgetPolicy.shouldAttachSecondary(elapsed: 5.9, budget: 15))
        #expect(HookBudgetPolicy.shouldAttachSecondary(elapsed: 6.0, budget: 15))
        #expect(!HookBudgetPolicy.shouldAttachSecondary(elapsed: 6.1, budget: 15))
        #expect(!HookBudgetPolicy.shouldAttachSecondary(elapsed: 1, budget: 0))
        #expect(!HookBudgetPolicy.shouldAttachSecondary(elapsed: .nan, budget: 15))
    }

    @Test func maintenanceCheckNeedsBudgetAndHeadroom() {
        // 7 s elapsed of 15 → 8 s remaining is fine on an idle machine...
        #expect(HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 8, loadAverage: 3, processorCount: 16))
        // ...but not with the load average over 2× ncpu (the 2026-10-21 state: 100–300 on 16 cores).
        #expect(!HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 8, loadAverage: 103.9, processorCount: 16))
        #expect(!HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 8, loadAverage: 32.1, processorCount: 16))
        #expect(HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 8, loadAverage: 32.0, processorCount: 16))
        // Below 2 s remaining it never runs, whatever the load.
        #expect(!HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 1.9, loadAverage: 0, processorCount: 16))
        #expect(HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: 2.0, loadAverage: nil, processorCount: 16))
    }

    @Test func ceilingOverrideParsesAndClamps() {
        #expect(HookBudgetPolicy.ceilingSeconds(environment: [:]) == 15)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": ""]) == 15)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "abc"]) == 15)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "inf"]) == 15)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "8"]) == 8)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": " 20.5 "]) == 20.5)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "1"]) == 3)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "-4"]) == 3)
        #expect(HookBudgetPolicy.ceilingSeconds(environment: ["ENGRAM_HOOK_RECALL_CEILING_S": "600"]) == 60)
    }

    @Test func loadAverageIsReadableOnThisPlatform() {
        let load = HookBudgetPolicy.loadAverage1m()
        #expect(load.map { $0 >= 0 } ?? true)
    }
}
