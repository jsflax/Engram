import Foundation
import Metal
import RealityKit

public struct RendererResourceDiagnostics: Sendable, Equatable {
    public let metalAvailable: Bool
    public let shaderLibraryAvailable: Bool
    public let missingShaderFunctions: [String]
    public let bundledMascotAvailable: Bool
    public let materialFallbacks: [String]
    public var shadersReady: Bool { metalAvailable && shaderLibraryAvailable && missingShaderFunctions.isEmpty && materialFallbacks.isEmpty }
}

public enum RendererResourceError: Error, LocalizedError {
    case metalUnavailable, shaderLibraryUnavailable, missingShaderFunctions([String]), mascotUnavailable, mascotDecodeFailed, materialFallback([String])
    public var errorDescription: String? {
        switch self {
        case .metalUnavailable: "Metal is unavailable for the Engram renderer."
        case .shaderLibraryUnavailable: "The Engram renderer’s compiled shader library is missing."
        case .missingShaderFunctions(let names): "The Engram shader library is incomplete: " + names.joined(separator: ", ")
        case .mascotUnavailable: "The bundled Engram mascot asset is missing."
        case .materialFallback(let names): "Engram could not create its shader materials: " + names.joined(separator: ", ")
        case .mascotDecodeFailed: "The bundled Engram mascot asset could not be decoded."
        }
    }
}

@MainActor public extension EngramRealityScene {
    var resourceDiagnostics: RendererResourceDiagnostics {
        var required = ["nodeSurface", "nodeGeometryTwoBuffer", "edgeSurface", "labelSurface"]
        if #available(macOS 26, iOS 26, *) { required += ["nodeGeometryInstanced", "edgeGeometry"] }
        let available = Set(library?.functionNames ?? [])
        return .init(metalAvailable: true, shaderLibraryAvailable: library != nil,
                     missingShaderFunctions: required.filter { !available.contains($0) }.sorted(),
                     bundledMascotAvailable: Bundle.module.url(forResource: "mascot", withExtension: "usdz") != nil,
                     materialFallbacks: materialFallbacks.sorted())
    }

    /// A visible PBR fallback is not acceptance of the full Engram renderer.
    func validateResources(requireMascot: Bool = true) throws {
        let result = resourceDiagnostics
        guard result.shaderLibraryAvailable else { throw RendererResourceError.shaderLibraryUnavailable }
        guard result.missingShaderFunctions.isEmpty else { throw RendererResourceError.missingShaderFunctions(result.missingShaderFunctions) }
        guard result.materialFallbacks.isEmpty else { throw RendererResourceError.materialFallback(result.materialFallbacks) }
        if requireMascot && !result.bundledMascotAvailable { throw RendererResourceError.mascotUnavailable }
    }

    /// Verify actual asset decoding without attaching it or starting inference.
    func validateMascotResource() async throws {
        guard let url = Bundle.module.url(forResource: "mascot", withExtension: "usdz") else { throw RendererResourceError.mascotUnavailable }
        do { _ = try await Entity(contentsOf: url); try Task.checkCancellation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw RendererResourceError.mascotDecodeFailed }
    }
}
