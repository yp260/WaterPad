import Foundation

/// 可调节布局中的控件标识。每个标识对应手柄上的一个物理控件，
/// 其位置与大小由 PadLayout 存储，可在 App 内编辑并持久化。
enum ControlID: String, CaseIterable, Codable, Identifiable {
    case leftStick, rightStick, dpad
    case faceNorth, faceEast, faceSouth, faceWest
    case leftShoulder, leftTriggerClick, rightShoulder, rightTriggerClick
    case back, start, guide
    case leftStickClick, rightStickClick, capture

    var id: String { rawValue }

    /// scale = 1 时的基础边长（点）。用于渲染实际尺寸与编辑态高亮框。
    var baseSize: CGFloat {
        switch self {
        case .leftStick, .rightStick: return 112
        case .dpad: return 120
        case .faceNorth, .faceEast, .faceSouth, .faceWest: return 46
        default: return 34
        }
    }
}

/// 单个控件的布局：归一化位置（0...1，相对手柄区左上角）与缩放系数。
struct LayoutItem: Codable {
    var x: Double
    var y: Double
    var scale: Double

    init(x: Double, y: Double, scale: Double = 1.0) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

/// 手柄整体布局，按 ControlID 索引。可编码为 JSON 持久化。
struct PadLayout: Codable {
    var items: [String: LayoutItem]

    init(items: [ControlID: LayoutItem]) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, $0.value) })
    }

    subscript(_ id: ControlID) -> LayoutItem {
        get { items[id.rawValue] ?? LayoutItem(x: 0.5, y: 0.5) }
        set { items[id.rawValue] = newValue }
    }

    /// 默认横屏布局（归一化坐标，基于初版三簇排布推算，供真机微调）。
    static let `default`: PadLayout = {
        var m: [ControlID: LayoutItem] = [:]
        let put: (ControlID, Double, Double, Double) -> Void = { id, x, y, s in
            m[id] = LayoutItem(x: x, y: y, scale: s)
        }
        // 左簇
        put(.leftShoulder, 0.10, 0.20, 1)
        put(.leftTriggerClick, 0.20, 0.20, 1)
        put(.dpad, 0.12, 0.60, 1)
        put(.leftStick, 0.27, 0.58, 1)
        // 中簇
        put(.back, 0.45, 0.18, 1)
        put(.guide, 0.50, 0.18, 1)
        put(.start, 0.55, 0.18, 1)
        put(.leftStickClick, 0.45, 0.82, 1)
        put(.rightStickClick, 0.50, 0.82, 1)
        put(.capture, 0.55, 0.82, 1)
        // 右簇
        put(.rightShoulder, 0.78, 0.20, 1)
        put(.rightTriggerClick, 0.88, 0.20, 1)
        put(.rightStick, 0.72, 0.58, 1)
        put(.faceWest, 0.83, 0.50, 1)
        put(.faceNorth, 0.88, 0.42, 1)
        put(.faceEast, 0.93, 0.50, 1)
        put(.faceSouth, 0.88, 0.58, 1)
        return PadLayout(items: m)
    }()

    mutating func reset() {
        self = PadLayout.default
    }
}
