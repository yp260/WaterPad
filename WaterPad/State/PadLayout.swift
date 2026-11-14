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

    /// 中文名。布局编辑器的名称选择器、选中标签都用它，
    /// 保证每一个按钮都能被「按名字」挑出来调整，不必在屏幕上精准命中。
    var displayName: String {
        switch self {
        case .leftStick: return "左摇杆"
        case .rightStick: return "右摇杆"
        case .dpad: return "十字键"
        case .faceNorth: return "面键·上"
        case .faceEast: return "面键·右"
        case .faceSouth: return "面键·下"
        case .faceWest: return "面键·左"
        case .leftShoulder: return "左肩键"
        case .leftTriggerClick: return "左扳机"
        case .rightShoulder: return "右肩键"
        case .rightTriggerClick: return "右扳机"
        case .back: return "Back"
        case .start: return "Start"
        case .guide: return "Home"
        case .leftStickClick: return "L3"
        case .rightStickClick: return "R3"
        case .capture: return "Share"
        }
    }

    /// scale = 1 时的基础边长（点）。必须与实际渲染尺寸一致，
    /// 否则选中框与控件本体错位，看起来像「位置没调准」。
    var baseSize: CGFloat {
        switch self {
        case .leftStick, .rightStick: return 112
        case .dpad: return 118
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

    static let neutral = LayoutItem(x: 0.5, y: 0.5)

    /// 缩放合法范围。最大 4.0 倍：面键基础边长 46 点，放到 4 倍是 184 点，
    /// 在 iPad 上已经接近四分之一屏宽，再大就没法用手指连续按压了。
    static let scaleRange: ClosedRange<Double> = 0.4...4.0

    /// 合法范围：位置 0...1，缩放 0.4...4.0。
    mutating func clamp() {
        x = min(1, max(0, x))
        y = min(1, max(0, y))
        scale = min(LayoutItem.scaleRange.upperBound,
                    max(LayoutItem.scaleRange.lowerBound, scale))
    }
}

/// 手柄整体布局，按 ControlID 索引。可编码为 JSON 持久化。
struct PadLayout: Codable {
    var items: [String: LayoutItem]

    init(items: [ControlID: LayoutItem]) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, $0.value) })
    }

    /// 缺项回退到默认布局里的那一项，而不是落在屏幕中心的 0.5/0.5。
    subscript(_ id: ControlID) -> LayoutItem {
        get { items[id.rawValue] ?? PadLayout.default[id] }
        set { items[id.rawValue] = newValue }
    }

    /// 默认横屏布局（归一化坐标）。所有 17 个控件都必须有默认值，
    /// 否则缺项会落到屏幕中央相互叠压。
    static let `default`: PadLayout = {
        var m: [ControlID: LayoutItem] = [:]
        let put: (ControlID, Double, Double, Double) -> Void = { id, x, y, s in
            m[id] = LayoutItem(x: x, y: y, scale: s)
        }
        // 左簇
        put(.leftShoulder, 0.085, 0.13, 1)
        put(.leftTriggerClick, 0.185, 0.13, 1)
        put(.dpad, 0.115, 0.58, 1)
        put(.leftStick, 0.285, 0.58, 1)
        // 中簇
        put(.back, 0.440, 0.13, 1)
        put(.guide, 0.500, 0.13, 1)
        put(.start, 0.560, 0.13, 1)
        put(.leftStickClick, 0.440, 0.80, 1)
        put(.rightStickClick, 0.500, 0.80, 1)
        put(.capture, 0.560, 0.80, 1)
        // 右簇
        put(.rightShoulder, 0.815, 0.13, 1)
        put(.rightTriggerClick, 0.915, 0.13, 1)
        put(.rightStick, 0.715, 0.58, 1)
        put(.faceWest, 0.815, 0.48, 1)
        put(.faceNorth, 0.880, 0.40, 1)
        put(.faceEast, 0.945, 0.48, 1)
        put(.faceSouth, 0.880, 0.56, 1)
        return PadLayout(items: m)
    }()

    /// 恢复单个控件到默认位置与大小。
    mutating func reset(_ id: ControlID) {
        self[id] = PadLayout.default[id]
    }

    /// 恢复全部控件到默认布局。
    mutating func reset() {
        self = PadLayout.default
    }
}
