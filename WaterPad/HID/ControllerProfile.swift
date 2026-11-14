import Foundation

// MARK: - 逻辑按键与十字键

/// 逻辑按键按「屏幕上的物理位置」命名，与具体平台标签解耦。
/// 切换手柄档位时只改变标签与 HID 报告中的位序，不改变手指位置。
enum PadButton: Int, CaseIterable, Hashable {
    case south = 0
    case east
    case west
    case north
    case leftShoulder
    case rightShoulder
    case leftTriggerClick
    case rightTriggerClick
    case back
    case start
    case guide
    case leftStick
    case rightStick
    case capture
}

/// HID Hat Switch 取值。0 为空位态（Null State），1 到 8 顺时针从正上开始，每 45 度一档。
enum HatDirection: UInt8 {
    case released = 0
    case up = 1
    case upRight = 2
    case right = 3
    case downRight = 4
    case down = 5
    case downLeft = 6
    case left = 7
    case upLeft = 8

    static func from(dx: Int, dy: Int) -> HatDirection {
        switch (dx, dy) {
        case (0, -1): return .up
        case (1, -1): return .upRight
        case (1, 0): return .right
        case (1, 1): return .downRight
        case (0, 1): return .down
        case (-1, 1): return .downLeft
        case (-1, 0): return .left
        case (-1, -1): return .upLeft
        default: return .released
        }
    }
}

// MARK: - 手柄档位

/// 四种手柄档位。
///
/// 重要边界：在这里切换厂商编号与设备名称，只能影响主机在设备列表里的展示，
/// 以及部分按名称做判断的应用。**不会**让 Windows 把低功耗蓝牙 HID 设备当成
/// XInput 的 Xbox 手柄，也不会通过 PS4 或 Switch 主机的认证握手。
/// 真正的 XInput 身份需要电脑端虚拟总线驱动，那是另一条技术链路。
struct ControllerProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let caveat: String
    let vendorID: UInt16
    let productID: UInt16
    let spoofedName: String
    let faceLabels: [PadButton: String]
    let buttonBits: [PadButton: Int]

    static let generic = ControllerProfile(
        id: "generic",
        displayName: "通用手柄",
        caveat: "厂商编号留空，主机按标准 HID 类驱动处理，兼容性最稳妥",
        vendorID: 0x0000,
        productID: 0x0000,
        spoofedName: "WaterPad",
        faceLabels: [.south: "1", .east: "2", .west: "3", .north: "4"],
        buttonBits: [
            .south: 0, .east: 1, .west: 2, .north: 3,
            .leftShoulder: 4, .rightShoulder: 5,
            .leftTriggerClick: 6, .rightTriggerClick: 7,
            .back: 8, .start: 9, .guide: 10,
            .leftStick: 11, .rightStick: 12, .capture: 13
        ]
    )

    static let xbox = ControllerProfile(
        id: "xbox",
        displayName: "Xbox 风格",
        caveat: "VID 045E / PID 028E 为 Xbox 360 手柄。蓝牙 HID 设备仍走 HID 类驱动，不是 XInput 设备",
        vendorID: 0x045E,
        productID: 0x028E,
        spoofedName: "Xbox Wireless Controller",
        faceLabels: [.south: "A", .east: "B", .west: "X", .north: "Y"],
        buttonBits: [
            .south: 0, .east: 1, .west: 2, .north: 3,
            .leftShoulder: 4, .rightShoulder: 5,
            .back: 6, .start: 7, .guide: 8,
            .leftStick: 9, .rightStick: 10,
            .leftTriggerClick: 11, .rightTriggerClick: 12, .capture: 13
        ]
    )

    static let dualShock4 = ControllerProfile(
        id: "dualShock4",
        displayName: "DualShock 4 风格",
        caveat: "VID 054C / PID 05C4 为 DualShock 4 一代。PS4 主机有 RSA 挑战应答，此方式无法连真主机",
        vendorID: 0x054C,
        productID: 0x05C4,
        spoofedName: "Wireless Controller",
        faceLabels: [.south: "×", .east: "○", .west: "□", .north: "△"],
        buttonBits: [
            .west: 0, .south: 1, .east: 2, .north: 3,
            .leftShoulder: 4, .rightShoulder: 5,
            .leftTriggerClick: 6, .rightTriggerClick: 7,
            .back: 8, .start: 9, .guide: 10,
            .leftStick: 11, .rightStick: 12, .capture: 13
        ]
    )

    static let switchPro = ControllerProfile(
        id: "switchPro",
        displayName: "Switch Pro 风格",
        caveat: "VID 057E / PID 2009 为 Switch Pro 手柄。Switch 主机有专有握手，此方式无法连真主机",
        vendorID: 0x057E,
        productID: 0x2009,
        spoofedName: "Pro Controller",
        faceLabels: [.south: "B", .east: "A", .west: "Y", .north: "X"],
        buttonBits: [
            .west: 0, .south: 1, .east: 2, .north: 3,
            .leftShoulder: 4, .rightShoulder: 5,
            .leftTriggerClick: 6, .rightTriggerClick: 7,
            .back: 8, .start: 9,
            .rightStick: 10, .leftStick: 11,
            .guide: 12, .capture: 13
        ]
    )

    static let all: [ControllerProfile] = [.generic, .xbox, .dualShock4, .switchPro]

    static func withID(_ id: String) -> ControllerProfile {
        all.first { $0.id == id } ?? .generic
    }

    func label(for button: PadButton) -> String {
        faceLabels[button] ?? button.defaultLabel
    }

    /// PnP ID 特征值：厂商来源 0x02 表示 USB-IF 编号，随后是小端的 VID、PID、产品版本。
    /// 伪装开关关闭时写入 0，避免主机误加载真实厂商驱动。
    func pnpIDData(spoofing: Bool) -> Data {
        let vendor = spoofing ? vendorID : 0x0000
        let product = spoofing ? productID : 0x0000
        return Data([
            0x02,
            UInt8(vendor & 0x00FF), UInt8(vendor >> 8),
            UInt8(product & 0x00FF), UInt8(product >> 8),
            0x00, 0x01
        ])
    }
}

extension PadButton {
    var defaultLabel: String {
        switch self {
        case .south: return "1"
        case .east: return "2"
        case .west: return "3"
        case .north: return "4"
        case .leftShoulder: return "LB"
        case .rightShoulder: return "RB"
        case .leftTriggerClick: return "LT"
        case .rightTriggerClick: return "RT"
        case .back: return "Back"
        case .start: return "Start"
        case .guide: return "Home"
        case .leftStick: return "L3"
        case .rightStick: return "R3"
        case .capture: return "Share"
        }
    }
}
