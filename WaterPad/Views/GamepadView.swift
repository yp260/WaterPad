import SwiftUI

/// 横屏虚拟手柄主界面。
struct GamepadView: View {
    @EnvironmentObject private var pad: PadState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var haptics: HapticEngineController

    @State private var dpadDX = 0
    @State private var dpadDY = 0

    private var profile: ControllerProfile { settings.profile }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leftCluster
            Spacer(minLength: 0)
            centerCluster
            Spacer(minLength: 0)
            rightCluster
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - 左侧：肩键、十字键、左摇杆

    private var leftCluster: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                smallButton(.leftShoulder, shoulderLabels.left)
                smallButton(.leftTriggerClick, shoulderLabels.leftTrigger)
            }
            HStack(spacing: 12) {
                DPadView(dx: dpadDX, dy: dpadDY) { x, y in
                    dpadDX = x
                    dpadDY = y
                    pad.setDpad(dx: x, dy: y)
                    if x != 0 || y != 0 { haptics.playTap() }
                }
                JoystickView(
                    label: "左摇杆",
                    x: pad.snapshot.leftX,
                    y: pad.snapshot.leftY,
                    onChange: { x, y in pad.setLeftStick(x: x, y: y) },
                    onRelease: { pad.setLeftStick(x: 0, y: 0) }
                )
            }
        }
    }

    // MARK: - 中间：功能键与模拟扳机

    private var centerCluster: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                smallButton(.back, "Back")
                smallButton(.guide, "Home")
                smallButton(.start, "Start")
            }
            TriggerSliderView(label: "LT", value: pad.snapshot.leftTrigger) {
                pad.setLeftTrigger($0)
            }
            TriggerSliderView(label: "RT", value: pad.snapshot.rightTrigger) {
                pad.setRightTrigger($0)
            }
            HStack(spacing: 8) {
                smallButton(.leftStick, "L3")
                smallButton(.rightStick, "R3")
                smallButton(.capture, "Share")
            }
            Text(profile.displayName)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button("全部松开") {
                pad.reset()
                dpadDX = 0
                dpadDY = 0
            }
            .font(.caption2)
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 190)
    }

    // MARK: - 右侧：肩键、右摇杆、面键

    private var rightCluster: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                smallButton(.rightShoulder, shoulderLabels.right)
                smallButton(.rightTriggerClick, shoulderLabels.rightTrigger)
            }
            HStack(spacing: 12) {
                JoystickView(
                    label: "右摇杆",
                    x: pad.snapshot.rightX,
                    y: pad.snapshot.rightY,
                    onChange: { x, y in pad.setRightStick(x: x, y: y) },
                    onRelease: { pad.setRightStick(x: 0, y: 0) }
                )
                ZStack {
                    faceButton(.north).offset(x: 0, y: -40)
                    faceButton(.west).offset(x: -40, y: 0)
                    faceButton(.east).offset(x: 40, y: 0)
                    faceButton(.south).offset(x: 0, y: 40)
                }
                .frame(width: 128, height: 128)
            }
        }
    }

    // MARK: - 组件封装

    private func isPressed(_ button: PadButton) -> Bool {
        pad.snapshot.pressed.contains(button)
    }

    private func press(_ button: PadButton, _ value: Bool) {
        pad.setButton(button, isPressed: value)
        if value { haptics.playTap() }
    }

    private func faceButton(_ button: PadButton) -> some View {
        PadButtonView(
            label: profile.label(for: button),
            isPressed: isPressed(button),
            onChange: { press(button, $0) },
            diameter: 42,
            fontSize: 15
        )
    }

    private func smallButton(_ button: PadButton, _ label: String) -> some View {
        PadButtonView(
            label: label,
            isPressed: isPressed(button),
            onChange: { press(button, $0) },
            diameter: 34,
            fontSize: 10
        )
    }

    private var shoulderLabels: (left: String, right: String, leftTrigger: String, rightTrigger: String) {
        switch profile.id {
        case "dualShock4": return ("L1", "R1", "L2", "R2")
        case "switchPro": return ("L", "R", "ZL", "ZR")
        default: return ("LB", "RB", "LT", "RT")
        }
    }
}
