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
}
