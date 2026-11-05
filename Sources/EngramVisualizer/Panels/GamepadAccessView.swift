import AppKit
import IOKit.hid
import IOKit.hidsystem
import SwiftUI

/// Shown only for a connected, recognized fallback profile. Standard
/// devices available through GameController skip this setup flow.
struct GamepadAccessView: View {
    let status: HIDGamepadInputStatus
    @Binding var isPresented: Bool
    @State private var isRequesting = false

    var body: some View {
        Group {
            if status == .permissionRequired {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Xbox controller needs input access", systemImage: "gamecontroller")
                        .font(.callout.weight(.medium))
                    Text("Enable controller input in macOS to use this controller with Engram.")
                        .font(.caption)
                    Button("Enable Controller…") { isPresented = true }
                        .disabled(isRequesting)
                        .accessibilityIdentifier("controller.access.setup")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if status == .awaitingNeutral {
                Text("Move a stick, then release all controller controls to begin.")
                    .font(.callout)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("controller.awaiting-neutral")
            } else if status == .failed {
                Text("Controller input is unavailable. Reconnect the controller to try again.")
                    .font(.callout)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .alert("Allow controller input?", isPresented: $isPresented) {
            Button("Open System Settings") { requestInputAccess() }
                .disabled(isRequesting)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("macOS calls this Input Monitoring and permits keyboard input access. Engram's controller reader uses it only for the recognized controller's gamepad controls. You can turn access off in System Settings at any time.")
        }
    }

    private func requestInputAccess() {
        guard !isRequesting else { return }
        isRequesting = true
        // This is the only access request, following the explicit setup action.
        // Discovery and input polling only check existing permission.
        Task { @MainActor in
            _ = await Task.detached(priority: .userInitiated) {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }.value
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
            isRequesting = false
        }
    }
}
