import ArgumentParser

@main
struct MemoryHooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory-hooks",
        abstract: "Claude Code hooks for automatic memory recall and learning",
        subcommands: [
            Advise.self,
            OnStart.self,
            OnEnd.self,
            OnStop.self,
            OnFailure.self,
            PreTool.self,
            PreCompact.self,
            ClearMaintenance.self,
            SampleGate.self,
            GroupAdvise.self,
            InternalProcessGuard.self,
        ]
    )
}
