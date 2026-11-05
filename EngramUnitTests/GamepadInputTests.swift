import Foundation
@testable import Engram
import EngramRealityKit
import GameController
import XCTest
import simd

@MainActor
final class GamepadInputTests: XCTestCase {
    private let controller = NSObject()

    private func state(buttons: GamepadInputState.Buttons = []) -> GamepadInputState {
        var state = GamepadInputState(identity: ObjectIdentifier(controller))
        state.buttons = buttons
        return state
    }

    func testRealSceneFrameCallbackConsumesControllerExactlyOnce() throws {
        let registry = GalaxyRegistry()
        var input = state()
        input.leftY = 1
        var reads = 0
        let manager = try XCTUnwrap(RKSceneManager(registry: registry,
            readGamepad: { reads += 1; return input }, acceptsGamepadInput: { true }))
        manager.isGraphInputActive = true
        var connected: [Bool] = []
        manager.controllerConnectionCallback = { connected.append($0) }
        let callback = try XCTUnwrap(manager.rkScene.onFrameCallback)
        let before = manager.camera.targetCameraPos
        callback(1 / 60)
        XCTAssertEqual(reads, 1)
        XCTAssertGreaterThan(simd_length(manager.camera.targetCameraPos - before), 1)
        XCTAssertEqual(connected, [true])
        callback(1 / 60)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(connected, [true], "Connection state only invalidates SwiftUI when it changes")
    }

    func testSceneStopsInputWhenGraphOrForegroundIsInactiveAndReportsDisconnect() throws {
        let registry = GalaxyRegistry()
        var input: GamepadInputState? = state()
        input?.leftY = 1
        var foreground = true
        let manager = try XCTUnwrap(RKSceneManager(registry: registry,
            readGamepad: { input }, acceptsGamepadInput: { foreground }))
        let callback = try XCTUnwrap(manager.rkScene.onFrameCallback)
        let before = manager.camera.targetCameraPos
        callback(1 / 60)
        XCTAssertEqual(manager.camera.targetCameraPos, before, "Graph is inactive until its host appears")
        manager.isGraphInputActive = true
        foreground = false
        callback(1 / 60)
        XCTAssertEqual(manager.camera.targetCameraPos, before)
        foreground = true
        callback(1 / 60)
        XCTAssertNotEqual(manager.camera.targetCameraPos, before)
        manager.updateGraphInputFocus(appearsActive: true, mascotChatVisible: false,
                                      controllerSetupVisible: true)
        XCTAssertFalse(manager.isGraphInputActive)
        let beforeSetupFrame = manager.camera.targetCameraPos
        callback(1 / 60)
        XCTAssertEqual(manager.camera.targetCameraPos, beforeSetupFrame,
                       "Controller setup must suspend scene input")
        manager.updateGraphInputFocus(appearsActive: true, mascotChatVisible: false,
                                      controllerSetupVisible: false)
        XCTAssertTrue(manager.isGraphInputActive)
        callback(1 / 60)
        XCTAssertNotEqual(manager.camera.targetCameraPos, beforeSetupFrame,
                          "Dismissing controller setup restores the active graph gate")
        var connections: [Bool] = []
        manager.controllerConnectionCallback = { connections.append($0) }
        input = nil
        callback(1 / 60)
        XCTAssertFalse(manager.hasGamepad)
        XCTAssertEqual(connections, [false])
    }

    func testMovementLookTriggersAndSprintUseExistingCameraDirections() {
        var input = state()
        input.leftX = 0.5
        input.leftY = 0.7
        input.rightX = -0.6
        input.rightY = 0.3
        input.leftTrigger = 0.4
        input.rightTrigger = 0.8
        input.sprint = true
        let camera = CameraController(), expected = CameraController()
        let dt: Float = 1 / 60
        expected.dolly(amount: 0.7 * 200 * dt * 3)
        expected.pan(dx: -0.5 * 300 * dt * 3, dy: 0)
        expected.lookRotate(deltaAz: 0.6 * 2 * dt, deltaEl: 0.3 * 2 * dt)
        expected.pan(dx: 0, dy: 0.8 * 300 * dt * 3)
        expected.pan(dx: 0, dy: -0.4 * 300 * dt * 3)
        _ = InputHandler().update(state: input, camera: camera, dt: dt, active: true)
        XCTAssertLessThan(simd_length(camera.targetCameraPos - expected.targetCameraPos), 0.001)
        XCTAssertEqual(camera.targetAzimuth, expected.targetAzimuth, accuracy: 0.0001)
        XCTAssertEqual(camera.targetElevation, expected.targetElevation, accuracy: 0.0001)
    }

    func testDeadzoneAndStalledFrameDoNotCreateUnboundedMovement() {
        let inputHandler = InputHandler(), camera = CameraController()
        var input = state()
        input.leftX = 0.09
        input.leftY = 0.09
        input.rightTrigger = 0.04
        _ = inputHandler.update(state: input, camera: camera, dt: 1 / 60, active: true)
        XCTAssertEqual(camera.targetCameraPos, .zero)
        input.leftY = 1
        _ = inputHandler.update(state: input, camera: camera, dt: 10, active: true)
        XCTAssertEqual(simd_length(camera.targetCameraPos), 10, accuracy: 0.001)
        let before = camera.targetCameraPos
        _ = inputHandler.update(state: input, camera: camera, dt: .nan, active: true)
        XCTAssertEqual(camera.targetCameraPos, before)
    }

    func testAllAdvertisedButtonsTriggerOncePerPress() {
        let handler = InputHandler(), camera = CameraController()
        _ = handler.update(state: state(), camera: camera, dt: 1 / 60, active: true)
        let cases: [(GamepadInputState.Buttons, GamepadAction)] = [
            (.a, .select), (.b, .cancel), (.x, .previousProject), (.y, .nextProject),
            (.leftShoulder, .previousGalaxy), (.rightShoulder, .nextGalaxy),
        ]
        for (button, action) in cases {
            XCTAssertEqual(handler.update(state: state(buttons: button), camera: camera,
                                           dt: 1 / 60, active: true), [action])
            XCTAssertEqual(handler.update(state: state(buttons: button), camera: camera,
                                           dt: 1 / 60, active: true), [])
            _ = handler.update(state: state(), camera: camera, dt: 1 / 60, active: true)
        }
    }

    func testReconnectAndFocusReturnRequireButtonRelease() {
        let handler = InputHandler(), camera = CameraController()
        let held = state(buttons: .a)
        XCTAssertEqual(handler.update(state: held, camera: camera, dt: 1 / 60, active: true), [])
        _ = handler.update(state: state(), camera: camera, dt: 1 / 60, active: true)
        XCTAssertEqual(handler.update(state: held, camera: camera, dt: 1 / 60, active: true), [.select])
        _ = handler.update(state: held, camera: camera, dt: 1 / 60, active: false)
        XCTAssertEqual(handler.update(state: held, camera: camera, dt: 1 / 60, active: true), [])
        _ = handler.update(state: nil, camera: camera, dt: 1 / 60, active: true)
        XCTAssertEqual(handler.update(state: held, camera: camera, dt: 1 / 60, active: true), [])
        let replacement = NSObject()
        var other = GamepadInputState(identity: ObjectIdentifier(replacement))
        other.buttons = .y
        XCTAssertEqual(handler.update(state: other, camera: camera, dt: 1 / 60, active: true), [])
        other.buttons = []
        _ = handler.update(state: other, camera: camera, dt: 1 / 60, active: true)
        other.buttons = .y
        XCTAssertEqual(handler.update(state: other, camera: camera, dt: 1 / 60, active: true), [.nextProject])
    }

    func testConnectedControllerFallbackAndCurrentControllerPreference() throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        first.extendedGamepad?.leftThumbstick.setValueForXAxis(0.25, yAxis: 0.75)
        second.extendedGamepad?.buttonX.setValue(1)
        let fallback = try XCTUnwrap(InputHandler.readGamepad(current: nil, controllers: [first, second]))
        XCTAssertEqual(fallback.identity, ObjectIdentifier(first))
        XCTAssertEqual(fallback.leftY, 0.75)
        let current = try XCTUnwrap(InputHandler.readGamepad(current: second, controllers: [first, second]))
        XCTAssertEqual(current.identity, ObjectIdentifier(second))
        XCTAssertTrue(current.buttons.contains(.x))
        XCTAssertNil(InputHandler.readGamepad(current: nil, controllers: []))
        let diagnostic = InputHandler.readGamepad(current: second, controllers: [first, second],
                                                   captureDiagnostics: true)
        XCTAssertEqual(diagnostic.state?.identity, current.identity)
        XCTAssertEqual(diagnostic.enumeration?.connectedCount, 2)
        XCTAssertEqual(diagnostic.enumeration?.supportedCount, 2)
        XCTAssertEqual(diagnostic.enumeration?.selection, "current")
        XCTAssertEqual(diagnostic.enumeration?.selectedConnectedIndex, 1)
        XCTAssertNotNil(diagnostic.enumeration?.selected?.extendedProfileClass)
        XCTAssertNil(InputHandler.readGamepad(current: first, controllers: [first],
                                               captureDiagnostics: false).enumeration)
    }

    func testCancelButtonReachesSelectionCallbackThroughSceneFrame() throws {
        let registry = GalaxyRegistry()
        var input = state()
        let manager = try XCTUnwrap(RKSceneManager(registry: registry,
            readGamepad: { input }, acceptsGamepadInput: { true }))
        manager.isGraphInputActive = true
        manager.selectedNode = UUID()
        var selections: [UUID?] = []
        manager.selectionCallback = { selections.append($0) }
        let callback = try XCTUnwrap(manager.rkScene.onFrameCallback)
        callback(1 / 60)
        input.buttons = .b
        callback(1 / 60)
        XCTAssertNil(manager.selectedNode)
        XCTAssertEqual(selections.count, 1)
        XCTAssertNil(selections[0])
        callback(1 / 60)
        XCTAssertEqual(selections.count, 1, "Holding B must not spam selection/UI changes")
    }

    func testControllerDiagnosticCadenceWaitsForActiveWindowAndThenStops() {
        var cadence = GamepadDiagnosticCadence(duration: 120)
        XCTAssertEqual(cadence.next(now: 10, armReady: false), .waiting)
        XCTAssertNil(cadence.next(now: 1000, armReady: false))
        XCTAssertNil(cadence.armedAt, "An unattended launch must not consume the capture window")
        XCTAssertEqual(cadence.next(now: 1001, armReady: true), .capturing)
        XCTAssertEqual(cadence.armedAt, 1001)
        XCTAssertNil(cadence.next(now: 1001.9, armReady: true))
        XCTAssertEqual(cadence.next(now: 1002, armReady: true), .capturing)
        XCTAssertEqual(cadence.next(now: 1121, armReady: false), .finished)
        XCTAssertTrue(cadence.finished)
        XCTAssertNil(cadence.next(now: 1122, armReady: true))
    }

    func testControllerDiagnosticCadenceBoundsDenseFrameCallsAndInvalidClock() {
        var cadence = GamepadDiagnosticCadence(duration: 600)
        XCTAssertNil(cadence.next(now: .nan, armReady: true))
        var rows = 0
        for index in 0...72_000 {
            if cadence.next(now: Double(index) / 60, armReady: true) != nil { rows += 1 }
        }
        XCTAssertLessThanOrEqual(rows, 602)
        XCTAssertGreaterThan(rows, 500)
        XCTAssertTrue(cadence.finished)
    }

    func testControllerDiagnosticsAccumulateInputBetweenRowsWithoutUIContent() throws {
        let configuration = try XCTUnwrap(GamepadDiagnosticConfiguration(
            environment: ["ENGRAM_CONTROLLER_STATS": "/diagnostics/controller.jsonl"]))
        var rows: [GamepadDiagnosticRecord] = []
        let recorder = GamepadDiagnosticRecorder(configuration: configuration) { rows.append($0) }
        let gate = GamepadGateDiagnostics(graphHostVisible: true, hostAppearsActive: true,
            mascotChatVisible: false, graphInputActive: true, appActive: true, keyWindowNumber: 7,
            attachedSheet: false, firstResponderClass: "NSView", firstResponderIsTextView: false,
            applicationGateAccepted: true, inputAccepted: true)
        func frame(_ time: Double, input: GamepadInputState, cameraChanged: Bool) {
            let phase = recorder.nextPhase(now: time, armReady: true)
            recorder.observe(now: time, phase: phase,
                reading: GamepadInputReading(state: input, enumeration: nil), gate: phase == nil ? nil : gate,
                inputAccepted: true, cameraTargetChanged: cameraChanged, cameraLookChanged: false)
        }
        frame(0, input: state(), cameraChanged: false)
        var moving = state(); moving.leftY = 1
        frame(0.2, input: moving, cameraChanged: true)
        frame(0.4, input: state(), cameraChanged: false)
        frame(1, input: state(), cameraChanged: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[1].input.nonNeutral)
        XCTAssertEqual(rows[1].sincePreviousRecord.frames, 3)
        XCTAssertEqual(rows[1].sincePreviousRecord.framesWithNonNeutralInput, 1)
        XCTAssertEqual(rows[1].sincePreviousRecord.framesWithMovementPastDeadzone, 1)
        XCTAssertEqual(rows[1].sincePreviousRecord.framesWithAcceptedMovementInput, 1)
        XCTAssertEqual(rows[1].sincePreviousRecord.framesWithCameraTargetChange, 1)
        let encoded = String(decoding: try JSONEncoder().encode(rows[1]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("identity"), "ObjectIdentifier must not enter the diagnostic")
        XCTAssertFalse(encoded.contains("serial"))
        XCTAssertTrue(encoded.contains("firstResponderClass"))
    }

    func testControllerDiagnosticConfigurationRequiresAbsolutePathAndBoundsDuration() throws {
        XCTAssertNil(GamepadDiagnosticConfiguration(environment: [:]))
        XCTAssertNil(GamepadDiagnosticConfiguration(environment: ["ENGRAM_CONTROLLER_STATS": "relative.jsonl"]))
        XCTAssertNil(GamepadDiagnosticConfiguration(environment: ["ENGRAM_CONTROLLER_STATS": "/diagnostics/"]))
        for (requested, expected) in [("120", 120.0), ("10000", 600.0), ("0.1", 1.0),
                                      ("nan", 120.0), ("-1", 120.0), ("invalid", 120.0)] {
            let configuration = try XCTUnwrap(GamepadDiagnosticConfiguration(environment: [
                "ENGRAM_CONTROLLER_STATS": "/diagnostics/controller.jsonl",
                "ENGRAM_CONTROLLER_STATS_SECONDS": requested,
            ]))
            XCTAssertEqual(configuration.duration, expected)
        }
    }

}
