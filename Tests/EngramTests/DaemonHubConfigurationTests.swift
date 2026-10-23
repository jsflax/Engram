@testable import EngramKit
import Foundation
import Lattice
import Testing

@Suite("Daemon hub configuration")
struct DaemonHubConfigurationTests {
    @Test func daemonHubConfigurationCarriesTheInteractiveBusyTimeout() {
        let targets = [Lattice.IPCSyncTarget(channel: "engram-sync", syncFilter: nil)]
        let config = SyncService.daemonHubConfiguration(dbPath: "/tmp/fixture-hub.sqlite", ipcTargets: targets)
        #expect(config.busyTimeoutMs == 2_000)
        #expect(config.busyTimeoutMs == SyncService.daemonHubBusyTimeoutMs)
        #expect(config.busyTimeoutMsWasCustomized)
        #expect(config.fileURL.path == "/tmp/fixture-hub.sqlite")
        #expect((config.ipcTargets ?? []).map { $0.channel } == ["engram-sync"])
        #expect(config.migration != nil)
    }
}
