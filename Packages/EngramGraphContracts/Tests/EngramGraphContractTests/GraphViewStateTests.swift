import Foundation
import Testing
import EngramGraphContract

struct GraphViewStateTests {
    @Test func cameraRoundTripsWithoutRendererDependencies() throws {
        let value = try EngramGraphViewState(selectedNode: UUID(), azimuth: 0.25, elevation: 0.125,
            target: .init(x: 1, y: 2, z: 3), orbitRadius: 100)
        #expect(try EngramGraphViewState.decode(value.encoded()) == value)
        let raw = try #require(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        #expect(raw["version"] as? Int == 1 && raw["selectedNode"] as? String == value.selectedNode?.uuidString)
    }

    @Test func cameraRejectsMissingRequiredFieldsInvalidGeometryAndOversize() throws {
        let value = try EngramGraphViewState(selectedNode: nil, azimuth: 0, elevation: 0,
            target: .init(x: 0, y: 0, z: 0), orbitRadius: 100)
        let raw = try #require(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        for field in ["elevation", "orbitRadius", "target"] {
            var incomplete = raw; incomplete.removeValue(forKey: field)
            #expect(throws: (any Error).self) {
                try EngramGraphViewState.decode(JSONSerialization.data(withJSONObject: incomplete))
            }
        }
        for (field, invalid) in [("azimuth", 1_000_001.0), ("elevation", 2.0), ("orbitRadius", -1.0)] {
            var malformed = raw; malformed[field] = invalid
            #expect(throws: EngramGraphSurfaceError.invalidState) {
                try EngramGraphViewState.decode(JSONSerialization.data(withJSONObject: malformed))
            }
        }
        #expect(throws: EngramGraphSurfaceError.invalidState) {
            try EngramGraphViewState(selectedNode: nil, azimuth: .infinity, elevation: 0,
                target: .init(x: 0, y: 0, z: 0), orbitRadius: 100)
        }
        #expect(throws: EngramGraphSurfaceError.invalidState) {
            try EngramGraphViewState.decode(Data(repeating: 32, count: 2_049))
        }
    }
}
