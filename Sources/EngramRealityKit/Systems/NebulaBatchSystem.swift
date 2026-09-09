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
/// clusters. Opacity rides OpacityComponent, written only when the factor
/// moves past a threshold (per-frame component churn stalls RealityKit).
@MainActor
public final class NebulaBatchSystem {
    private var activeNebulae: [String: Entity] = [:]
    private var nebulaRadii: [String: Float] = [:]
    private var activeGalaxyGas: [String: Entity] = [:]
    private var galaxyGasRadii: [String: Float] = [:]
    private var activeBridges: [String: Entity] = [:]
    private var colorCache: [String: (start: NSColor, end: NSColor)] = [:]
    private var lastColorMapHash: Int = 0
    /// Last applied LOD opacity per entity key — write-on-change only.
    private var lastOpacity: [String: Float] = [:]

    /// Camera distances (to a galaxy's worldCenter) over which per-project
    /// nebulae crossfade into the galaxy's single-color mass. Scaled by the
    /// galaxy's own extent so a huge personal cloud doesn't flip to a blob
    /// while you're still inside its suburbs.
    private static let fadeStart: Float = 2600
    private static let fadeEnd: Float = 5200

    public init() {}

    public func update(
        container: Entity,
        dataProvider: SceneDataProvider,
        topologyChanged: Bool,
        scaleFactor: Float,
        cameraPosition: SIMD3<Float>
    ) {
        let colorMap = dataProvider.projectColorMap
        let colorHash = colorMap.hashValue
        if colorHash != lastColorMapHash {
            colorCache.removeAll()
            lastColorMapHash = colorHash
        }

        let clusters = dataProvider.nebulaClusters.filter { $0.count >= 2 }
        let galaxies = dataProvider.galaxySnapshots

        // Per-galaxy far factor: 0 = fully resolved (project nebulae),
        // 1 = fully far (single-color galaxy mass).
        var farFactor: [String: Float] = [:]
        for galaxy in galaxies {
            let dist = simd_length(cameraPosition - galaxy.worldCenter)
            let start = max(Self.fadeStart, galaxy.radius * 1.4)
            let end = start + (Self.fadeEnd - Self.fadeStart)
            farFactor[galaxy.id] = min(1, max(0, (dist - start) / max(1, end - start)))
        }

        updateClusterNebulae(container: container, clusters: clusters,
                             colorMap: colorMap, scaleFactor: scaleFactor,
                             farFactor: farFactor)
        updateGalaxyGas(container: container, galaxies: galaxies,
                        scaleFactor: scaleFactor, farFactor: farFactor)
        updateBridges(container: container, galaxies: galaxies,
                      scaleFactor: scaleFactor)
    }

    // MARK: - Per-cluster nebulae (near LOD)

    private func updateClusterNebulae(
        container: Entity,
        clusters: [RKNebulaCluster],
        colorMap: [String: SIMD3<Float>],
        scaleFactor: Float,
        farFactor: [String: Float]
    ) {
        let activeKeys = Set(clusters.map(\.key))
        for (key, entity) in activeNebulae where !activeKeys.contains(key) {
            entity.removeFromParent()
            activeNebulae.removeValue(forKey: key)
            nebulaRadii.removeValue(forKey: key)
            lastOpacity.removeValue(forKey: key)
        }

        for cluster in clusters {
            let key = cluster.key
            let color = colorMap[cluster.project] ?? SIMD3<Float>(0.5, 0.5, 0.5)

            if let entity = activeNebulae[key] {
                let position = cluster.centroid * scaleFactor
                if entity.position != position { entity.position = position }
                // Clusters RESIZE now — the old system froze radius at
                // creation, so anything created mid-load stayed invisible
                // (radius ~40 against a spread of hundreds). Rebuild the
                // emitter only past a 25% delta; the component write is the
                // expensive part.
                let known = nebulaRadii[key] ?? cluster.radius
                if abs(cluster.radius - known) / max(known, 1) > 0.25 {
                    let colors = nebulaColors(for: cluster.project, rgb: color)
                    entity.components.set(makeNebulaEmitter(
                        radius: cluster.radius, scaleFactor: scaleFactor,
                        startColor: colors.start, endColor: colors.end))
                    nebulaRadii[key] = cluster.radius
                }
            } else {
                let entity = Entity()
                entity.name = "Nebula_\(key)"
                entity.position = cluster.centroid * scaleFactor
                let colors = nebulaColors(for: cluster.project, rgb: color)
                entity.components.set(makeNebulaEmitter(
                    radius: cluster.radius, scaleFactor: scaleFactor,
                    startColor: colors.start, endColor: colors.end))
                entity.components.set(NebulaComponent(
                    project: cluster.project,
                    color: SIMD4(color.x, color.y, color.z, 0.3),
                    radius: cluster.radius))
                container.addChild(entity)
                activeNebulae[key] = entity
                nebulaRadii[key] = cluster.radius
            }

            // Near LOD: visible when close, gone when far.
            setOpacity(key: key, entity: activeNebulae[key]!,
                       opacity: 1 - (farFactor[cluster.galaxyId] ?? 0))
        }
    }

    // MARK: - Per-galaxy single-color mass (far LOD)

    private func updateGalaxyGas(
        container: Entity,
        galaxies: [RKGalaxySnapshot],
        scaleFactor: Float,
        farFactor: [String: Float]
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
                if abs(radius - known) / max(known, 1) > 0.25 {
                    let colors = nebulaColors(for: key, rgb: galaxy.dominantColor)
                    entity.components.set(makeNebulaEmitter(
                        radius: radius, scaleFactor: scaleFactor,
                        startColor: colors.start, endColor: colors.end,
                        dense: true))
                    galaxyGasRadii[galaxy.id] = radius
                }
            } else {
                let entity = Entity()
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
            // Far LOD: the inverse of the clusters.
            setOpacity(key: key, entity: activeGalaxyGas[galaxy.id]!,
                       opacity: farFactor[galaxy.id] ?? 0)
        }
    }

    // MARK: - Bridges (personal → group, parent → child)

    private func updateBridges(
        container: Entity,
        galaxies: [RKGalaxySnapshot],
        scaleFactor: Float
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

    private func setOpacity(key: String, entity: Entity, opacity: Float) {
        let clamped = min(1, max(0, opacity))
        if let last = lastOpacity[key], abs(last - clamped) < 0.05 { return }
        entity.components.set(OpacityComponent(opacity: clamped))
        lastOpacity[key] = clamped
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
        dense: Bool = false
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
        emitter.mainEmitter.birthRate = dense
            ? max(10, min(28, radius * 0.03))
            : max(5, min(15, radius * 0.05))
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
