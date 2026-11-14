import SwiftUI

/// 横屏虚拟手柄主界面。所有主要控件的位置与大小由 PadLayout 驱动。
///
/// 布局编辑态的交互约定（v0.0.6 重写）：
///   - 轻点控件即选中：拖拽手势用 minimumDistance 0，指尖落下就完成选中，
///     不再需要「先精准点中、再拖动」；
///   - 拖动控件改位置，双指捏合改大小；
///   - 底部面板提供按名称选择控件的胶囊条，以及 X / Y / 大小三条滑块与步进按钮，
///     每一个按钮都能被单独调整；
///   - 任何改动即时写入设置并持久化，离开编辑态不会丢。
struct GamepadView: View {
    @EnvironmentObject private var pad: PadState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var haptics: HapticEngineController

    @State private var dpadDX = 0
    @State private var dpadDY = 0
    /// 编辑态草稿。改动先写这里，提交时同步到 settings.layout。
    @State private var draft: PadLayout = .default
    /// 进入编辑态时的快照，供「取消」回滚。
    @State private var snapshot: PadLayout = .default
    /// 当前选中的控件（编辑态下决定底部面板调谁）。
    @State private var selected: ControlID? = nil

    private var profile: ControllerProfile { settings.profile }
    private var editing: Bool { settings.isEditingLayout }

    /// 拖拽用的命名坐标系。它固定在手柄区上，不随控件移动，
    /// 因此拖动过程中位移不会被自身移动反复放大。
    private static let areaSpace = "waterpad.area"

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            ZStack {
                ForEach(ControlID.allCases) { id in
                    layoutHandle(for: id, area: area)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: Self.areaSpace)
            .onChange(of: settings.isEditingLayout) { newValue in
                if newValue {
                    snapshot = settings.layout
                    draft = settings.layout
                    selected = nil
                } else {
                    commit()
                    selected = nil
                }
            }
            .overlay(alignment: .bottom) {
                if editing {
                    LayoutEditorPanel(
                        layout: $draft,
                        selected: $selected,
                        onResetAll: { draft = .default },
                        onCancel: {
                            draft = snapshot
                            settings.isEditingLayout = false
                        },
                        onDone: {
                            commit()
                            settings.isEditingLayout = false
                        },
                        onChange: { commit() }
                    )
                }
            }
        }
    }

    // MARK: - 定位与编辑包装

    private func layoutHandle(for id: ControlID, area: CGSize) -> some View {
        LayoutControl(
            item: binding(for: id),
            areaSize: area,
            baseSize: id.baseSize,
            editing: editing,
            isSelected: selected == id,
            displayName: id.displayName,
            areaSpace: Self.areaSpace,
            onSelect: { selected = id },
            onCommit: { commit() },
            content: { controlContent(for: id) }
        )
    }

    /// 返回一个可写回 draft 或 settings.layout 的绑定，绕开 @State 值类型直接赋值的坑。
    private func binding(for id: ControlID) -> Binding<LayoutItem> {
        if editing {
            return Binding(
                get: { draft[id] },
                set: { nv in
                    var copy = draft
                    copy[id] = nv
                    draft = copy
                }
            )
        }
        return Binding(
            get: { settings.layout[id] },
            set: { nv in
                var copy = settings.layout
                copy[id] = nv
                settings.layout = copy
            }
        )
    }

    /// 把草稿写回设置并持久化。每次拖动/微调结束都会调用。
    private func commit() {
        var copy = draft
        for id in ControlID.allCases {
            var item = copy[id]
            item.clamp()
            copy[id] = item
        }
        draft = copy
        settings.layout = copy
        settings.persistLayout()
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
            diameter: 46 * scale,
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
}

/// 单个控件的定位与编辑包装。
///
/// 非编辑态：控件自身的手势生效（按压、摇杆、十字键）。
/// 编辑态：控件本体停止命中测试，由外层统一接管
///   - 轻点选中（minimumDistance 0，指尖落下即选中）；
///   - 拖动改位置；
///   - 双指捏合改大小。
private struct LayoutControl<Content: View>: View {
    @Binding var item: LayoutItem
    let areaSize: CGSize
    let baseSize: CGFloat
    let editing: Bool
    let isSelected: Bool
    let displayName: String
    let areaSpace: String
    let onSelect: () -> Void
    let onCommit: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragStartX: Double? = nil
    @State private var dragStartY: Double? = nil
    @State private var pinchBase: Double? = nil

    private var side: CGFloat { baseSize * item.scale }

    var body: some View {
        content()
            .allowsHitTesting(!editing)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .overlay(highlight)
            .overlay(alignment: .top) { badge }
            .overlay { hitArea }
            .position(x: item.x * areaSize.width, y: item.y * areaSize.height)
            .gesture(editing ? dragGesture : nil)
            .simultaneousGesture(editing ? pinchGesture : nil)
    }

    /// 编辑态下的透明命中层。比控件本体略大，方便手指抓取。
    @ViewBuilder
    private var hitArea: some View {
        if editing {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: side + 16, height: side + 16)
        }
    }

    @ViewBuilder
    private var highlight: some View {
        if editing {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            Color.accentColor.opacity(isSelected ? 0.95 : 0.40),
                            style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1, dash: isSelected ? [] : [5, 4])
                        )
                )
                .frame(width: side + 18, height: side + 18)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if editing && isSelected {
            Text(displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(Capsule())
                .offset(y: -side / 2 - 12)
        }
    }

    private var dragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(areaSpace))
                .onChanged { value in
                    if dragStartX == nil || dragStartY == nil {
                        dragStartX = item.x
                        dragStartY = item.y
                        onSelect()
                    }
                    guard let startX = dragStartX, let startY = dragStartY else { return }
                    let width = max(1, Double(areaSize.width))
                    let height = max(1, Double(areaSize.height))
                    var updated = item
                    updated.x = min(1, max(0, startX + Double(value.translation.width) / width))
                    updated.y = min(1, max(0, startY + Double(value.translation.height) / height))
                    item = updated
                }
                .onEnded { _ in
                    dragStartX = nil
                    dragStartY = nil
                    onCommit()
                }
        )
    }

    private var pinchGesture: AnyGesture<CGFloat> {
        AnyGesture(
            MagnificationGesture()
                .onChanged { value in
                    if pinchBase == nil {
                        pinchBase = item.scale
                    }
                    let base = pinchBase ?? 1
                    var updated = item
                    updated.scale = min(2.0, max(0.5, base * Double(value)))
                    item = updated
                }
                .onEnded { _ in
                    pinchBase = nil
                    onCommit()
                }
        )
    }
}
