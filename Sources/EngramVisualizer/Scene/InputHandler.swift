import GameController
import EngramRealityKit

/// Values read once per scene frame. Keeping hardware reads separate lets tests
/// exercise the same camera/action path without synthesizing OS input events.
struct GamepadInputState {
    struct Buttons: OptionSet {
        let rawValue: UInt8
        static let a = Self(rawValue: 1 << 0)
        static let b = Self(rawValue: 1 << 1)
        static let x = Self(rawValue: 1 << 2)
        static let y = Self(rawValue: 1 << 3)
        static let leftShoulder = Self(rawValue: 1 << 4)
        static let rightShoulder = Self(rawValue: 1 << 5)
    }

    let identity: ObjectIdentifier
    var leftX: Float = 0
    var leftY: Float = 0
    var rightX: Float = 0
    var rightY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var sprint = false
    var buttons: Buttons = []
}

enum GamepadAction: Equatable {
    case select, cancel, previousProject, nextProject, previousGalaxy, nextGalaxy
}

/// Shared by the normal and instrumented RealityKit frame callbacks. No graph
/// snapshots or hit tests are needed to read a controller or move the camera.
@MainActor
final class InputHandler {
    private var controllerIdentity: ObjectIdentifier?
    private var previousButtons: GamepadInputState.Buttons = []
    private var awaitingButtonRelease = true

    static func readGamepad() -> GamepadInputState? {
        readGamepad(current: GCController.current, controllers: GCController.controllers())
    }

    static func readGamepad(current: GCController?, controllers: [GCController]) -> GamepadInputState? {
        // `current` is the most recently used controller, not the list of
        // connected devices. Include one already connected before app launch.
        let controller: GCController?
        if let current, current.extendedGamepad != nil {
            controller = current
        } else {
            controller = controllers.first { $0.extendedGamepad != nil }
        }
        guard let controller, let gamepad = controller.extendedGamepad else { return nil }
        var state = GamepadInputState(identity: ObjectIdentifier(controller))
        state.leftX = gamepad.leftThumbstick.xAxis.value
        state.leftY = gamepad.leftThumbstick.yAxis.value
        state.rightX = gamepad.rightThumbstick.xAxis.value
        state.rightY = gamepad.rightThumbstick.yAxis.value
        state.leftTrigger = gamepad.leftTrigger.value
        state.rightTrigger = gamepad.rightTrigger.value
        state.sprint = (gamepad.leftThumbstickButton?.isPressed ?? false)
            || (gamepad.rightThumbstickButton?.isPressed ?? false)
        if gamepad.buttonA.isPressed { state.buttons.insert(.a) }
        if gamepad.buttonB.isPressed { state.buttons.insert(.b) }
        if gamepad.buttonX.isPressed { state.buttons.insert(.x) }
        if gamepad.buttonY.isPressed { state.buttons.insert(.y) }
        if gamepad.leftShoulder.isPressed { state.buttons.insert(.leftShoulder) }
        if gamepad.rightShoulder.isPressed { state.buttons.insert(.rightShoulder) }
        return state
    }

    func reset() {
        controllerIdentity = nil
        previousButtons = []
        awaitingButtonRelease = true
    }

    func update(state: GamepadInputState?, camera: CameraController,
                dt: Float, active: Bool) -> [GamepadAction] {
        guard active, let state else { reset(); return [] }
        if controllerIdentity != state.identity {
            reset()
            controllerIdentity = state.identity
        }
        // A stalled render frame must not turn a held stick into a huge jump.
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        let sprint: Float = state.sprint ? 3 : 1
        if abs(state.leftY) > 0.1 { camera.dolly(amount: state.leftY * 200 * step * sprint) }
        if abs(state.leftX) > 0.1 { camera.pan(dx: -state.leftX * 300 * step * sprint, dy: 0) }
        if abs(state.rightX) > 0.1 || abs(state.rightY) > 0.1 {
            camera.lookRotate(deltaAz: -state.rightX * 2 * step, deltaEl: state.rightY * 2 * step)
        }
        if state.rightTrigger > 0.05 { camera.pan(dx: 0, dy: state.rightTrigger * 300 * step * sprint) }
        if state.leftTrigger > 0.05 { camera.pan(dx: 0, dy: -state.leftTrigger * 300 * step * sprint) }

        // Ignore buttons held while connecting, switching controllers, or
        // returning from another window. Require release before a new action.
        if awaitingButtonRelease {
            previousButtons = state.buttons
            awaitingButtonRelease = !state.buttons.isEmpty
            return []
        }
        let pressed = state.buttons.subtracting(previousButtons)
        previousButtons = state.buttons
        var actions: [GamepadAction] = []
        if pressed.contains(.a) { actions.append(.select) }
        if pressed.contains(.b) { actions.append(.cancel) }
        if pressed.contains(.x) { actions.append(.previousProject) }
        if pressed.contains(.y) { actions.append(.nextProject) }
        if pressed.contains(.leftShoulder) { actions.append(.previousGalaxy) }
        if pressed.contains(.rightShoulder) { actions.append(.nextGalaxy) }
        return actions
    }
}
