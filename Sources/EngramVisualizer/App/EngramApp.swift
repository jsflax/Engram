import SwiftUI
import Lattice
import EngramKit
import GoogleSignIn
import UniformTypeIdentifiers
import ScreenCaptureKit
import Sparkle
import UserNotifications

@main
struct EngramApp: App {
    let localLattice: Lattice
    let lattice: Lattice  // For now, just localLattice. ATTACH'd view added when sync connects.
    let config: VisualizerConfig
    let dbPath: String
    private let updaterController: SPUStandardUpdaterController
    @State private var accountService: AccountService
    @State private var groupService: GroupService
    @State private var syncManager = SyncManager()

    #if SWIFT_PACKAGE && os(macOS)
    private final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            #if !SWIFT_PACKAGE
            UNUserNotificationCenter.current().delegate = self
            #endif
        }

        /// Tapping a notification activates the existing window instead of opening a new instance.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.keyWindow ?? NSApp.orderedWindows.first)?.makeKeyAndOrderFront(nil)
            }
        }

        /// Allow notifications to show even when the app is in the foreground.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner]
        }
    }

    @NSApplicationDelegateAdaptor(Delegate.self) private var appDelegate
    #endif

    init() {
        PerformanceLaunch.beginBenchmarkActivity()
        // ENGRAM_FRAME_STATS (the perf-instrumentation harness) and headless
        // launches never want Sparkle: a terminal-launched unsigned binary
        // can't reach the appcast, so startingUpdater:true throws a modal
        // NSAlert that captures the main thread before the scene ever renders.
        let startUpdater = !PerformanceLaunch.isIsolated
            && ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] == nil
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startUpdater, updaterDelegate: nil, userDriverDelegate: nil
        )

        let account = AccountService()
        _accountService = State(initialValue: account)
        _groupService = State(initialValue: GroupService(account: account))

        #if ENGRAM_INSTRUMENTATION
        // Redirect stderr to a file so Lattice C++ debug logs are captured during UI tests
        // (the app runs in a separate process whose stderr isn't in xcodebuild output)
        freopen("/tmp/lattice-debug.log", "w", stderr)
        
        #endif
        Lattice.setLogLevel(.error)
        let dbPath = PerformanceLaunch.databasePath
        self.dbPath = dbPath

        // Local DB — full schema. The sync daemon handles IPC relay separately.
        let localConfig = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: dbPath),
            migration: engramMigrations
        )
        let local = try! Lattice(
            Memory.self, Edge.self, Checkpoint.self, VisualizerConfig.self, SyncConfig.self, HookState.self,
            configuration: localConfig
        )
        // Sealed-query failures (lattice 1.4.1): a query that fails under
        // e.g. memory pressure returns EMPTY instead of crashing the app —
        // this is the visibility channel for those, so a degraded load is
        // diagnosable from the console instead of silent.
        local.onQueryError { message in
            print("[lattice] query failed (degraded to empty result): \(message)")
        }
        localLattice = local
        lattice = local

        config = local.objects(VisualizerConfig.self).first ?? {
            let c = VisualizerConfig()
            // Same posture as the `try! Lattice(...)` above: without a
            // config row the app has nothing to render.
            try! local.add(c)
            return c
        }()
        // Allow tests to force sound on via environment
        if ProcessInfo.processInfo.environment["ENGRAM_FORCE_SOUND"] == "1" {
            config.soundEnabled = true
        }

        // Configure Google Sign-In if client ID is available
        if let googleClientID = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"]
            ?? Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: googleClientID)
        }

        if !PerformanceLaunch.isIsolated {
            Task.detached { CLIInstaller.syncIfNeeded() }
        } else {
            config.notificationsEnabled = false
            if PerformanceLaunch.usesTemporaryDatabase {
                config.hiddenProjects = []
                config.hiddenRelations = []
            }
        }

        // Test hook: insert a test memory after a delay for jitter profiling
        if let delayStr = ProcessInfo.processInfo.environment["ENGRAM_TEST_INSERT_DELAY"],
           let delay = Double(delayStr) {
            let ref = local.sendableReference
            Task { @ForceSimulatorActor in
                let bg = ref.resolve()!
                try? await Task.sleep(for: .seconds(delay))
                let m = Memory()
                m.content = "UI test memory inserted at \(Date()) for jitter profiling"
                m.project = "Engram"
                m.topic = "profiling"
                m.importance = 3
                m.embedding = Vector<Float>([Float](repeating: 0.01, count: 384))
                m.createdAt = Date()
                m.lastAccessedAt = Date()
                try? bg.add(m)
                try? await Task.sleep(for: .seconds(3))
                try? bg.delete(m)
            }
        }
    }

    private func autoConnectSync() {
        guard !PerformanceLaunch.isIsolated,
              let wsURL = accountService.syncWebSocketURL,
              let token = accountService.token,
              !syncManager.isSyncing else { return }
        syncManager.connectSync(wssEndpoint: wsURL, authToken: token)
    }

    var body: some Scene {
        WindowGroup("Engram") {
            GraphView(syncManager: syncManager)
                .environment(\.lattice, lattice)
                .environment(config)
                .environment(accountService)
                .environment(groupService)
                .environment(syncManager)
                .frame(minWidth: 800, minHeight: 600)
                .ignoresSafeArea()
                .onAppear {
                    syncManager.initialize(lattice: localLattice)
                    // Signed in is enough to run the daemon: a group seat is
                    // billed on the group, so waiting for a PERSONAL
                    // subscription would leave group-only members with no
                    // sync. The daemon decides what it may actually open.
                    if accountService.isSignedIn { syncManager.startDaemonIfSignedIn() }
                    autoConnectSync()
                }
                .onChange(of: accountService.isSignedIn) { _, signedIn in
                    if signedIn { syncManager.startDaemonIfSignedIn() }
                }
                .onChange(of: accountService.subscription?.isActive) { _, active in
                    if active == true {
                        autoConnectSync()
                    }
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .saveItem) {
                Button("Export as PNG…") {
                    Task {
                        guard let pngData = await captureWindowPNG() else { return }
                        await MainActor.run {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.png]
                            panel.nameFieldStringValue = "memory-graph.png"
                            panel.begin { response in
                                if response == .OK, let url = panel.url {
                                    try? pngData.write(to: url)
                                }
                            }
                        }
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            MenuBarActivityFeed()
                .environment(\.lattice, lattice)
                .environment(accountService)
                .environment(syncManager)
        } label: {
            Image(systemName: "brain.head.profile")
                .accessibilityLabel("Engram activity")
                .accessibilityIdentifier("engram.status-item")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Capture the key window as PNG using ScreenCaptureKit (works with Metal/RealityKit content).
@MainActor
private func captureWindowPNG() async -> Data? {
    guard let nsWindow = NSApp.keyWindow else { return nil }
    let windowID = CGWindowID(nsWindow.windowNumber)

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(nsWindow.frame.width * (nsWindow.screen?.backingScaleFactor ?? 2))
        config.height = Int(nsWindow.frame.height * (nsWindow.screen?.backingScaleFactor ?? 2))
        config.captureResolution = .best
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    } catch {
        // Fallback: NSView bitmap (may miss Metal content)
        guard let contentView = nsWindow.contentView else { return nil }
        let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        guard let rep else { return nil }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
