import RealityKit
import AVFoundation
import Foundation
import simd
import os

private let audioLog = Logger(subsystem: "com.claudememory.engram", category: "RKSpatialAudio")

/// RealityKit-native spatial audio system.
///
/// Replaces the bespoke AVAudioEngine + HRTF setup with RealityKit's built-in
/// spatial audio. Audio sources are attached directly to entities — the scene
/// graph IS the audio graph. No manual position syncing needed.
///
/// Entity pools are allocated once and reused across rescans. PHASE's spatial
/// modeler keeps references to source entities — removing them from the scene
/// while PHASE still tracks them causes invalid-source errors. Instead, inactive
/// voices are muted and parked at the origin.
///
/// Subsystems:
/// - **Proximity tones**: Quiet ambient tones on nearby nodes (importance → frequency)
/// - **Edge hums**: Subtle hum on edges connected to selected node
/// - **Event sounds**: One-shot sounds for recall glow, node create/delete
/// - **Mascot thruster**: Looping engine hum on mascot entities
@MainActor
public final class RKSpatialAudioSystem {

    // MARK: - Configuration

    /// Maximum number of concurrent proximity tone voices.
    public var maxProximityVoices: Int = 8
    /// Maximum number of concurrent edge hum voices.
    public var maxEdgeHumVoices: Int = 6
    /// Whether audio is enabled.
    public var isEnabled: Bool = true {
        didSet { if !isEnabled { stopAll() } }
    }
    /// Legacy desktop diagnostic. Embedded hosts can suppress its startup tone
    /// independently of the graph's actual proximity/edge/event audio.
    public var playsStartupDiagnosticTone = true

    // MARK: - Audio Resources (generated once)

    private var proximityToneResources: [Int: AudioFileResource] = [:]  // importance → resource
    private var edgeHumResource: AudioFileResource?
    private var recallGlowResource: AudioFileResource?
    private var nodeCreateResource: AudioFileResource?
    private var nodeDeleteResource: AudioFileResource?
    private var thrusterResource: AudioFileResource?

    // MARK: - Voice Pools

    /// A reusable audio voice entity. Stays in the scene graph permanently.
    private struct Voice {
        let entity: Entity
        var controller: AudioPlaybackController?
        var currentResourceKey: Int = -1  // importance for proximity, 0 for edge
        var isActive: Bool = false
    }

    private var proximityPool: [Voice] = []
    private var edgePool: [Voice] = []
    private var poolsInitialized = false

    // MARK: - Event Sound Entities (one-shot, cleaned up after playback)

    private var activeMascotControllers: [String: AudioPlaybackController] = [:]
    private var pendingGlowNodes: Set<UUID> = []

    /// Temp WAV files that back AudioFileResources. PHASE loads audio data
    /// asynchronously — files must stay on disk until the system is torn down.
    private var tempFileURLs: [URL] = []
    private var eventVoices: [UUID: (Entity, AudioPlaybackController, Task<Void, Never>)] = [:]
    private var isTornDown = false

    // MARK: - Throttling

    private var frameCount: UInt64 = 0
    private let rescanInterval: UInt64 = 10  // rescan every 10 frames (~6Hz at 60fps)

    // MARK: - Init

    public init() {
        generateAudioResources()
        let proxCount = proximityToneResources.count
        let hasEdge = edgeHumResource != nil
        let hasGlow = recallGlowResource != nil
        let hasThruster = thrusterResource != nil
        audioLog.info("RKSpatialAudioSystem init: proximity=\(proxCount)/5, edge=\(hasEdge), glow=\(hasGlow), thruster=\(hasThruster)")
    }

    // MARK: - Pool Setup

    /// Create persistent voice entities and add them to the scene root.
    /// Called once on first update when the scene is fully wired.
    private func setupPools(root: Entity) {
        guard !poolsInitialized else { return }
        poolsInitialized = true

        // Proximity voice pool — use AmbientAudioComponent (non-spatial, no listener needed)
        for i in 0..<maxProximityVoices {
            let entity = Entity()
            entity.name = "ProximityTone_\(i)"
            root.addChild(entity)
            proximityPool.append(Voice(entity: entity))
        }

        // Edge voice pool
        for i in 0..<maxEdgeHumVoices {
            let entity = Entity()
            entity.name = "EdgeHum_\(i)"
            root.addChild(entity)
            edgePool.append(Voice(entity: entity))
        }

        audioLog.debug("Audio pools initialized: \(self.maxProximityVoices) proximity, \(self.maxEdgeHumVoices) edge")

        // Smoke test: play a tone on the root entity with AmbientAudioComponent
        // to verify audio output works at all on this system.
        if playsStartupDiagnosticTone, let testResource = proximityToneResources[3] {
            let testEntity = Entity()
            testEntity.name = "AudioSmokeTest"
            var ambient = AmbientAudioComponent()
            ambient.gain = -5.0  // loud enough to definitely hear
            testEntity.components.set(ambient)
            root.addChild(testEntity)

            let controller = testEntity.playAudio(testResource)
            audioLog.info("Audio smoke test: playing 440Hz tone via AmbientAudioComponent, controller.isPlaying=\(controller.isPlaying)")

            // Stop after 3 seconds
            let id = UUID()
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                controller.stop()
                testEntity.removeFromParent()
                self?.eventVoices.removeValue(forKey: id)
                audioLog.info("Audio smoke test: stopped")
            }
            eventVoices[id] = (testEntity, controller, task)
        } else if playsStartupDiagnosticTone {
            audioLog.error("Audio smoke test: no proximity tone resource for importance 3")
        }
    }

    // MARK: - Per-Frame Update

    public func update(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        dt: Float
    ) {
        guard isEnabled, !isTornDown else { return }

        // Lazy pool setup — needs scene root to be in the RealityView
        if !poolsInitialized {
            setupPools(root: scene.rootEntity)
        }

        frameCount += 1

        // Throttled rescan for proximity tones + edge hums
        if frameCount % rescanInterval == 0 {
            updateProximityTones(scene: scene, dataProvider: dataProvider, visibleSet: visibleSet)
            updateEdgeHums(scene: scene, dataProvider: dataProvider)
        }

        // Event sounds — check for new glow events every frame
        updateEventSounds(scene: scene, dataProvider: dataProvider)
    }

    // MARK: - Proximity Tones

    /// Assign proximity tones to nearest visible nodes.
    /// Reuses pooled entities — only repositions and swaps audio resources when needed.
    private func updateProximityTones(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet
    ) {
        guard let cameraProvider = scene.cameraProvider else {
            muteAllProximity()
            return
        }
        let cameraPos = cameraProvider.cameraState.cameraPosition
        let nodes = dataProvider.nodes
        let positions = dataProvider.positions
        let scaleFactor = scene.scaleFactor

        // Find nearest nodes from the near tier
        var candidates: [(index: Int, distance: Float)] = []
        for idx in visibleSet.nearNodes {
            let node = nodes[idx]
            guard let pos = positions[node.id] else { continue }
            let dist = simd_length(pos - cameraPos)
            candidates.append((idx, dist))
        }
        candidates.sort { $0.distance < $1.distance }

        // Assign tones to nearest N nodes
        let activeCount = min(candidates.count, maxProximityVoices)
        if frameCount < 100 && frameCount % rescanInterval == 0 {
            audioLog.debug("Proximity rescan: nearNodes=\(visibleSet.nearNodes.count) candidates=\(candidates.count) active=\(activeCount) cam=(\(cameraPos.x, format: .fixed(precision: 0)),\(cameraPos.y, format: .fixed(precision: 0)),\(cameraPos.z, format: .fixed(precision: 0)))")
        }

        // Hard audibility cutoff. Two bugs made tones audible from anywhere:
        // the manual gain floored at -30 dB (quiet but never silent), and the
        // quantile LOD rewrite made near-tier membership RELATIVE — the 8
        // relatively-nearest nodes qualified even with the camera far from
        // everything. Beyond this range a voice mutes outright.
        let audibleRange: Float = 420

        for i in 0..<maxProximityVoices {
            if i < activeCount, candidates[i].distance < audibleRange {
                let idx = candidates[i].index
                let node = nodes[idx]
                let dist = candidates[i].distance
                guard let pos = positions[node.id] else {
                    muteVoice(&proximityPool[i])
                    continue
                }

                let importance = max(1, min(5, node.importance))
                guard let resource = proximityToneResources[importance] else {
                    muteVoice(&proximityPool[i])
                    continue
                }

                // Reposition
                proximityPool[i].entity.position = pos * scaleFactor

                // Swap resource if importance changed (different tone frequency)
                if proximityPool[i].currentResourceKey != importance || !proximityPool[i].isActive {
                    proximityPool[i].controller?.stop()

                    // Use AmbientAudioComponent for reliable output (no listener dependency)
                    var ambient = AmbientAudioComponent()
                    ambient.gain = -10.0
                    proximityPool[i].entity.components.set(ambient)

                    proximityPool[i].controller = proximityPool[i].entity.playAudio(resource)
                    proximityPool[i].currentResourceKey = importance
                    proximityPool[i].isActive = true

                    if frameCount < 100 {
                        audioLog.debug("Proximity voice \(i): playing importance=\(importance) at dist=\(dist, format: .fixed(precision: 1))")
                    }
                }

                // Distance-based gain: -12 dB up close fading to -34 dB at
                // the edge of audibleRange (the hard mute above catches the rest).
                let volume = max(0.0, 1.0 - dist / audibleRange)
                proximityPool[i].controller?.gain = Double(-34.0 + volume * 22.0)
            } else {
                muteVoice(&proximityPool[i])
            }
        }
    }

    // MARK: - Edge Hums

    private func updateEdgeHums(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider
    ) {
        guard let resource = edgeHumResource,
              let selectedNode = dataProvider.selectedNode else {
            muteAllEdge()
            return
        }

        let edges = dataProvider.edges
        let positions = dataProvider.positions
        let scaleFactor = scene.scaleFactor
        var activeCount = 0

        for edge in edges {
            guard activeCount < maxEdgeHumVoices else { break }
            guard edge.sourceId == selectedNode || edge.targetId == selectedNode else { continue }
            guard let srcPos = positions[edge.sourceId],
                  let tgtPos = positions[edge.targetId] else { continue }

            let midpoint = (srcPos + tgtPos) * 0.5 * scaleFactor
            edgePool[activeCount].entity.position = midpoint

            if !edgePool[activeCount].isActive {
                edgePool[activeCount].controller?.stop()
                edgePool[activeCount].controller = edgePool[activeCount].entity.playAudio(resource)
                edgePool[activeCount].isActive = true
                edgePool[activeCount].currentResourceKey = 0
            }

            edgePool[activeCount].controller?.gain = -25.0
            activeCount += 1
        }

        // Mute remaining voices
        for i in activeCount..<maxEdgeHumVoices {
            muteVoice(&edgePool[i])
        }
    }

    // MARK: - Voice Muting

    private func muteVoice(_ voice: inout Voice) {
        guard voice.isActive else { return }
        voice.controller?.stop()
        voice.controller = nil
        voice.isActive = false
        voice.currentResourceKey = -1
    }

    private func muteAllProximity() {
        for i in 0..<proximityPool.count {
            muteVoice(&proximityPool[i])
        }
    }

    private func muteAllEdge() {
        for i in 0..<edgePool.count {
            muteVoice(&edgePool[i])
        }
    }

    // MARK: - Event Sounds

    private func updateEventSounds(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider
    ) {
        // Detect new recall glows
        for (nodeId, elapsed) in dataProvider.glowingNodes {
            guard elapsed < 0.1, !pendingGlowNodes.contains(nodeId) else { continue }
            pendingGlowNodes.insert(nodeId)

            // Play recall sound at node position
            if let resource = recallGlowResource,
               let pos = dataProvider.positions[nodeId] {
                let audioEntity = Entity()
                audioEntity.position = pos * scene.scaleFactor
                var spatialAudio = SpatialAudioComponent()
                spatialAudio.gain = -10.0
                audioEntity.components.set(spatialAudio)
                scene.rootEntity.addChild(audioEntity)
                let controller = audioEntity.playAudio(resource)
                // Clean up after playback completes (resource is 0.5s, non-looping)
                let id = UUID()
                let task = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    controller.stop(); audioEntity.removeFromParent()
                    self?.eventVoices.removeValue(forKey: id)
                }
                eventVoices[id] = (audioEntity, controller, task)
            }
        }

        // Clean up expired glows from tracking set
        for nodeId in pendingGlowNodes {
            if dataProvider.glowingNodes[nodeId] == nil {
                pendingGlowNodes.remove(nodeId)
            }
        }
    }

    // MARK: - Mascot Audio

    /// Attach thruster audio to a mascot entity.
    public func attachThrusterAudio(to entity: Entity, project: String) {
        guard isEnabled, !isTornDown, let resource = thrusterResource else { return }

        var spatialAudio = SpatialAudioComponent()
        spatialAudio.gain = -20.0
        spatialAudio.distanceAttenuation = .rolloff(factor: 2.0)
        entity.components.set(spatialAudio)

        let controller = entity.playAudio(resource)
        activeMascotControllers[project] = controller
    }

    /// Update mascot thruster volume based on behavior state.
    public func updateMascotAudio(project: String, state: MascotBehavior) {
        guard let controller = activeMascotControllers[project] else { return }

        let gain: Double
        switch state {
        case .patrol: gain = -15.0  // louder when moving
        case .hover, .chatting: gain = -25.0  // quiet when hovering
        case .conjure: gain = -10.0  // louder during conjure
        case .idle(.sleeping): gain = -40.0  // nearly silent
        default: gain = -20.0
        }
        controller.gain = gain
    }

    // MARK: - Stop All

    public func stopAll() {
        for (entity, controller, task) in eventVoices.values {
            task.cancel(); controller.stop(); entity.removeFromParent()
        }
        eventVoices.removeAll()
        muteAllProximity()
        muteAllEdge()

        for (_, controller) in activeMascotControllers {
            controller.stop()
        }
        activeMascotControllers.removeAll()
    }

    /// Release only this system's generated WAVs and retained playback resources.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true; isEnabled = false; stopAll()
        for voice in proximityPool { voice.entity.removeFromParent() }
        for voice in edgePool { voice.entity.removeFromParent() }
        proximityPool.removeAll(); edgePool.removeAll(); pendingGlowNodes.removeAll()
        proximityToneResources.removeAll(); edgeHumResource = nil; recallGlowResource = nil
        nodeCreateResource = nil; nodeDeleteResource = nil; thrusterResource = nil
        for url in tempFileURLs { try? FileManager.default.removeItem(at: url) }
        tempFileURLs.removeAll()
    }

    // MARK: - Audio Resource Generation

    /// Pre-generate procedural tone audio resources.
    /// Creates short WAV buffers in memory — no file I/O needed.
    private func generateAudioResources() {
        let sampleRate: Double = 44100
        let duration: Double = 2.0  // loop length

        // Proximity tones: importance 1→5 maps to frequency 220→880 Hz
        let frequencies: [Int: Double] = [
            1: 220.0,  // A3
            2: 330.0,  // E4
            3: 440.0,  // A4
            4: 554.37, // C#5
            5: 880.0,  // A5
        ]

        for (importance, freq) in frequencies {
            if let resource = generateToneResource(frequency: freq, duration: duration, sampleRate: sampleRate, amplitude: 0.15) {
                proximityToneResources[importance] = resource
            }
        }

        // Edge hum: low drone at 110 Hz
        edgeHumResource = generateToneResource(frequency: 110.0, duration: duration, sampleRate: sampleRate, amplitude: 0.1)

        // Recall glow: rising tone sweep 440→880 Hz over 0.5s (one-shot)
        recallGlowResource = generateSweepResource(startFreq: 440, endFreq: 880, duration: 0.5, sampleRate: sampleRate, amplitude: 0.3, shouldLoop: false)

        // Thruster: low rumble at 80 Hz with harmonics
        thrusterResource = generateToneResource(frequency: 80.0, duration: duration, sampleRate: sampleRate, amplitude: 0.08, harmonics: true)
    }

    /// Generate a pure sine tone as AudioFileResource.
    private func generateToneResource(
        frequency: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float,
        harmonics: Bool = false,
        shouldLoop: Bool = true
    ) -> AudioFileResource? {
        let sampleCount = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            var sample = Float(sin(2.0 * .pi * frequency * t)) * amplitude

            if harmonics {
                // Add 2nd and 3rd harmonics for richer timbre
                sample += Float(sin(2.0 * .pi * frequency * 2.0 * t)) * amplitude * 0.3
                sample += Float(sin(2.0 * .pi * frequency * 3.0 * t)) * amplitude * 0.15
            }

            // Fade in/out to avoid clicks
            let fadeLength = min(0.05, duration / 4.0)
            let fadeSamples = Int(fadeLength * sampleRate)
            if i < fadeSamples {
                sample *= Float(i) / Float(fadeSamples)
            } else if i > sampleCount - fadeSamples {
                sample *= Float(sampleCount - i) / Float(fadeSamples)
            }

            samples[i] = sample
        }

        return audioResourceFromSamples(samples, sampleRate: sampleRate, shouldLoop: shouldLoop)
    }

    /// Generate a frequency sweep as AudioFileResource.
    private func generateSweepResource(
        startFreq: Double,
        endFreq: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float,
        shouldLoop: Bool = true
    ) -> AudioFileResource? {
        let sampleCount = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: sampleCount)
        var phase: Double = 0

        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount)
            let freq = startFreq + (endFreq - startFreq) * t
            phase += 2.0 * .pi * freq / sampleRate
            var sample = Float(sin(phase)) * amplitude

            // ADSR envelope
            let attack = 0.05, decay = 0.1, sustain: Float = 0.6, release = 0.2
            let timeS = Double(i) / sampleRate
            if timeS < attack {
                sample *= Float(timeS / attack)
            } else if timeS < attack + decay {
                sample *= 1.0 - (1.0 - sustain) * Float((timeS - attack) / decay)
            } else if timeS > duration - release {
                sample *= Float((duration - timeS) / release)
            } else {
                sample *= sustain
            }

            samples[i] = sample
        }

        return audioResourceFromSamples(samples, sampleRate: sampleRate, shouldLoop: shouldLoop)
    }

    /// Convert raw float samples to an AudioFileResource via in-memory WAV.
    ///
    /// PHASE (RealityKit's audio backend) loads audio data asynchronously — even
    /// with `loadingStrategy: .preload`, the file is re-opened by PHASE after
    /// `AudioFileResource.load` returns. The temp WAV must stay on disk.
    private func audioResourceFromSamples(_ samples: [Float], sampleRate: Double, shouldLoop: Bool) -> AudioFileResource? {
        // Build minimal WAV header + PCM data
        let bytesPerSample = 2  // 16-bit PCM
        let dataSize = samples.count * bytesPerSample
        let fileSize = 44 + dataSize  // WAV header = 44 bytes

        var wav = Data(capacity: fileSize)

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * Double(bytesPerSample)).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(bytesPerSample).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        // PCM samples (float → 16-bit int)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            wav.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        // Write to temp file — must persist for PHASE async loading
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram_tone_\(UUID().uuidString).wav")
        do {
            try wav.write(to: tempURL)
            var config = AudioFileResource.Configuration()
            config.shouldLoop = shouldLoop
            config.loadingStrategy = .preload
            let resource = try AudioFileResource.load(contentsOf: tempURL,
                                                       withName: nil,
                                                       configuration: config)
            tempFileURLs.append(tempURL)
            audioLog.debug("Loaded audio resource: \(tempURL.lastPathComponent, privacy: .public) loop=\(shouldLoop)")
            return resource
        } catch {
            audioLog.error("Failed to load audio resource: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    /// Clean up temp WAV files.
    deinit {
        for url in tempFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
