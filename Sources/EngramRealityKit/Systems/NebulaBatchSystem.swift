import RealityKit
import AppKit
import simd

/// Nebula gas: per-(galaxy, project) cluster emitters, a single-color
/// far-LOD gas mass per galaxy, and gas bridges connecting group galaxies
/// to the personal one.
///
/// Uses RealityKit ParticleEmitterComponent for the gaseous fog effect.
///
/// LOD: when the camera is far from a galaxy, its per-project nebulae fade
/// out and one galaxy-sized single-color mass fades in — so a distant team
/// reads as a colored body, and flying closer resolves it into its project
/// clusters. Fully transparent LOD entities are disabled so their particle
/// simulation stops. Visible opacity changes are throttled between exact
/// endpoints (per-frame component churn stalls RealityKit). Project detail
/// also shares a scene-wide emitter/rate budget; galaxy gas covers withheld
/// detail instead of activating every project when its galaxy is nearby.
@MainActor
public final class NebulaBatchSystem {
    private var activeNebulae: [String: Entity] = [:]
    private var nebulaRadii: [String: Float] = [:]
    private var nebulaBirthRates: [String: Float] = [:]
    private var activeGalaxyGas: [String: Entity] = [:]
    private var galaxyGasRadii: [String: Float] = [:]
    private var activeBridges: [String: Entity] = [:]
    private var colorCache: [String: (start: NSColor, end: NSColor)] = [:]
    private var lastColorMapHash: Int = 0
    /// Last applied LOD opacity per entity key — write-on-change only.
    private var lastOpacity: [String: Float] = [:]
    private var detailPlanner = NebulaDetailPlanner()
    private var lastScaleFactor: Float?

    /// Retained emitter entities, not particle counts; read only by diagnostics.
    var diagnosticTrackedCounts: (clusters: Int, galaxies: Int, bridges: Int) {
        (activeNebulae.count, activeGalaxyGas.count, activeBridges.count)
    }

    /// Camera distances (to a galaxy's worldCenter) over which per-project
    /// nebulae crossfade into the galaxy's single-color mass. Scaled by the
    /// galaxy's own extent so a huge personal cloud doesn't flip to a blob
    /// while you're still inside its suburbs.
    private static let fadeStart: Float = 2600
    private static let fadeEnd: Float = 5200

    public init() {}

    init(detailBudget: NebulaDetailPlanner.Budget) {
        detailPlanner = NebulaDetailPlanner(budget: detailBudget)
    }

    public func update(
        container: Entity,
        dataProvider: SceneDataProvider,
        topologyChanged: Bool,
        scaleFactor: Float,
        cameraPosition: SIMD3<Float>,
        deltaTime: Float = 1.0 / 60.0
    ) {
        let colorMap = dataProvider.projectColorMap
        let colorHash = colorMap.hashValue
        if colorHash != lastColorMapHash {
            colorCache.removeAll()
            lastColorMapHash = colorHash
        }

        let clusters = dataProvider.nebulaClusters.filter {
            $0.count >= 2 && $0.radius.isFinite && $0.radius >= 0
                && $0.centroid.x.isFinite && $0.centroid.y.isFinite && $0.centroid.z.isFinite
        }
        let originalGalaxies = dataProvider.galaxySnapshots
        let galaxies = completeGalaxies(originalGalaxies, clusters: clusters, colorMap: colorMap)
        let scaleChanged = lastScaleFactor != scaleFactor
        lastScaleFactor = scaleFactor

        // Per-galaxy far factor: 0 = fully resolved (project nebulae),
        // 1 = fully far (single-color galaxy mass).
        var farFactor: [String: Float] = [:]
        for galaxy in galaxies {
            farFactor[galaxy.id] = farOpacity(camera: cameraPosition, center: galaxy.worldCenter,
                                             radius: galaxy.radius)
        }

        let candidates = clusters.map { cluster in
            let localNear = 1 - farOpacity(camera: cameraPosition, center: cluster.centroid,
                                           radius: cluster.radius)
            let knownRadius = nebulaRadii[cluster.key] ?? cluster.radius
            let resized = scaleChanged || abs(cluster.radius - knownRadius) / max(knownRadius, 1) > 0.25
            let emitterRadius = resized ? cluster.radius : knownRadius
            return NebulaDetailPlanner.Candidate(key: cluster.key, galaxyId: cluster.galaxyId,
                desiredOpacity: min(localNear, 1 - (farFactor[cluster.galaxyId] ?? 0)),
                priority: simd_length(cameraPosition - cluster.centroid) / max(cluster.radius, 40),
                birthRate: Self.detailBirthRate(radius: emitterRadius))
        }
        let allocations = detailPlanner.update(candidates: candidates, deltaTime: deltaTime)

        // Include the current membership fade, not just its eventual target.
        // If all detail is admitted and local fading adds no restriction,
        // this is the original far factor. Otherwise it covers withheld fog.
        var coverage: [String: (weight: Double, visible: Double)] = [:]
        for cluster in clusters {
            let weight = Double(cluster.count)
            let opacity = Double(allocations[cluster.key]?.opacity ?? 0)
            var aggregate = coverage[cluster.galaxyId] ?? (0, 0)
            aggregate.weight += weight
            aggregate.visible += weight * opacity
            coverage[cluster.galaxyId] = aggregate
        }
        var gasOpacity = farFactor
        for (id, aggregate) in coverage where aggregate.weight > 0 {
            gasOpacity[id] = Float(1 - aggregate.visible / aggregate.weight)
        }

        updateClusterNebulae(container: container, clusters: clusters,
                             colorMap: colorMap, scaleFactor: scaleFactor,
                             scaleChanged: scaleChanged, allocations: allocations)
        updateGalaxyGas(container: container, galaxies: galaxies,
                        scaleFactor: scaleFactor, scaleChanged: scaleChanged, opacity: gasOpacity)
        // Synthetic fallback masses do not invent hierarchy relationships.
        updateBridges(container: container, galaxies: originalGalaxies,
                      scaleFactor: scaleFactor, scaleChanged: scaleChanged)
    }

    // MARK: - Per-cluster nebulae (near LOD)

    private func updateClusterNebulae(
        container: Entity,
        clusters: [RKNebulaCluster],
        colorMap: [String: SIMD3<Float>],
        scaleFactor: Float,
        scaleChanged: Bool,
        allocations: [String: NebulaDetailPlanner.Allocation]
    ) {
        let activeKeys = Set(clusters.map(\.key))
        for (key, entity) in activeNebulae where !activeKeys.contains(key) {
            entity.removeFromParent()
            activeNebulae.removeValue(forKey: key)
            nebulaRadii.removeValue(forKey: key)
            nebulaBirthRates.removeValue(forKey: key)
            lastOpacity.removeValue(forKey: key)
        }

        // Release all disabled slots and rate reductions before any increase
        // or activation, so iteration order cannot transiently exceed budget.
        for (key, entity) in activeNebulae {
            guard let allocation = allocations[key] else {
                setOpacity(key: key, entity: entity, opacity: 0); continue
            }
            if allocation.opacity <= 0 { setOpacity(key: key, entity: entity, opacity: 0) }
            if allocation.birthRate < (nebulaBirthRates[key] ?? 0),
               var emitter = entity.components[ParticleEmitterComponent.self] {
                emitter.mainEmitter.birthRate = allocation.birthRate
                entity.components.set(emitter)
                nebulaBirthRates[key] = allocation.birthRate
            }
        }

        for cluster in clusters {
            let key = cluster.key
            let color = colorMap[cluster.project] ?? SIMD3<Float>(0.5, 0.5, 0.5)
            let rate = allocations[key]?.birthRate ?? Self.detailBirthRate(radius: cluster.radius)

            if let entity = activeNebulae[key] {
                let position = cluster.centroid * scaleFactor
                if entity.position != position { entity.position = position }
                // Clusters RESIZE now — the old system froze radius at
                // creation, so anything created mid-load stayed invisible
                // (radius ~40 against a spread of hundreds). Rebuild the
                // emitter only past a 25% delta; the component write is the
                // expensive part.
                let known = nebulaRadii[key] ?? cluster.radius
                let resized = scaleChanged || abs(cluster.radius - known) / max(known, 1) > 0.25
                if resized || nebulaBirthRates[key] != rate {
                    // A deferred rate upgrade must not reset the radius
                    // deadband and turn small simulation changes into writes.
                    let emitterRadius = resized ? cluster.radius : known
                    let colors = nebulaColors(for: cluster.project, rgb: color)
                    entity.components.set(makeNebulaEmitter(
                        radius: emitterRadius, scaleFactor: scaleFactor,
                        startColor: colors.start, endColor: colors.end, birthRate: rate))
                    nebulaRadii[key] = emitterRadius
                    nebulaBirthRates[key] = rate
                }
            } else {
                let entity = Entity()
                entity.isEnabled = false
                entity.name = "Nebula_\(key)"
                entity.position = cluster.centroid * scaleFactor
                let colors = nebulaColors(for: cluster.project, rgb: color)
                entity.components.set(makeNebulaEmitter(
                    radius: cluster.radius, scaleFactor: scaleFactor,
                    startColor: colors.start, endColor: colors.end, birthRate: rate))
                entity.components.set(NebulaComponent(
                    project: cluster.project,
                    color: SIMD4(color.x, color.y, color.z, 0.3),
                    radius: cluster.radius))
                container.addChild(entity)
                activeNebulae[key] = entity
                nebulaRadii[key] = cluster.radius
                nebulaBirthRates[key] = rate
            }
        }
        // Only now can newly admitted entities begin simulation.
        for cluster in clusters {
            let key = cluster.key
            setOpacity(key: key, entity: activeNebulae[key]!,
                       opacity: allocations[key]?.opacity ?? 0)
        }
    }

    // MARK: - Per-galaxy single-color mass (far LOD)

    private func updateGalaxyGas(
        container: Entity,
        galaxies: [RKGalaxySnapshot],
        scaleFactor: Float,
        scaleChanged: Bool,
        opacity: [String: Float]
    ) {
        let activeIds = Set(galaxies.filter { $0.nodeCount >= 2 }.map(\.id))
        for (id, entity) in activeGalaxyGas where !activeIds.contains(id) {
            entity.removeFromParent()
            activeGalaxyGas.removeValue(forKey: id)
            galaxyGasRadii.removeValue(forKey: id)
            lastOpacity.removeValue(forKey: "gas|\(id)")
        }

        for galaxy in galaxies where galaxy.nodeCount >= 2 {
            let key = "gas|\(galaxy.id)"
            let radius = max(galaxy.radius * 0.9, 200)
            if let entity = activeGalaxyGas[galaxy.id] {
                let position = galaxy.worldCenter * scaleFactor
                if entity.position != position { entity.position = position }
                let known = galaxyGasRadii[galaxy.id] ?? radius
                if scaleChanged || abs(radius - known) / max(known, 1) > 0.25 {
                    let colors = nebulaColors(for: key, rgb: galaxy.dominantColor)
                    entity.components.set(makeNebulaEmitter(
                        radius: radius, scaleFactor: scaleFactor,
                        startColor: colors.start, endColor: colors.end,
                        dense: true))
                    galaxyGasRadii[galaxy.id] = radius
                }
            } else {
                let entity = Entity()
                entity.isEnabled = false
                entity.name = "GalaxyGas_\(galaxy.id)"
                entity.position = galaxy.worldCenter * scaleFactor
                let colors = nebulaColors(for: key, rgb: galaxy.dominantColor)
                entity.components.set(makeNebulaEmitter(
                    radius: radius, scaleFactor: scaleFactor,
                    startColor: colors.start, endColor: colors.end,
                    dense: true))
                container.addChild(entity)
                activeGalaxyGas[galaxy.id] = entity
                galaxyGasRadii[galaxy.id] = radius
            }
            // Far or budget-withheld detail is represented by this gas mass.
            setOpacity(key: key, entity: activeGalaxyGas[galaxy.id]!,
                       opacity: opacity[galaxy.id] ?? 0)
        }
    }

    // MARK: - Bridges (personal → group, parent → child)

    private func updateBridges(
        container: Entity,
        galaxies: [RKGalaxySnapshot],
        scaleFactor: Float,
        scaleChanged: Bool
    ) {
        let byId = Dictionary(uniqueKeysWithValues: galaxies.map { ($0.id, $0) })
        // Each group galaxy bridges FROM its attached parent group when one
        // exists, else from the personal galaxy — mirroring the hierarchy.
        var wanted: [(key: String, from: SIMD3<Float>, to: SIMD3<Float>, color: SIMD3<Float>)] = []
        for galaxy in galaxies where galaxy.isGroup {
            let source = galaxy.parentGalaxyId.flatMap { byId[$0] } ?? byId["personal"]
            guard let source else { continue }
            let steps = 4
            for step in 1...steps {
                let t = Float(step) / Float(steps + 1)
                let center = source.worldCenter + (galaxy.worldCenter - source.worldCenter) * t
                wanted.append((key: "bridge|\(galaxy.id)|\(step)",
                               from: source.worldCenter, to: galaxy.worldCenter,
                               color: galaxy.dominantColor))
                _ = center
            }
        }

        let wantedKeys = Set(wanted.map(\.key))
        for (key, entity) in activeBridges where !wantedKeys.contains(key) {
            entity.removeFromParent()
            activeBridges.removeValue(forKey: key)
        }

        for item in wanted {
            let step = Int(item.key.split(separator: "|").last.map(String.init) ?? "1") ?? 1
            let t = Float(step) / 5.0
            let center = item.from + (item.to - item.from) * t
            // Thin at the middle, flaring toward both ends — a stream
            // pouring out of the team into the personal sky.
            let pinch = 1 - abs(t - 0.5) * 1.2
            let radius = max(60, 140 * (1 - pinch * 0.45))

            if let entity = activeBridges[item.key] {
                let position = center * scaleFactor
                if entity.position != position { entity.position = position }
                if scaleChanged {
                    let colors = nebulaColors(for: item.key, rgb: item.color)
                    entity.components.set(makeNebulaEmitter(
                        radius: radius, scaleFactor: scaleFactor,
                        startColor: colors.start, endColor: colors.end))
                }
            } else {
                let entity = Entity()
                entity.name = "Bridge_\(item.key)"
                entity.position = center * scaleFactor
                let colors = nebulaColors(for: item.key, rgb: item.color)
                entity.components.set(makeNebulaEmitter(
                    radius: radius, scaleFactor: scaleFactor,
                    startColor: colors.start, endColor: colors.end))
                container.addChild(entity)
                activeBridges[item.key] = entity
            }
        }
    }

    // MARK: - Helpers

    private func farOpacity(camera: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> Float {
        let distance = simd_length(camera - center)
        guard distance.isFinite, radius.isFinite else { return 1 }
        let start = max(Self.fadeStart, radius * 1.4)
        return min(1, max(0, (distance - start) / (Self.fadeEnd - Self.fadeStart)))
    }

    /// Default single-galaxy providers may supply clusters without snapshots.
    /// Give any withheld detail a coarse representation instead of losing fog.
    private func completeGalaxies(_ galaxies: [RKGalaxySnapshot], clusters: [RKNebulaCluster],
                                  colorMap: [String: SIMD3<Float>]) -> [RKGalaxySnapshot] {
        let known = Set(galaxies.map(\.id))
        let missing = Dictionary(grouping: clusters.filter { !known.contains($0.galaxyId) }, by: \.galaxyId)
        var result = galaxies
        for id in missing.keys.sorted() {
            let members = missing[id]!
            let count = members.reduce(0) { $0 + $1.count }
            let center = members.reduce(SIMD3<Float>.zero) { $0 + $1.centroid * (Float($1.count) / Float(count)) }
            let radius = members.reduce(Float(0)) { max($0, simd_length($1.centroid - center) + $1.radius) }
            let largest = members.sorted { $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count }[0]
            result.append(RKGalaxySnapshot(id: id, displayName: id, worldCenter: center,
                dominantColor: colorMap[largest.project] ?? SIMD3<Float>(0.5, 0.5, 0.5),
                nodeCount: count, radius: radius, parentGalaxyId: nil))
        }
        return result
    }

    private static func detailBirthRate(radius: Float) -> Float { max(5, min(15, radius * 0.05)) }

    private func setOpacity(key: String, entity: Entity, opacity: Float) {
        let clamped = min(1, max(0, opacity))
        let visible = clamped > 0
        let last = lastOpacity[key]
        let endpointChanged = (clamped == 0 || clamped == 1) && last != clamped
        let becomingVisible = visible && (!entity.isEnabled || last == 0)
        if last == nil || abs((last ?? clamped) - clamped) >= 0.05
            || endpointChanged || becomingVisible {
            // Apply even a tiny positive opacity before re-enabling. The
            // ordinary deadband must not leave a returning emitter at zero.
            entity.components.set(OpacityComponent(opacity: clamped))
            lastOpacity[key] = clamped
        }
        if entity.isEnabled != visible { entity.isEnabled = visible }
    }

    private func nebulaColors(for key: String, rgb: SIMD3<Float>) -> (start: NSColor, end: NSColor) {
        if let cached = colorCache[key] { return cached }

        let start = NSColor(
            red: CGFloat(min(1.0, rgb.x * 1.3 + 0.1)),
            green: CGFloat(min(1.0, rgb.y * 1.3 + 0.1)),
            blue: CGFloat(min(1.0, rgb.z * 1.3 + 0.1)),
            alpha: 0.035
        )
        let end = NSColor(
            red: CGFloat(min(1.0, rgb.x * 0.7 + 0.05)),
            green: CGFloat(min(1.0, rgb.y * 0.7 + 0.05)),
            blue: CGFloat(min(1.0, rgb.z * 0.7 + 0.05)),
            alpha: 0.005
        )
        let result = (start: start, end: end)
        colorCache[key] = result
        return result
    }

    private func makeNebulaEmitter(
        radius: Float,
        scaleFactor: Float,
        startColor: NSColor,
        endColor: NSColor,
        dense: Bool = false,
        birthRate: Float? = nil
    ) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        let scaledR = radius * scaleFactor

        emitter.emitterShape = .sphere
        emitter.birthLocation = .volume
        emitter.emitterShapeSize = SIMD3<Float>(repeating: scaledR * 2.4)

        emitter.speed = 0.0001
        emitter.speedVariation = 0.00005

        emitter.timing = .repeating(
            warmUp: 15.0,
            emit: .init(duration: .infinity),
            idle: nil
        )

        // The far-LOD galaxy mass is DENSER: it stands in for many cluster
        // nebulae at once, so its particle budget is higher and its puffs
        // larger relative to radius.
        emitter.mainEmitter.birthRate = birthRate ?? (dense
            ? max(10, min(28, radius * 0.03))
            : Self.detailBirthRate(radius: radius))
        emitter.mainEmitter.lifeSpan = 15.0
        emitter.mainEmitter.lifeSpanVariation = 5.0
        emitter.mainEmitter.size = max(0.03, scaledR * (dense ? 0.7 : 0.55))
        emitter.mainEmitter.sizeVariation = emitter.mainEmitter.size * 0.4
        emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 1.2

        emitter.mainEmitter.color = .evolving(
            start: .single(startColor),
            end: .single(endColor)
        )

        emitter.mainEmitter.blendMode = .alpha
        emitter.mainEmitter.billboardMode = .billboard
        emitter.mainEmitter.opacityCurve = .quickFadeInOut

        emitter.mainEmitter.noiseStrength = 0.0003
        emitter.mainEmitter.noiseScale = 6.0
        emitter.mainEmitter.noiseAnimationSpeed = 0.03
        emitter.mainEmitter.dampingFactor = 0.98

        return emitter
    }
}
