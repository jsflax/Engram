import Metal
import Foundation

/// Single source of truth for Engram's compiled Metal shaders.
/// - Xcode: compiles .metal → metallib automatically, loaded via `Bundle.module`.
/// - `swift test`: falls back to runtime compilation of compute kernels from bundled source.
public enum EngramMetalShaders {
    /// Embedded acceptance requires the actual packaged library. This never
    /// substitutes runtime source compilation for a missing build resource.
    public static func makePackagedLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            throw PackagedShaderError.libraryMissing
        }
        for name in ["compute_charge_forces", "compute_charge_forces_bh", "compute_spring_and_structural", "integrate_positions"] {
            guard library.makeFunction(name: name) != nil else { throw PackagedShaderError.functionMissing(name) }
        }
        return library
    }

    public enum PackagedShaderError: Error, LocalizedError {
        case libraryMissing, functionMissing(String)
        public var errorDescription: String? {
            switch self {
            case .libraryMissing: "The Engram compute shader library is missing."
            case .functionMissing(let name): "The Engram compute shader library is incomplete: \(name)"
            }
        }
    }

    public static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Xcode pre-compiles the metallib into the bundle
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            return lib
        }
        // swift build/test: compile compute kernels from bundled .metal source
        return try compileFromSource(device: device)
    }

    private static func compileFromSource(device: MTLDevice) throws -> MTLLibrary {
        let bundle = Bundle.module
        guard let headerURL = bundle.url(forResource: "SharedTypes", withExtension: "h") else {
            throw ShaderError.missingFile("SharedTypes.h")
        }
        let header = try String(contentsOf: headerURL)

        var source = "#include <metal_stdlib>\nusing namespace metal;\n\n\(header)\n"

        // Compile all .metal files found in the bundle
        let shaderNames = ["ForceCompute", "ForceIntegrate"]
        for name in shaderNames {
            guard let url = bundle.url(forResource: name, withExtension: "metal") else { continue }
            var text = try String(contentsOf: url)
            // Strip #include directives (header already inlined above)
            text = text.replacingOccurrences(
                of: #"#include\s+[<"].*[>"]\s*\n"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "using namespace metal;\n", with: "")
            // Strip RealityKit surface/geometry shader functions — they need framework
            // headers unavailable to makeLibrary(source:). Compute kernels compile standalone.
            // Use brace-balanced removal since these functions contain nested braces.
            text = Self.stripVisibleFunctions(text)
            source += "\n\(text)"
        }

        return try device.makeLibrary(source: source, options: nil)
    }

    /// Strip [[visible]] RealityKit functions by matching balanced braces.
    private static func stripVisibleFunctions(_ source: String) -> String {
        var result = source
        while let marker = result.range(of: "[[visible]]\n") {
            // Find the opening brace of the function body
            guard let braceStart = result[marker.upperBound...].firstIndex(of: "{") else { break }
            // Walk forward counting braces to find the matching close
            var depth = 0
            var idx = braceStart
            while idx < result.endIndex {
                let ch = result[idx]
                if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1; if depth == 0 { break } }
                idx = result.index(after: idx)
            }
            guard idx < result.endIndex else { break }
            // Remove from [[visible]] through the closing brace + trailing newline
            let end = result.index(after: idx)
            let removeEnd = end < result.endIndex && result[end] == "\n"
                ? result.index(after: end) : end
            result.removeSubrange(marker.lowerBound..<removeEnd)
        }
        return result
    }

    public enum ShaderError: Error, LocalizedError {
        case missingFile(String)
        public var errorDescription: String? {
            switch self { case .missingFile(let f): "Missing shader file: \(f)" }
        }
    }
}
