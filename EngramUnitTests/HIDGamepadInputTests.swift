import Foundation
@testable import Engram
import EngramRealityKit
import XCTest

/// Exercises the descriptor/value contract without opening a device or asking
/// for permission. Physical Nano button labels still require in-app acceptance.
final class HIDGamepadInputTests: XCTestCase {
    private func descriptor(reportID: UInt32 = 1, type: UInt32 = 1,
                            page: UInt32 = 1, usage: UInt32 = 48,
                            minimum: Int = 0, maximum: Int = 65535,
                            isRelative: Bool = false,
                            hasGamepadAncestor: Bool = true,
                            hasKeyboardOrMouseAncestor: Bool = false,
                            reportSize: UInt32? = nil,
                            reportCount: UInt32 = 1) -> HIDGamepadElementDescriptor {
        let bits = reportSize ?? (page == 9 ? 1 : page == 2 ? 10 : usage == 57 ? 4 : 16)
        return HIDGamepadElementDescriptor(reportID: reportID, type: type, page: page, usage: usage,
            minimum: minimum, maximum: maximum, isRelative: isRelative,
            hasGamepadAncestor: hasGamepadAncestor,
            hasKeyboardOrMouseAncestor: hasKeyboardOrMouseAncestor,
            reportSize: bits, reportCount: reportCount)
    }

    private var descriptors: [HIDGamepadElementDescriptor] {
        [48, 49, 50, 53].map { descriptor(usage: UInt32($0)) }
            + [descriptor(usage: 57, minimum: 1, maximum: 8)]
            + [196, 197].map { descriptor(page: 2, usage: UInt32($0), maximum: 1023) }
            + (1...15).map { descriptor(type: 2, page: 9, usage: UInt32($0), maximum: 1) }
    }

    private var neutralInputs: [(HIDGamepadChannel, Int)] {
        [(.leftX, 32768), (.leftY, 32768), (.rightX, 32768), (.rightY, 32768),
         (.leftTrigger, 0), (.rightTrigger, 0), (.hat, 0)]
            + (1...15).map { (.button($0), 0) }
    }

    /// Sanitized complete report-1 input list from the 2026-11-05 element capture,
    /// preserving its order and numeric fields. This includes the Consumer Record
    /// entry omitted by the old handpicked fixture. No device IDs/cookies remain.
    /// Absolute inputs and gamepad ancestry are corroborated by the static report
    /// descriptor SHA-256 fb3633e4abcdaf3c52ea0c54388d50b252a2201214c1d0418e09ff62ce6e010f.
    private func recordedReportOneInputs() throws -> [HIDGamepadElementDescriptor] {
        struct RecordedInput: Decodable {
            let type, page, usage, reportID, size, count: UInt32
            let minimum, maximum: Int
        }
        let json = """
        [
          {"type":1,"page":1,"usage":48,"reportID":1,"size":16,"count":1,"minimum":0,"maximum":65535},
          {"type":1,"page":1,"usage":49,"reportID":1,"size":16,"count":1,"minimum":0,"maximum":65535},
          {"type":1,"page":1,"usage":50,"reportID":1,"size":16,"count":1,"minimum":0,"maximum":65535},
          {"type":1,"page":1,"usage":53,"reportID":1,"size":16,"count":1,"minimum":0,"maximum":65535},
          {"type":2,"page":9,"usage":1,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":2,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":3,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":4,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":5,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":6,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":7,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":8,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":9,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":10,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":11,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":12,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":13,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":14,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":9,"usage":15,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":2,"page":12,"usage":178,"reportID":1,"size":1,"count":1,"minimum":0,"maximum":1},
          {"type":1,"page":2,"usage":197,"reportID":1,"size":10,"count":1,"minimum":0,"maximum":1023},
          {"type":1,"page":2,"usage":196,"reportID":1,"size":10,"count":1,"minimum":0,"maximum":1023},
          {"type":1,"page":1,"usage":57,"reportID":1,"size":4,"count":1,"minimum":1,"maximum":8}
        ]
        """
        return try JSONDecoder().decode([RecordedInput].self, from: Data(json.utf8)).map {
            descriptor(reportID: $0.reportID, type: $0.type, page: $0.page, usage: $0.usage,
                       minimum: $0.minimum, maximum: $0.maximum,
                       reportSize: $0.size, reportCount: $0.count)
        }
    }

    private func readyState() -> HIDGamepadValueState {
        var state = HIDGamepadValueState()
        for (channel, value) in neutralInputs {
            XCTAssertTrue(state.update(channel: channel, rawValue: value))
        }
        return state
    }

    func testDeviceMatchRequiresEveryObservedIdentityField() {
        func matches(vendor: Int = 1118, product: Int = 2895, page: Int = 1,
                     usage: Int = 5, transport: String = "Bluetooth Low Energy") -> Bool {
            XboxWirelessBLEInputPolicy.matchesDevice(vendor: vendor, product: product,
                usagePage: page, usage: usage, transport: transport)
        }
        XCTAssertTrue(matches())
        XCTAssertFalse(matches(vendor: 1119))
        XCTAssertFalse(matches(product: 2896))
        XCTAssertFalse(matches(page: 7))
        XCTAssertFalse(matches(usage: 2), "A matching mouse collection is not a gamepad")
        XCTAssertFalse(matches(usage: 6), "A matching keyboard collection is not a gamepad")
        XCTAssertFalse(matches(transport: "USB"))
        XCTAssertFalse(matches(transport: "Bluetooth"))
        XCTAssertFalse(matches(transport: ""))
    }

    func testExactGamepadDescriptorMapsEverySupportedChannel() {
        let profile = HIDGamepadProfile.xboxWirelessBLE
        XCTAssertEqual(profile.inputReportIDs, [1], "Keyboard/mouse reports must remain outside the reader")
        let actual = descriptors.compactMap(XboxWirelessBLEInputPolicy.channel(for:))
        let expected: [HIDGamepadChannel] = [.leftX, .leftY, .rightX, .rightY, .hat,
                                          .rightTrigger, .leftTrigger]
            + (1...15).map { .button($0) }
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(XboxWirelessBLEInputPolicy.validatesSchema(descriptors))
        XCTAssertTrue(profile.validatesSchema(descriptors))
        XCTAssertEqual(descriptors.compactMap(profile.channel(for:)), expected)
    }

    func testDescriptorRejectsOtherReportsAndCollectionAncestry() {
        for report: UInt32 in [0, 5, 14, .max] {
            XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(reportID: report)))
        }
        XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(hasGamepadAncestor: false)))
        XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(hasKeyboardOrMouseAncestor: true)))
        XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(
            hasGamepadAncestor: false, hasKeyboardOrMouseAncestor: true)))
    }

    func testDescriptorRejectsRelativeAxesAndWrongElementTypes() {
        XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(isRelative: true)))
        // Input-misc axes and input-button elements have different contracts;
        // output/feature/collection elements may never become input channels.
        for type: UInt32 in [0, 2, 3, 129, 257, 513] {
            XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(type: type)))
        }
        XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: descriptor(type: 1, page: 9, usage: 1, maximum: 1)))
    }

    func testDescriptorRejectsUnknownUsagesAndUnexpectedRanges() {
        let rejected = [descriptor(usage: 51), descriptor(page: 7, usage: 4, maximum: 1),
            descriptor(page: 2, usage: 195, maximum: 1023),
            descriptor(type: 2, page: 9, usage: 0, maximum: 1),
            descriptor(type: 2, page: 9, usage: 16, maximum: 1),
            descriptor(minimum: -32768, maximum: 32767), descriptor(maximum: 255),
            descriptor(reportSize: 8), descriptor(reportCount: 2),
            descriptor(page: 2, usage: 196, maximum: 65535),
            descriptor(page: 2, usage: 196, maximum: 1023, reportSize: 16),
            descriptor(usage: 57, minimum: 0, maximum: 7),
            descriptor(type: 2, page: 9, usage: 1, maximum: 2),
            descriptor(type: 2, page: 9, usage: 1, maximum: 1, reportCount: 2)]
        for element in rejected { XCTAssertNil(XboxWirelessBLEInputPolicy.channel(for: element)) }
    }

    func testSchemaRequiresExactlyOneOfEveryControl() {
        XCTAssertFalse(XboxWirelessBLEInputPolicy.validatesSchema([]))
        for index in descriptors.indices {
            var missing = descriptors
            missing.remove(at: index)
            XCTAssertFalse(XboxWirelessBLEInputPolicy.validatesSchema(missing), "Missing channel \(index)")
        }
        var duplicate = descriptors
        duplicate[1] = duplicate[0]
        XCTAssertFalse(XboxWirelessBLEInputPolicy.validatesSchema(duplicate))
        XCTAssertFalse(XboxWirelessBLEInputPolicy.validatesSchema(descriptors + [descriptors[0]]))
        var foreignReport = descriptors
        foreignReport[0] = descriptor(reportID: 14)
        XCTAssertFalse(XboxWirelessBLEInputPolicy.validatesSchema(foreignReport))
    }

    func testRecordedReportOneSelectsMappedControlsAndIgnoresAuxiliary() throws {
        let profile = HIDGamepadProfile.xboxWirelessBLE
        let recorded = try recordedReportOneInputs()
        XCTAssertEqual(recorded.count, 23)
        XCTAssertTrue(profile.validatesSchema(recorded))
        let selected = try XCTUnwrap(profile.selectedInputs(in: recorded))
        XCTAssertEqual(selected.count, 22)
        XCTAssertEqual(Set(selected.map(\.channel)), profile.channels)
        XCTAssertEqual(selected.map(\.index), Array(0...18) + Array(20...22),
                       "The same plan used for device matching and seeding must omit the auxiliary")
        XCTAssertNil(profile.channel(for: recorded[19]))

        let neutral = Dictionary(uniqueKeysWithValues: neutralInputs)
        var state = HIDGamepadValueState(profile: profile)
        for input in selected {
            XCTAssertEqual(profile.channel(for: recorded[input.index]), input.channel)
            XCTAssertTrue(state.update(channel: input.channel, rawValue: try XCTUnwrap(neutral[input.channel])))
        }
        XCTAssertTrue(state.isComplete, "No auxiliary value is read or required to complete the state")
        XCTAssertTrue(state.isNeutral)
        XCTAssertEqual(state.output, readyState().output)
        XCTAssertTrue(state.update(channel: .leftX, rawValue: 65535))
        XCTAssertEqual(state.output?.leftX, 1)
        XCTAssertTrue(state.update(channel: .button(5), rawValue: 1))
        XCTAssertEqual(state.output?.buttons, 1 << 3)
        XCTAssertEqual(profile.selectedInputs(in: descriptors)?.count, 22,
                       "The auxiliary is permitted, not mandatory")
    }

    func testAuxiliaryDescriptorAllowlistRejectsMalformedAndUnrecognizedEntries() throws {
        let profile = HIDGamepadProfile.xboxWirelessBLE
        let invalid = [
            descriptor(reportID: 5, type: 2, page: 12, usage: 178, maximum: 1, reportSize: 1),
            descriptor(type: 1, page: 12, usage: 178, maximum: 1, reportSize: 1),
            descriptor(type: 129, page: 12, usage: 178, maximum: 1, reportSize: 1),
            descriptor(type: 2, page: 13, usage: 178, maximum: 1, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 179, maximum: 1, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, minimum: 1, maximum: 1, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, maximum: 2, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, isRelative: true, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, hasGamepadAncestor: false, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, hasKeyboardOrMouseAncestor: true, reportSize: 1),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, reportSize: 0),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, reportSize: 2),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, reportSize: 1, reportCount: 0),
            descriptor(type: 2, page: 12, usage: 178, maximum: 1, reportSize: 1, reportCount: 2),
        ]
        for auxiliary in invalid {
            var recorded = try recordedReportOneInputs()
            recorded[19] = auxiliary
            XCTAssertFalse(profile.validatesSchema(recorded), "Malformed auxiliary: \(auxiliary)")
            XCTAssertNil(profile.selectedInputs(in: recorded), "No input plan may escape validation")
        }
    }

    func testAuxiliaryDoesNotMaskDuplicateOrMissingMappedControls() throws {
        let profile = HIDGamepadProfile.xboxWirelessBLE
        let recorded = try recordedReportOneInputs()
        XCTAssertNil(profile.selectedInputs(in: recorded + [recorded[19]]), "Duplicate auxiliaries are ambiguous")
        for index in recorded.indices where index != 19 {
            var missing = recorded
            missing.remove(at: index)
            XCTAssertNil(profile.selectedInputs(in: missing), "Missing mapped control \(index)")
            var duplicate = recorded
            duplicate[index] = recorded[index == 0 ? 1 : 0]
            XCTAssertNil(profile.selectedInputs(in: duplicate), "Duplicate mapped control \(index)")
        }
    }

    func testIncompleteStateNeverProducesInput() {
        var state = HIDGamepadValueState()
        XCTAssertFalse(state.isComplete)
        XCTAssertNil(state.output)
        for (channel, value) in neutralInputs.dropLast() {
            XCTAssertTrue(state.update(channel: channel, rawValue: value))
            XCTAssertNil(state.output)
        }
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.update(channel: .button(15), rawValue: 0))
        XCTAssertTrue(state.isComplete)
        XCTAssertTrue(state.isNeutral)
        XCTAssertNotNil(state.output)
    }

    func testHeldControlsMustReturnToNeutralBeforeFirstOutput() {
        var state = HIDGamepadValueState()
        for (channel, value) in neutralInputs {
            let held = channel == .leftX ? 65535 : (channel == .button(5) ? 1 : value)
            XCTAssertTrue(state.update(channel: channel, rawValue: held))
        }
        XCTAssertTrue(state.isComplete)
        XCTAssertFalse(state.isNeutral)
        XCTAssertNil(state.output)
        XCTAssertTrue(state.update(channel: .leftX, rawValue: 32768))
        XCTAssertNil(state.output, "A held button still prevents initial arming")
        XCTAssertTrue(state.update(channel: .button(5), rawValue: 0))
        XCTAssertNotNil(state.output)
        XCTAssertTrue(state.update(channel: .button(5), rawValue: 1))
        XCTAssertEqual(state.output?.buttons, 1 << 3)
    }

    func testNormalizedAxesMatchGameControllerDirectionsAndEndpoints() throws {
        var state = readyState()
        let neutral = try XCTUnwrap(state.output)
        XCTAssertEqual(neutral.leftX, 0, accuracy: 0.0001)
        XCTAssertEqual(neutral.leftY, 0, accuracy: 0.0001)
        XCTAssertEqual(neutral.rightX, 0, accuracy: 0.0001)
        XCTAssertEqual(neutral.rightY, 0, accuracy: 0.0001)
        for (raw, x, y): (Int, Float, Float) in [(0, -1, 1), (65535, 1, -1)] {
            for channel: HIDGamepadChannel in [.leftX, .leftY, .rightX, .rightY] {
                XCTAssertTrue(state.update(channel: channel, rawValue: raw))
            }
            let value = try XCTUnwrap(state.output)
            XCTAssertEqual(value.leftX, x, accuracy: 0.0001)
            XCTAssertEqual(value.rightX, x, accuracy: 0.0001)
            XCTAssertEqual(value.leftY, y, accuracy: 0.0001)
            XCTAssertEqual(value.rightY, y, accuracy: 0.0001)
        }
    }

    func testTriggersNormalizeIndependentlyWithoutSwapping() throws {
        var state = readyState()
        XCTAssertTrue(state.update(channel: .leftTrigger, rawValue: 1023))
        var value = try XCTUnwrap(state.output)
        XCTAssertEqual(value.leftTrigger, 1, accuracy: 0.0001)
        XCTAssertEqual(value.rightTrigger, 0, accuracy: 0.0001)
        XCTAssertTrue(state.update(channel: .leftTrigger, rawValue: 0))
        XCTAssertTrue(state.update(channel: .rightTrigger, rawValue: 512))
        value = try XCTUnwrap(state.output)
        XCTAssertEqual(value.leftTrigger, 0, accuracy: 0.0001)
        XCTAssertEqual(value.rightTrigger, Float(512) / 1023, accuracy: 0.0001)
    }

    func testButtonUsageContractPreservesGapsAndSprint() throws {
        // HID usages encode the established Xbox layout. This is a mapping
        // contract test, not evidence of a particular physical button press.
        let mapped: [Int: UInt8] = [1: 1 << 0, 2: 1 << 1, 4: 1 << 2,
                                  5: 1 << 3, 7: 1 << 4, 8: 1 << 5]
        for usage in 1...15 {
            var state = readyState()
            XCTAssertTrue(state.update(channel: .button(usage), rawValue: 1))
            let value = try XCTUnwrap(state.output)
            XCTAssertEqual(value.buttons, mapped[usage] ?? 0, "Button usage \(usage)")
            XCTAssertEqual(value.sprint, usage == 14 || usage == 15)
            XCTAssertTrue(state.update(channel: .button(usage), rawValue: 0))
            XCTAssertEqual(state.output?.buttons, 0)
            XCTAssertEqual(state.output?.sprint, false)
        }
    }

    func testOutOfRangeValuesClearPreviouslyAcceptedState() {
        let invalid: [(HIDGamepadChannel, Int)] = [(.leftX, -1), (.rightY, 65536),
            (.leftX, .max), (.leftTrigger, -1), (.rightTrigger, 1024),
            (.hat, -1), (.hat, 9), (.button(1), -1), (.button(1), 2),
            (.button(0), 0), (.button(16), 0)]
        for (channel, value) in invalid {
            var state = readyState()
            XCTAssertNotNil(state.output)
            XCTAssertFalse(state.update(channel: channel, rawValue: value))
            XCTAssertNil(state.output, "Malformed samples must not leave stale movement available")
            XCTAssertFalse(state.isComplete)
        }
    }

    func testResetRequiresFreshCompleteNeutralState() throws {
        var state = readyState()
        XCTAssertTrue(state.update(channel: .rightX, rawValue: 65535))
        XCTAssertEqual(try XCTUnwrap(state.output).rightX, 1, accuracy: 0.0001)
        state.reset()
        XCTAssertFalse(state.isComplete)
        XCTAssertNil(state.output)
        for (channel, value) in neutralInputs {
            XCTAssertTrue(state.update(channel: channel, rawValue: channel == .rightX ? 65535 : value))
        }
        XCTAssertNil(state.output, "Focus return/reconnect must not replay a held stick")
        XCTAssertTrue(state.update(channel: .rightX, rawValue: 32768))
        XCTAssertNotNil(state.output)
        XCTAssertTrue(state.update(channel: .rightX, rawValue: 65535))
        XCTAssertEqual(try XCTUnwrap(state.output).rightX, 1, accuracy: 0.0001)
    }

    func testNeutralDeadzoneIncludesSmallDriftButRejectsMeaningfulMovement() {
        var smallDrift = HIDGamepadValueState()
        for (channel, value) in neutralInputs {
            XCTAssertTrue(smallDrift.update(channel: channel, rawValue: channel == .leftX ? 34000 : value))
        }
        XCTAssertTrue(smallDrift.isNeutral)
        XCTAssertNotNil(smallDrift.output)
        var heldTrigger = HIDGamepadValueState()
        for (channel, value) in neutralInputs {
            XCTAssertTrue(heldTrigger.update(channel: channel, rawValue: channel == .rightTrigger ? 100 : value))
        }
        XCTAssertFalse(heldTrigger.isNeutral)
        XCTAssertNil(heldTrigger.output)
    }

    func testNeutralHatAndUnmappedButtonsMustBeReleasedBeforeArming() {
        var state = HIDGamepadValueState()
        for (channel, value) in neutralInputs {
            let held = channel == .hat ? 1 : (channel == .button(13) ? 1 : value)
            XCTAssertTrue(state.update(channel: channel, rawValue: held))
        }
        XCTAssertNil(state.output)
        XCTAssertTrue(state.update(channel: .hat, rawValue: 0))
        XCTAssertNil(state.output)
        XCTAssertTrue(state.update(channel: .button(13), rawValue: 0))
        XCTAssertTrue(state.isNeutral)
        XCTAssertNotNil(state.output)
    }

    @MainActor
    func testNeutralGameControllerAlwaysTakesPriorityOverHID() {
        let primaryIdentity = NSObject(), hidIdentity = NSObject()
        let neutral = GamepadInputState(identity: ObjectIdentifier(primaryIdentity))
        var moving = GamepadInputState(identity: ObjectIdentifier(hidIdentity))
        moving.leftY = 1
        moving.buttons = .y
        let primary = GamepadInputReading(state: neutral, enumeration: nil)
        let fallback = HIDGamepadInputSnapshot(state: moving, status: .ready)
        let selected = InputHandler.preferredReading(primary: primary, fallback: fallback, active: true)
        XCTAssertEqual(selected.state?.identity, neutral.identity)
        XCTAssertEqual(selected.state?.leftY, 0)
        XCTAssertEqual(selected.state?.buttons, [])
        XCTAssertEqual(selected.backend, .gameController)
        XCTAssertNil(selected.hidStatus)
    }

    @MainActor
    func testInactiveSceneCannotSelectHIDSnapshot() {
        let identity = NSObject()
        var moving = GamepadInputState(identity: ObjectIdentifier(identity))
        moving.rightX = 1
        let primary = GamepadInputReading(state: nil, enumeration: nil)
        let fallback = HIDGamepadInputSnapshot(state: moving, status: .ready)
        let selected = InputHandler.preferredReading(primary: primary, fallback: fallback, active: false)
        XCTAssertNil(selected.state)
        XCTAssertEqual(selected.backend, .none)
        XCTAssertNil(selected.hidStatus)
    }

    @MainActor
    func testHIDSelectionKeepsAppleEnumerationAndReportsSeparateBackendStatus() {
        let identity = NSObject()
        let input = GamepadInputState(identity: ObjectIdentifier(identity))
        let enumeration = GamepadEnumerationDiagnostics(connectedCount: 0, supportedCount: 0,
            connected: [], current: nil, selected: nil, selection: "none",
            currentConnectedIndex: nil, selectedConnectedIndex: nil)
        let primary = GamepadInputReading(state: nil, enumeration: enumeration)
        let selected = InputHandler.preferredReading(primary: primary,
            fallback: HIDGamepadInputSnapshot(state: input, status: .ready), active: true)
        XCTAssertEqual(selected.state?.identity, input.identity)
        XCTAssertEqual(selected.backend, .hidGamepad)
        XCTAssertEqual(selected.hidStatus, HIDGamepadInputStatus.ready.rawValue)
        XCTAssertEqual(selected.enumeration?.connectedCount, 0,
                       "HID delivery must not invent an Apple GameController device")
        XCTAssertEqual(selected.enumeration?.selection, "none")
        let denied = InputHandler.preferredReading(primary: primary,
            fallback: HIDGamepadInputSnapshot(state: nil, status: .permissionRequired), active: true)
        XCTAssertNil(denied.state)
        XCTAssertEqual(denied.backend, .none)
        XCTAssertEqual(denied.hidStatus, HIDGamepadInputStatus.permissionRequired.rawValue)
    }

    @MainActor
    func testNewConnectionGenerationRequiresReleaseEvenWhenIdentityIsReused() {
        let identity = NSObject()
        let handler = InputHandler(), camera = CameraController()
        var input = GamepadInputState(identity: ObjectIdentifier(identity))
        input.connectionGeneration = 10
        XCTAssertEqual(handler.update(state: input, camera: camera, dt: 1 / 60, active: true), [])
        // A new attachment may reuse the same object/address. Generation must
        // still suppress a button already held at reconnection.
        input.connectionGeneration = 11
        input.buttons = .y
        XCTAssertEqual(handler.update(state: input, camera: camera, dt: 1 / 60, active: true), [])
        XCTAssertEqual(handler.update(state: input, camera: camera, dt: 1 / 60, active: true), [])
        input.buttons = []
        XCTAssertEqual(handler.update(state: input, camera: camera, dt: 1 / 60, active: true), [])
        input.buttons = .y
        XCTAssertEqual(handler.update(state: input, camera: camera, dt: 1 / 60, active: true), [.nextProject])
    }
}
