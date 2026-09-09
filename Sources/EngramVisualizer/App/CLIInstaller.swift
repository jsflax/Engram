import Foundation
import EngramKit

enum CLIInstaller {
    private static let claudeDir = NSHomeDirectory() + "/.claude"
    private static let installDir = claudeDir + "/bin"
    private static let agentsDir = claudeDir + "/agents"
    private static let skillsDir = claudeDir + "/skills"
    private static let versionFile = installDir + "/.memory-version"

    enum InstallError: Error {
        case missingBundledBinary(String)
        case verificationFailed(String)
    }
    private static let claudeMDPath = claudeDir + "/CLAUDE.md"
    private static let settingsPath = claudeDir + "/settings.json"

    static func syncIfNeeded() {
        guard let bundledVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let cliDir = Bundle.main.resourceURL?.appendingPathComponent("cli")
        else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: cliDir.path) else { return }

        // Independent of Claude and of the CLI version stamp: retry after a
        // user installs Codex/Python, even when Engram itself is up to date.
        // Interpreter discovery and config I/O must not block app startup.
        // Schedule after any binary replacement below, so a fresh install's
        // memory command exists before the Codex registration is validated.
        defer {
            DispatchQueue.global(qos: .utility).async {
                syncCodexSupport(from: cliDir)
            }
        }

        let installedVersion = (try? String(contentsOfFile: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard installedVersion == nil || compareVersions(bundledVersion, isNewerThan: installedVersion!) else {
            return
        }

        let isFirstInstall = installedVersion == nil

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)

            // Copy CLI binaries. Two field failures shaped this loop:
            // (1) Sparkle-updated app bundles carry com.apple.quarantine on
            //     every file — a faithful copy is then BLOCKED by Gatekeeper
            //     when Claude Code spawns it (silent, hooks swallow stderr).
            //     Strip the xattr after each copy (signature stays intact).
            // (2) A missing source or failed copy used to skip silently and
            //     still stamp the version, wedging the install until the
            //     next release. Missing binaries are now an error, and the
            //     result is verified below before the version stamp.
            let binaries = ["memory", "memory-hooks", "memory-sync"]
            for binary in binaries {
                let src = cliDir.appendingPathComponent(binary)
                let dst = URL(fileURLWithPath: installDir).appendingPathComponent(binary)
                guard fm.fileExists(atPath: src.path) else {
                    throw InstallError.missingBundledBinary(binary)
                }
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                removexattr(dst.path, "com.apple.quarantine", 0)  // ENOATTR is fine
            }

            // Copy .bundle resources
            if let contents = try? fm.contentsOfDirectory(atPath: cliDir.path) {
                for item in contents where item.hasSuffix(".bundle") {
                    let src = cliDir.appendingPathComponent(item)
                    let dst = URL(fileURLWithPath: installDir).appendingPathComponent(item)
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: src, to: dst)
                }
            }

            // Copy agent definitions
            let agentsSrc = cliDir.appendingPathComponent("agents")
            if fm.fileExists(atPath: agentsSrc.path) {
                try fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
                if let agents = try? fm.contentsOfDirectory(atPath: agentsSrc.path) {
                    for agent in agents where agent.hasSuffix(".md") {
                        let src = agentsSrc.appendingPathComponent(agent)
                        let dst = URL(fileURLWithPath: agentsDir).appendingPathComponent(agent)
                        try? fm.removeItem(at: dst)
                        try fm.copyItem(at: src, to: dst)
                    }
                }
            }

            // Copy skill definitions
            let skillsSrc = cliDir.appendingPathComponent("skills")
            if fm.fileExists(atPath: skillsSrc.path) {
                if let skillDirs = try? fm.contentsOfDirectory(atPath: skillsSrc.path) {
                    for skillName in skillDirs {
                        let srcDir = skillsSrc.appendingPathComponent(skillName)
                        let dstDir = URL(fileURLWithPath: skillsDir).appendingPathComponent(skillName)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: srcDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                        let skillFile = srcDir.appendingPathComponent("SKILL.md")
                        if fm.fileExists(atPath: skillFile.path) {
                            let dst = dstDir.appendingPathComponent("SKILL.md")
                            try? fm.removeItem(at: dst)
                            try fm.copyItem(at: skillFile, to: dst)
                        }
                    }
                }
            }

            // Install sync daemon launchd plist
            installDaemonPlist()

            // Verify before stamping: every binary must exist, be executable,
            // and carry no quarantine. A failed install retries next launch
            // instead of wedging until the next release.
            for binary in binaries {
                let path = installDir + "/" + binary
                guard fm.isExecutableFile(atPath: path) else {
                    throw InstallError.verificationFailed(binary)
                }
                if getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 {
                    throw InstallError.verificationFailed("\(binary) (still quarantined)")
                }
            }

            // Write version marker
            try bundledVersion.write(toFile: versionFile, atomically: true, encoding: .utf8)

            // Register MCP server (re-register on upgrade to update path if needed)
            registerMCPServer(isFirstInstall: isFirstInstall)

            // Install CLAUDE.md instructions and hooks config
            installClaudeMD()
            installSettings()
        } catch {
            // Best-effort — don't crash the app if CLI sync fails
        }
    }

    // MARK: - Sync Daemon

    /// Deploy the same payload as the shell installer, then delegate owned
    /// hook merging to its shared Python installer. The installer is
    /// idempotent and preserves user hooks, config, state, and backups.
    private static func syncCodexSupport(from cliDir: URL) {
        let fm = FileManager.default
        let source = cliDir.appendingPathComponent("codex")
        guard fm.fileExists(atPath: source.appendingPathComponent("install_codex_support.sh").path) else {
            return
        }
        let destination = URL(fileURLWithPath: installDir).appendingPathComponent("codex")
        do {
            guard let files = fm.enumerator(at: source,
                                            includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else {
                throw InstallError.missingBundledBinary("codex")
            }
            for case let file as URL in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
                let relativePath = String(file.path.dropFirst(source.path.count + 1))
                let target = destination.appendingPathComponent(relativePath)
                if fm.contentsEqual(atPath: file.path, andPath: target.path) { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: file).write(to: target, options: .atomic)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [destination.appendingPathComponent("install_codex_support.sh").path, "install"]
            proc.environment = cleanEnv()
            let output = Pipe()
            proc.standardOutput = output
            proc.standardError = output
            try proc.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let message = String(decoding: data.suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { NSLog("Engram Codex installer: %@", message) }
            if proc.terminationStatus != 0 {
                NSLog("Engram Codex installer exited %d; retrying on next app launch", proc.terminationStatus)
            }
        } catch {
            NSLog("Engram Codex installation failed; retrying on next app launch: %@", String(describing: error))
        }
    }

    private static let daemonLabel = "io.engram.sync"
    private static let daemonPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/io.engram.sync.plist"
    private static let daemonBinary = installDir + "/memory-sync"
    private static let uid = getuid()

    /// Rewrite the daemon plist from current settings and restart it.
    /// Called whenever the sync endpoint changes (or a stale dev endpoint is
    /// migrated away) — the plist snapshots --endpoint at write time, so
    /// without a refresh the daemon keeps launching against the old host
    /// until the next version bump reruns the installer.
    static func refreshDaemonPlist() {
        installDaemonPlist()
    }

    private static func installDaemonPlist() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: daemonBinary) else { return }

        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Propagate the user's configured endpoint to the daemon. Without
        // --endpoint the daemon fell back to its hardcoded default, so a
        // non-default endpoint set in the UI never reached sync (auth went to
        // one host, relay to another). Only pass it when it differs from the
        // daemon's own default, to keep the common case argument-free.
        var args = [daemonBinary]
        let configured = UserDefaults.standard.string(forKey: "sync_endpoint")
        if let configured, !configured.isEmpty, configured != "https://engramdb.io" {
            args += ["--endpoint", configured]
        }

        let plist: [String: Any] = [
            "Label": daemonLabel,
            "ProgramArguments": args,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "StandardErrorPath": claudeDir + "/sync-daemon-launchd.log",
            "ProcessType": "Background",
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }

        // Bootout existing before overwriting
        launchctl(["bootout", "gui/\(uid)/\(daemonLabel)"])

        // Clean up old label if present
        let oldPlist = NSHomeDirectory() + "/Library/LaunchAgents/io.engram.sync-daemon.plist"
        if fm.fileExists(atPath: oldPlist) {
            launchctl(["bootout", "gui/\(uid)/io.engram.sync-daemon"])
            try? fm.removeItem(atPath: oldPlist)
        }

        fm.createFile(atPath: daemonPlistPath, contents: data)

        launchctl(["bootstrap", "gui/\(uid)", daemonPlistPath])
    }

    /// Start the daemon via launchctl (called on sign-in).
    static func startDaemon() {
        launchctl(["bootstrap", "gui/\(uid)", daemonPlistPath])
    }

    /// Unload the daemon (called on sign-out).
    static func stopDaemon() {
        launchctl(["bootout", "gui/\(uid)/\(daemonLabel)"])
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    // MARK: - MCP Server Registration

    private static func registerMCPServer(isFirstInstall: Bool) {
        let env = cleanEnv()

        // Remove first to ensure clean state (matches install.sh behavior)
        if !isFirstInstall {
            let remove = Process()
            remove.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            remove.arguments = ["claude", "mcp", "remove", "memory"]
            remove.environment = env
            try? remove.run()
            remove.waitUntilExit()
        }

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        add.arguments = [
            "claude", "mcp", "add", "--scope", "user", "--transport", "stdio",
            "memory", "--", "\(installDir)/memory"
        ]
        add.environment = env
        try? add.run()
    }

    // MARK: - CLAUDE.md

    private static func installClaudeMD() {
        let fm = FileManager.default
        let memoryBlock = InstallConfig.memoryBlockMarkdown

        if fm.fileExists(atPath: claudeMDPath) {
            guard let existing = try? String(contentsOfFile: claudeMDPath, encoding: .utf8) else { return }

            if existing.contains("\n# Memory\n") || existing.hasPrefix("# Memory\n") {
                // Replace existing Memory section
                let lines = existing.components(separatedBy: "\n")
                var result: [String] = []
                var skipping = false
                for line in lines {
                    if line == "# Memory" {
                        skipping = true
                        continue
                    }
                    if skipping && line.hasPrefix("# ") {
                        skipping = false
                    }
                    if !skipping {
                        result.append(line)
                    }
                }
                // Trim trailing blank lines
                while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.removeLast()
                }
                let updated = result.joined(separator: "\n") + "\n\n" + memoryBlock + "\n"
                try? updated.write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
            } else {
                // Append Memory section
                let updated = existing.trimmingCharacters(in: .newlines) + "\n\n" + memoryBlock + "\n"
                try? updated.write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
            }
        } else {
            // Create new file
            try? (memoryBlock + "\n").write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - settings.json (hooks)

    /// Register our hooks without stepping on the user's settings.
    ///
    /// The merge itself is `HookSettingsMerge` — a pure function on parsed
    /// dictionaries, so it can be tested without touching the real
    /// `~/.claude/settings.json`. All this does is the file I/O around it.
    private static func installSettings() {
        let fm = FileManager.default
        let shipped = InstallConfig.hooksSettings(installDir: installDir)

        let payload: [String: Any]
        if fm.fileExists(atPath: settingsPath) {
            // A settings.json we cannot parse is left ALONE: overwriting it
            // would destroy hand-written configuration we never read.
            guard let data = fm.contents(atPath: settingsPath),
                  let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            payload = HookSettingsMerge.merged(existingSettings: existing, shipped: shipped)
        } else {
            payload = shipped
        }

        if let json = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: settingsPath))
        }
    }

    // MARK: - Helpers

    private static func cleanEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }

    private static func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}
