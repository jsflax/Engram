import RealityKit
import Foundation
import simd
import CoreGraphics

/// Keeps the prepared asset out of the scene. Each caller receives its own
/// hierarchy; RealityKit clones share the underlying mesh/texture resources.
@MainActor
final class MascotModelPrototypeCache {
    private let load: @MainActor () async -> Entity?
    private var prototype: Entity?
    private var pending: (generation: UInt64, task: Task<Entity?, Never>)?
    private var generation: UInt64 = 0

    init(load: @escaping @MainActor () async -> Entity?) { self.load = load }

    func clone() async -> Entity? {
        if let prototype { return prototype.clone(recursive: true) }
        let task: Task<Entity?, Never>
        if let pending {
            task = pending.task
        } else {
            generation &+= 1
            let attempt = generation
            task = Task { @MainActor in
                let loaded = await self.load()
                // Publish before resuming waiters. Failed loads are not cached,
                // and an older completion cannot clear a newer pending attempt.
                if self.pending?.generation == attempt {
                    self.prototype = loaded
                    self.pending = nil
                }
                return loaded
            }
            pending = (attempt, task)
        }
        return await task.value?.clone(recursive: true)
    }
}

/// Loads mascot USDZ and manages joint mapping for skeleton animation.
///
/// The mascot has a 5-joint UsdSkel skeleton:
/// - root (body bob + yaw)
/// - root/left_arm (arm swing/raise)
/// - root/right_arm (arm swing/raise)
/// - root/eye (eye pulse)
/// - root/bottom (thruster)
@MainActor
enum MascotEntityFactory {

    /// Joint names in the UsdSkel skeleton.
    static let jointRoot = "root"
    static let jointLeftArm = "root/left_arm"
    static let jointRightArm = "root/right_arm"
    static let jointEye = "root/eye"
    static let jointBottom = "root/bottom"

    /// All joint paths for skeleton queries.
    static let allJointPaths = [jointRoot, jointLeftArm, jointRightArm, jointEye, jointBottom]

    private static let modelCache = MascotModelPrototypeCache(load: loadPreparedModel)

    // Only geometry is shared. Each project still gets fresh effect entities
    // and material values, including independently replaceable holo textures.
    private static let arcaneCircleMesh = MeshResource.generatePlane(width: 15, depth: 15, cornerRadius: 7.5)
    private static let conjureOrbMesh = MeshResource.generateSphere(radius: 3)
    private static let holoScreenMesh = MeshResource.generatePlane(width: 20, height: 15)

    /// Clone the prepared USDZ hierarchy. The authored model color is preserved;
    /// the project tint is applied to the separately created effect materials.
    static func loadMascotEntity(tint: SIMD3<Float>) async -> Entity? {
        await modelCache.clone()
    }

    /// Preserve main-bundle, module-bundle, then named-asset fallback order.
    /// A total failure remains retryable by a later factory call.
    private static func loadPreparedModel() async -> Entity? {
        let mascotScale: Float = 10.0  // ~node-sized in world units

        // Try main bundle first (EngramVisualizer app)
        if let url = Bundle.main.url(forResource: "mascot", withExtension: "usdz") {
            do {
                let entity = try await Entity(contentsOf: url)
                entity.scale = SIMD3<Float>(repeating: mascotScale)
                tameMascotMaterials(entity)
                return entity
            } catch {}
        }

        // Try module bundle (EngramRealityKit copies it via .copy("Resources/mascot.usdz"))
        if let url = Bundle.module.url(forResource: "mascot", withExtension: "usdz") {
            do {
                let entity = try await Entity(contentsOf: url)
                entity.scale = SIMD3<Float>(repeating: mascotScale)
                tameMascotMaterials(entity)
                return entity
            } catch {}
        }

        // Try named asset (Xcode asset catalog)
        do {
            let entity = try await Entity(named: "mascot", in: .main)
            entity.scale = SIMD3<Float>(repeating: mascotScale)
            tameMascotMaterials(entity)
            return entity
        } catch {}

        return nil
    }

    /// Damp the mascot's environment-reflection response. The scene sets no
    /// ImageBasedLight, so RealityKit's default studio environment mirrors in
    /// the asset's glossy (low-roughness) regions as harsh white/blue patches
    /// — the "broken camo texture" look. (Preview.app renders the same USDZ
    /// cleanly under its own gentler IBL; the asset itself is fine.) Raising
    /// the roughness floor and cutting specular keeps the authored basecolor
    /// while killing the mirror shards.
    private static func tameMascotMaterials(_ root: Entity) {
        func visit(_ e: Entity) {
            if var model = e.components[ModelComponent.self] {
                model.materials = model.materials.map { mat in
                    guard var pbr = mat as? PhysicallyBasedMaterial else { return mat }
                    pbr.roughness.scale = max(pbr.roughness.scale, 1.0) * 2.0
                    pbr.specular.scale = 0.2
                    pbr.clearcoat.scale = 0.0
                    return pbr
                }
                e.components.set(model)
            }
            for child in e.children { visit(child) }
        }
        visit(root)
    }

    /// Create a full mascot entity group with child effect entities.
    /// Returns the root entity with arcane circle, conjure orb, and holo screen children.
    static func createMascotGroup(
        project: String,
        tint: SIMD3<Float>
    ) async -> Entity {
        let group = Entity()
        group.name = "Mascot_\(project)"

        // Load USDZ model
        if let model = await loadMascotEntity(tint: tint) {
            model.name = "MascotModel"
            group.addChild(model)
        }

        // Arcane circle — flat disk child entity
        let arcaneCircle = createArcaneCircle(tint: tint)
        arcaneCircle.name = "ArcaneCircle"
        arcaneCircle.isEnabled = false
        group.addChild(arcaneCircle)

        // Conjure orb — small emissive sphere
        let conjureOrb = createConjureOrb(tint: tint)
        conjureOrb.name = "ConjureOrb"
        conjureOrb.isEnabled = false
        group.addChild(conjureOrb)

        // Holo screen — billboard quad
        let holoScreen = createHoloScreen(tint: tint)
        holoScreen.name = "HoloScreen"
        holoScreen.isEnabled = false
        group.addChild(holoScreen)

        // Attach component
        group.components.set(MascotComponent(project: project, tint: tint))

        return group
    }

    // MARK: - Effect Entities

    private static func createArcaneCircle(tint: SIMD3<Float>) -> Entity {
        var mat = PhysicallyBasedMaterial()
        mat.emissiveColor = .init(color: .init(
            red: CGFloat(tint.x * 0.5 + 0.5),
            green: CGFloat(tint.y * 0.5 + 0.5),
            blue: CGFloat(tint.z * 0.5 + 0.5),
            alpha: 1
        ))
        mat.emissiveIntensity = 3.0
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.4))
        mat.faceCulling = .none
        let entity = ModelEntity(mesh: arcaneCircleMesh, materials: [mat])
        entity.position.y = -5.0
        return entity
    }

    private static func createConjureOrb(tint: SIMD3<Float>) -> Entity {
        var mat = PhysicallyBasedMaterial()
        mat.emissiveColor = .init(color: .init(
            red: CGFloat(tint.x),
            green: CGFloat(tint.y),
            blue: CGFloat(tint.z),
            alpha: 1
        ))
        mat.emissiveIntensity = 8.0
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.8))
        return ModelEntity(mesh: conjureOrbMesh, materials: [mat])
    }

    private static func createHoloScreen(tint: SIMD3<Float>) -> Entity {
        // Start with a blank unlit material — texture is applied dynamically
        // when the mascot hovers over a node.
        var mat = UnlitMaterial()
        mat.color = .init(
            tint: .init(
                red: CGFloat(tint.x * 0.3 + 0.2),
                green: CGFloat(tint.y * 0.3 + 0.4),
                blue: CGFloat(tint.z * 0.3 + 0.6),
                alpha: 0.3
            )
        )
        mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        mat.faceCulling = .none
        let entity = ModelEntity(mesh: holoScreenMesh, materials: [mat])
        entity.position = SIMD3(0, 8.0, 18.0)
        return entity
    }
}
