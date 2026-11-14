import SwiftUI

/// 虚拟摇杆。输出 -1 到 1 的归一化坐标，松手自动回中。
struct JoystickView: View {
    let label: String
    let x: Double
    let y: Double
    var scale: CGFloat = 1
    let onChange: (Double, Double) -> Void
    let onRelease: () -> Void

    @State private var touching = false

    private var radius: CGFloat { 56 * scale }
    private var knobRadius: CGFloat { 22 * scale }
    private var travel: CGFloat { radius - knobRadius }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Color(UIColor.secondarySystemBackground))
                Circle()
                    .stroke(Color(UIColor.separator), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: radius, y: 8))
                    path.addLine(to: CGPoint(x: radius, y: radius * 2 - 8))
                    path.move(to: CGPoint(x: 8, y: radius))
                    path.addLine(to: CGPoint(x: radius * 2 - 8, y: radius))
                }
                .stroke(Color(UIColor.separator).opacity(0.6), lineWidth: 0.5)
                Circle()
                    .fill(Color.accentColor.opacity(touching ? 0.95 : 0.65))
                    .frame(width: knobRadius * 2, height: knobRadius * 2)
                    .offset(x: CGFloat(x) * travel, y: CGFloat(y) * travel)
            }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !touching {
                            touching = true
                        }
                        var dx = Double(value.location.x - radius) / Double(travel)
                        var dy = Double(value.location.y - radius) / Double(travel)
                        let length = (dx * dx + dy * dy).squareRoot()
                        if length > 1 {
                            dx /= length
                            dy /= length
                        }
                        onChange(dx, dy)
                    }
                    .onEnded { _ in
                        touching = false
                        onRelease()
                    }
            )
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 按住式按键。用零距离拖动手势实现按下与抬起，避免系统按钮的点击延迟。
struct PadButtonView: View {
    let label: String
    let isPressed: Bool
    let onChange: (Bool) -> Void
    var diameter: CGFloat = 46
    var fontSize: CGFloat = 14

    @State private var touching = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isPressed ? Color.accentColor : Color(UIColor.secondarySystemBackground))
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
            Text(label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(isPressed ? .white : .primary)
                .minimumScaleFactor(0.5)
                .padding(4)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !touching {
                        touching = true
                        onChange(true)
                    }
                }
                .onEnded { _ in
                    touching = false
                    onChange(false)
                }
        )
    }
}

/// 十字键。四个方向按钮按下时组合成 Hat Switch 方向，松开回到空位态。
struct DPadView: View {
    let dx: Int
    let dy: Int
    var scale: CGFloat = 1
    let onChange: (Int, Int) -> Void

    private var size: CGFloat { 38 * scale }

    var body: some View {
        VStack(spacing: 2) {
            directionButton(symbol: "▲", x: 0, y: -1)
            HStack(spacing: 2) {
                directionButton(symbol: "◀", x: -1, y: 0)
                Rectangle().fill(Color.clear).frame(width: size, height: size)
                directionButton(symbol: "▶", x: 1, y: 0)
            }
            directionButton(symbol: "▼", x: 0, y: 1)
        }
    }

    private func directionButton(symbol: String, x: Int, y: Int) -> some View {
        let active = dx == x && dy == y && (x != 0 || y != 0)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.accentColor : Color(UIColor.secondarySystemBackground))
            Text(symbol)
                .font(.system(size: 13 * scale))
                .foregroundColor(active ? .white : .primary)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if dx != x || dy != y {
                        onChange(x, y)
                    }
                }
                .onEnded { _ in
                    onChange(0, 0)
                }
        )
    }
}

/// 模拟扳机滑块，输出 0 到 1。
struct TriggerSliderView: View {
    let label: String
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .frame(width: 22, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1)
            Text("\(Int(value * 100))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(maxWidth: 180)
    }
}
