import SwiftUI

/// 布局编辑面板。
///
/// 解决「每个按钮没法调节大小和位置」的三个症结：
///   1. 名称选择器：所有 17 个控件以名称胶囊列出，点一下即选中，
///      不必在屏幕上精准命中几十点的小按钮；
///   2. 三条滑块 + 步进按钮：X、Y 位置与大小都能用数值精确设置；
///   3. 提示常驻：随时能看到当前调的是哪个控件、大小百分比是多少。
struct LayoutEditorPanel: View {
    @Binding var layout: PadLayout
    @Binding var selected: ControlID?
    @Binding var panelExpanded: Bool
    let onResetAll: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            header
            if panelExpanded {
                picker
                if let sel = selected {
                    positionRow(sel)
                    sizeRow(sel)
                } else {
                    Text("轻点屏幕上的控件，或在上面的名称条里选一个按钮")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            } else {
                // 收起时留一条细边，显示当前选中项与数值，方便确认状态又不挡控件
                if let sel = selected {
                    Text("\(sel.displayName)　X \(Int((layout[sel].x * 100).rounded()))%　Y \(Int((layout[sel].y * 100).rounded()))%　大小 \(Int((layout[sel].scale * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("面板已收起，轻点控件仍可拖动")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.25)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                panelExpanded.toggle()
            } label: {
                Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            Text(selected.map { "\($0.displayName)" } ?? "未选中控件")
                .font(.caption.bold())
                .lineLimit(1)
                .frame(minWidth: 70, alignment: .leading)
            Spacer(minLength: 2)
            if panelExpanded {
                Button("重置全部") { onResetAll(); onChange() }
                    .font(.caption)
                Button("取消") { onCancel() }
                    .font(.caption)
                Button("完成") { onDone() }
                    .font(.caption.bold())
            }
        }
    }

    /// 按名称选择控件。每个控件都在列表里，谁都能被单独调。
    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ControlID.allCases) { id in
                    Button {
                        selected = id
                    } label: {
                        Text(id.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundColor(selected == id ? .white : .primary)
                            .background(selected == id ? Color.accentColor : Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 26)
    }

    // MARK: - 位置

    private func positionRow(_ id: ControlID) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("X").font(.caption2).frame(width: 10, alignment: .leading)
                Slider(value: binding(id, \.x, 0...1)) { isEditing in
                    if !isEditing { onChange() }
                }
                Text("\(Int((layout[id].x * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text("Y").font(.caption2).frame(width: 10, alignment: .leading)
                Slider(value: binding(id, \.y, 0...1)) { isEditing in
                    if !isEditing { onChange() }
                }
                Text("\(Int((layout[id].y * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 6) {
                stepButton("arrow.left") { nudge(id, dx: -0.01, dy: 0) }
                stepButton("arrow.right") { nudge(id, dx: 0.01, dy: 0) }
                stepButton("arrow.up") { nudge(id, dx: 0, dy: -0.01) }
                stepButton("arrow.down") { nudge(id, dx: 0, dy: 0.01) }
                Text("位置微调 1%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer(minLength: 2)
                stepButton("minus") { setScale(id, layout[id].scale - 0.05) }
                stepButton("plus") { setScale(id, layout[id].scale + 0.05) }
                Text("大小 ±5%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 大小

    private func sizeRow(_ id: ControlID) -> some View {
        HStack(spacing: 6) {
            Text("大小").font(.caption2).frame(width: 28, alignment: .leading)
            Slider(value: binding(id, \.scale, 0.5...2.0)) { isEditing in
                if !isEditing { onChange() }
            }
            Text("\(Int((layout[id].scale * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            Button("复位") { setScale(id, 1.0) }
                .font(.caption2)
        }
    }

    // MARK: - 数据操作

    private func binding(_ id: ControlID, _ keyPath: WritableKeyPath<LayoutItem, Double>,
                         _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { layout[id][keyPath: keyPath] },
            set: { newValue in
                var copy = layout
                var item = copy[id]
                item[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, newValue))
                copy[id] = item
                layout = copy
            }
        )
    }

    private func nudge(_ id: ControlID, dx: Double, dy: Double) {
        var copy = layout
        var item = copy[id]
        item.x = min(1, max(0, item.x + dx))
        item.y = min(1, max(0, item.y + dy))
        copy[id] = item
        layout = copy
        onChange()
    }

    private func setScale(_ id: ControlID, _ scale: Double) {
        var copy = layout
        var item = copy[id]
        item.scale = min(2.0, max(0.5, scale))
        copy[id] = item
        layout = copy
        onChange()
    }

    private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}
