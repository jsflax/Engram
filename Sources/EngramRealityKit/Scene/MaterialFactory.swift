import RealityKit
import Metal

/// Creates CustomMaterial instances with surface shaders from the shader bundle.
///
/// Each material uses a `[[visible]]` surface shader for glow, fog, transparency,
/// and per-vertex color decoding. Falls back to PBR materials if shader loading fails.
@MainActor
enum MaterialFactory {

    /// Cached shader library from the module bundle.
    private static var shaderLibrary: MTLLibrary?

    /// Load the Metal shader library from the EngramRealityKit bundle.
    static func loadLibrary(device: MTLDevice) {
        if shaderLibrary == nil {
            shaderLibrary = try? device.makeDefaultLibrary(bundle: .module)
        }
    }

    // MARK: - Node Material

    /// CustomMaterial with node surface shader + geometry modifier.
    ///
    /// The geometry modifier (`nodeGeometry`) handles both code paths:
    /// - Mode 0 (< macOS 26): reads per-instance data from buffer 1 vertex attributes
    ///   (color + uv2) and transforms template geometry to world space.
    /// - Mode 1 (macOS 26+): reads visual data from custom texture using instance_id().
    ///
    /// `custom_parameter.x` selects the mode (0.0 or 1.0).
    /// `custom_parameter.y` holds the texture width for UV coordinate calculation.
    static func makeNodeMaterial(
        device: MTLDevice,
        instanceTexture: TextureResource? = nil,
        textureWidth: Float = 0,
        mode: Float = 0,
        onFallback: (() -> Void)? = nil
    ) -> any Material {
        loadLibrary(device: device)
        guard let library = shaderLibrary else { onFallback?(); return fallbackNodeMaterial() }

        do {
            let surfaceShader = CustomMaterial.SurfaceShader(named: "nodeSurface", in: library)
            // Two separate shader functions to avoid availability issues:
            // - nodeGeometryTwoBuffer: uses color()/uv2() vertex attributes (all macOS versions)
            // - nodeGeometryInstanced: uses instance_id() + custom texture (macOS 26+ only)
            let shaderName = mode > 0.5 ? "nodeGeometryInstanced" : "nodeGeometryTwoBuffer"
            let geometryModifier = CustomMaterial.GeometryModifier(named: shaderName, in: library)
            var mat = try CustomMaterial(
                surfaceShader: surfaceShader,
                geometryModifier: geometryModifier,
                lightingModel: .lit
            )
            mat.baseColor.tint = .white
            mat.custom.value = SIMD4<Float>(mode, textureWidth, 0, 0)
            if let tex = instanceTexture {
                mat.custom.texture = .init(tex)
            }
            return mat
        } catch {
            onFallback?()
            return fallbackNodeMaterial()
        }
    }

    private static func fallbackNodeMaterial() -> any Material {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .white)
        mat.metallic = .init(floatLiteral: 0.3)
        mat.roughness = .init(floatLiteral: 0.6)
        return mat
    }

    // MARK: - Edge Material

    /// CustomMaterial with edge surface shader — transparency, selection highlight, fog.
    ///
    /// On macOS 26+, adds `edgeGeometry` geometry modifier that reads per-instance visual
    /// data from a custom texture using `instance_id()`. On < macOS 26, no geometry modifier
    /// (edges use the single-buffer approach with vertex color).
    static func makeEdgeMaterial(
        device: MTLDevice,
        instanceTexture: TextureResource? = nil,
        textureWidth: Float = 0,
        useGeometryModifier: Bool = false,
        onFallback: (() -> Void)? = nil
    ) -> any Material {
        loadLibrary(device: device)
        guard let library = shaderLibrary else { onFallback?(); return fallbackEdgeMaterial() }

        do {
            let surfaceShader = CustomMaterial.SurfaceShader(named: "edgeSurface", in: library)
            var mat: CustomMaterial
            if useGeometryModifier {
                let geometryModifier = CustomMaterial.GeometryModifier(named: "edgeGeometry", in: library)
                mat = try CustomMaterial(
                    surfaceShader: surfaceShader,
                    geometryModifier: geometryModifier,
                    lightingModel: .lit
                )
                mat.custom.value = SIMD4<Float>(1.0, textureWidth, 0, 0)
                if let tex = instanceTexture {
                    mat.custom.texture = .init(tex)
                }
            } else {
                mat = try CustomMaterial(surfaceShader: surfaceShader, lightingModel: .lit)
            }
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            mat.faceCulling = .none
            return mat
        } catch {
            onFallback?()
            return fallbackEdgeMaterial()
        }
    }

    private static func fallbackEdgeMaterial() -> any Material {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .white)
        mat.metallic = .init(floatLiteral: 0.1)
        mat.roughness = .init(floatLiteral: 0.8)
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.4))
        mat.faceCulling = .none
        return mat
    }

    // MARK: - Label Material

    /// Unlit material for label batch rendering — atlas texture used for both color and opacity.
    /// The atlas has white text on transparent-black background; using the texture as the
    /// opacity source ensures background pixels are fully transparent (R=0 → opacity=0).
    static func makeLabelMaterial(device: MTLDevice, atlasTexture: TextureResource?) -> any Material {
        var mat = UnlitMaterial()
        if let texture = atlasTexture {
            mat.color = .init(tint: .white, texture: .init(texture))
            mat.blending = .transparent(opacity: .init(texture: .init(texture)))
        } else {
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        }
        return mat
    }

    // MARK: - Flow Particle Material

    static func makeFlowParticleMaterial() -> any Material {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .white)
        mat.emissiveColor = .init(color: .init(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0))
        mat.emissiveIntensity = 2.0
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.6))
        mat.faceCulling = .none
        return mat
    }
}
