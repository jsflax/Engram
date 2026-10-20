import RealityKit
import Foundation
import simd
import CoreGraphics

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

    /// Load a mascot entity from the USDZ asset.
    /// Searches main bundle, module bundle, and Resources subdirectory.
    static func loadMascotEntity(tint: SIMD3<Float>) async -> Entity? {
        guard !Task.isCancelled else { return nil }
        let mascotScale: Float = 10.0  // ~node-sized in world units

        // Prefer the renderer module asset used by resource validation.
        if let url = Bundle.module.url(forResource: "mascot", withExtension: "usdz") {
            do {
                let entity = try await Entity(contentsOf: url)
                guard !Task.isCancelled else { return nil }
                entity.scale = SIMD3<Float>(repeating: mascotScale)
                tameMascotMaterials(entity)
                return entity
            } catch {}
        }

        // Legacy standalone fallback when the module asset is absent/unreadable.
        guard !Task.isCancelled else { return nil }
        if let url = Bundle.main.url(forResource: "mascot", withExtension: "usdz") {
            do {
                let entity = try await Entity(contentsOf: url)
                guard !Task.isCancelled else { return nil }
                entity.scale = SIMD3<Float>(repeating: mascotScale)
                tameMascotMaterials(entity)
                return entity
            } catch {}
        }

        // Try named asset (Xcode asset catalog)
        guard !Task.isCancelled else { return nil }
        do {
            let entity = try await Entity(named: "mascot", in: .main)
            guard !Task.isCancelled else { return nil }
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
        guard !Task.isCancelled else { return group }

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
        let s: Float = 15.0
        let mesh = MeshResource.generatePlane(width: s, depth: s, cornerRadius: s * 0.5)
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
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.position.y = -5.0
        return entity
    }

    private static func createConjureOrb(tint: SIMD3<Float>) -> Entity {
        let mesh = MeshResource.generateSphere(radius: 3.0)
        var mat = PhysicallyBasedMaterial()
        mat.emissiveColor = .init(color: .init(
            red: CGFloat(tint.x),
            green: CGFloat(tint.y),
            blue: CGFloat(tint.z),
            alpha: 1
        ))
        mat.emissiveIntensity = 8.0
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.8))
        return ModelEntity(mesh: mesh, materials: [mat])
    }

    private static func createHoloScreen(tint: SIMD3<Float>) -> Entity {
        let mesh = MeshResource.generatePlane(width: 20.0, height: 15.0)
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
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.position = SIMD3(0, 8.0, 18.0)
        return entity
    }
}
