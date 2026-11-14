import SwiftUI

/// 横屏虚拟手柄主界面。所有主要控件的位置与大小由 PadLayout 驱动，
/// 进入编辑态后可在屏幕上拖动改变位置、用滑块改变大小，退出时自动保存。
struct GamepadView: View {
    @EnvironmentObject private var pad: PadState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var haptics: HapticEngineController

    @State private var dpadDX = 0
    @State private var dpadDY = 0
    /// 编辑态下的草稿布局，退出时写回 settings.layout。
    @State private var draft: PadLayout = .default
    /// 当前选中的控件（编辑态下用于底部大小滑块）。
    @State private var selected: ControlID? = nil

    private var profile: ControllerProfile { settings.profile }
    private var editing: Bool { settings.isEditingLayout }

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            let layout = editing ? draft : settings.layout
            ZStack {
                ForEach(ControlID.allCases) { id in
                    layoutHandle(for: id, layout: layout, area: area)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: settings.isEditingLayout) { _ in
                if settings.isEditingLayout {
                    draft = settings.layout
                    selected = nil
                } else {
                    selected = nil
                }
            }
            .overlay(alignment: .bottom) {
                if editing {
                    editPanel(area: area)
                }
            }
        }
    }

    // MARK: - 定位与编辑包装

    private func layoutHandle(for id: ControlID, layout: PadLayout, area: CGSize) -> some View {
        LayoutControl(
            item: binding(for: id),
            areaSize: area,
            baseSize: id.baseSize,
            editing: editing,
            onSelect: { selected = id },
            content: { controlContent(for: id) }
        )
    }

    /// 返回一个可写回 draft 或 settings.layout 的绑定，绕开 @State 值类型直接赋值的坑。
    private func binding(for id: ControlID) -> Binding<LayoutItem> {
        editing
            ? Binding(
                get: { draft[id] },
                set: { nv in
                    var copy = draft
                    copy[id] = nv
                    draft = copy
                }
            )
            : Binding(
                get: { settings.layout[id] },
                set: { nv in
                    var copy = settings.layout
                    copy[id] = nv
                    settings.layout = copy
                }
            )
    }

    // MARK: - 控件内容

    @ViewBuilder
    private func controlContent(for id: ControlID) -> some View {
        let item = (editing ? draft : settings.layout)[id]
        switch id {
        case .leftStick:
            JoystickView(
                label: "", x: pad.snapshot.leftX, y: pad.snapshot.leftY, scale: item.scale,
                onChange: { pad.setLeftStick(x: $0, y: $1) },
                onRelease: { pad.setLeftStick(x: 0, y: 0) }
            )
        case .rightStick:
            JoystickView(
                label: "", x: pad.snapshot.rightX, y: pad.snapshot.rightY, scale: item.scale,
                onChange: { pad.setRightStick(x: $0, y: $1) },
                onRelease: { pad.setRightStick(x: 0, y: 0) }
            )
        case .dpad:
            DPadView(dx: dpadDX, dy: dpadDY, scale: item.scale) { x, y in
                dpadDX = x
                dpadDY = y
                pad.setDpad(dx: x, dy: y)
                if x != 0 || y != 0 { haptics.playTap() }
            }
        case .faceNorth:
            faceButton(.north, scale: item.scale)
        case .faceEast:
            faceButton(.east, scale: item.scale)
        case .faceSouth:
            faceButton(.south, scale: item.scale)
        case .faceWest:
            faceButton(.west, scale: item.scale)
        case .leftShoulder:
            smallButton(.leftShoulder, shoulderLabels.left, scale: item.scale)
        case .rightShoulder:
            smallButton(.rightShoulder, shoulderLabels.right, scale: item.scale)
        case .leftTriggerClick:
            smallButton(.leftTriggerClick, shoulderLabels.leftTrigger, scale: item.scale)
        case .rightTriggerClick:
            smallButton(.rightTriggerClick, shoulderLabels.rightTrigger, scale: item.scale)
        case .back:
            smallButton(.back, "Back", scale: item.scale)
        case .start:
            smallButton(.start, "Start", scale: item.scale)
        case .guide:
            smallButton(.guide, "Home", scale: item.scale)
        case .leftStickClick:
            smallButton(.leftStick, "L3", scale: item.scale)
        case .rightStickClick:
            smallButton(.rightStick, "R3", scale: item.scale)
        case .capture:
            smallButton(.capture, "Share", scale: item.scale)
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

    private func faceButton(_ button: PadButton, scale: Double = 1) -> some View {
        PadButtonView(
            label: profile.label(for: button),
            isPressed: isPressed(button),
            onChange: { press(button, $0) },
            diameter: 42 * scale,
            fontSize: 15 * scale
        )
    }

    private func smallButton(_ button: PadButton, _ label: String, scale: Double = 1) -> some View {
        PadButtonView(
            label: label,
            isPressed: isPressed(button),
            onChange: { press(button, $0) },
            diameter: 34 * scale,
            fontSize: max(8, 10 * scale)
        )
    }

    private var shoulderLabels: (left: String, right: String, leftTrigger: String, rightTrigger: String) {
        switch profile.id {
        case "dualShock4": return ("L1", "R1", "L2", "R2")
        case "switchPro": return ("L", "R", "ZL", "ZR")
        default: return ("LB", "RB", "LT", "RT")
        }
    }

    // MARK: - 编辑面板

    @ViewBuilder
    private func editPanel(area: CGSize) -> some View {
        VStack(spacing: 6) {
            HStack {
                Button("重置布局") {
                    draft = .default
                    selected = nil
                }
                .font(.caption)
                Spacer()
                if let sel = selected {
                    Text(controlName(sel))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("完成") {
                    var copy = settings.layout
                    copy = draft
                    settings.layout = copy
                    settings.persistLayout()
                    settings.isEditingLayout = false
                }
                .font(.caption.bold())
            }
            .padding(.horizontal, 4)
            if let sel = selected {
                HStack {
                    Text("大小")
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { draft[sel].scale },
                            set: { nv in
                                var copy = draft
                                copy[sel].scale = nv
                                draft = copy
                            }
                        ),
                        in: 0.5...2.0
                    )
                    Text("\(Int(draft[sel].scale * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 4)
            }
            Text("拖动按钮调整位置，选中后拖动滑块调整大小")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(.regularMaterial)
        .cornerRadius(14)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func controlName(_ id: ControlID) -> String {
        switch id {
        case .leftStick: return "左摇杆"
        case .rightStick: return "右摇杆"
        case .dpad: return "十字键"
        case .faceNorth: return "面键·上"
        case .faceEast: return "面键·右"
        case .faceSouth: return "面键·下"
        case .faceWest: return "面键·左"
        case .leftShoulder: return shoulderLabels.left
        case .rightShoulder: return shoulderLabels.right
        case .leftTriggerClick: return shoulderLabels.leftTrigger
        case .rightTriggerClick: return shoulderLabels.rightTrigger
        case .back: return "Back"
        case .start: return "Start"
        case .guide: return "Home"
        case .leftStickClick: return "L3"
        case .rightStickClick: return "R3"
        case .capture: return "Share"
        }
    }
}

/// 单个控件的定位与编辑包装。非编辑态正常响应内部手势；
/// 编辑态关闭内部命中测试，改用外层拖拽移动，并显示定位高亮框。
private struct LayoutControl<Content: View>: View {
    @Binding var item: LayoutItem
    let areaSize: CGSize
    let baseSize: CGFloat
    let editing: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragStart: CGPoint?

    var body: some View {
        content()
            .allowsHitTesting(!editing)
            .frame(width: baseSize * item.scale, height: baseSize * item.scale)
            .position(x: item.x * areaSize.width, y: item.y * areaSize.height)
            .overlay(editHighlight)
            .gesture(editing ? dragGesture : nil)
    }

    private var dragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture()
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = CGPoint(x: item.x, y: item.y)
                        onSelect()
                    }
                    guard let start = dragStart else { return }
                    let nx = start.x + Double(value.translation.width) / Double(areaSize.width)
                    let ny = start.y + Double(value.translation.height) / Double(areaSize.height)
                    item.x = min(1, max(0, nx))
                    item.y = min(1, max(0, ny))
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    @ViewBuilder
    private var editHighlight: some View {
        if editing {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                .frame(width: baseSize * item.scale + 10, height: baseSize * item.scale + 10)
        }
    }
}
