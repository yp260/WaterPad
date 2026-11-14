import Foundation

/// 手柄状态与 HID 报告字节之间的唯一转换入口。
///
/// 字段顺序必须与 HIDSpec.reportDescriptor 完全一致，任何一侧改动都要同步改写
/// 另一侧，并重新运行 tools/verify_hid.py 做一致性校验。
enum GamepadReport {

    /// 生成输入报告。HID over GATT 规范要求数据不含报告编号，编号由 0x2908 描述符指定；
    /// 但部分主机实现会期待额外的一字节编号前缀，因此保留开关。
    static func makeBytes(
        snapshot: GamepadSnapshot,
        profile: ControllerProfile,
        includeReportIDPrefix: Bool = false
    ) -> Data {
        var bytes: [UInt8] = []

        bytes.append(axis(snapshot.leftX))
        bytes.append(axis(snapshot.leftY))
        bytes.append(axis(snapshot.rightX))
        bytes.append(axis(snapshot.rightY))
        bytes.append(trigger(snapshot.leftTrigger))
        bytes.append(trigger(snapshot.rightTrigger))

        var buttonMask: UInt16 = 0
        for button in snapshot.pressed {
            if let bit = profile.buttonBits[button], bit >= 0, bit < 16 {
                buttonMask |= (1 << UInt16(bit))
            }
        }
        bytes.append(UInt8(buttonMask & 0x00FF))
        bytes.append(UInt8(buttonMask >> 8))

        // 高四位是描述符里的常量填充，必须保持为零
        bytes.append(snapshot.hat.rawValue & 0x0F)

        precondition(bytes.count == HIDSpec.inputReportLength,
                     "输入报告长度与描述符不一致")

        if includeReportIDPrefix {
            bytes.insert(HIDSpec.inputReportID, at: 0)
        }
        return Data(bytes)
    }

    /// 解析主机通过输出报告下发的力反馈。返回大马达与小马达力度，各 0 到 255。
    /// 主机可能在数据前带一字节报告编号，这里一并兼容。
    static func parseRumble(_ data: Data) -> (low: UInt8, high: UInt8)? {
        var bytes = Array(data)
        if bytes.first == HIDSpec.outputReportID {
            bytes.removeFirst()
        }
        guard bytes.count >= HIDSpec.outputReportLength else { return nil }
        return (bytes[0], bytes[1])
    }

    /// 把 -1 到 1 的摇杆量映射到 0 到 255，中位取 128。
    private static func axis(_ value: Double) -> UInt8 {
        let raw = (min(1, max(-1, value)) * 127.5) + 127.5
        return UInt8(clamping: Int(raw.rounded(.toNearestOrAwayFromZero)))
    }

    /// 把 0 到 1 的扳机量映射到 0 到 255。
    private static func trigger(_ value: Double) -> UInt8 {
        let raw = min(1, max(0, value)) * 255
        return UInt8(clamping: Int(raw.rounded(.toNearestOrAwayFromZero)))
    }
}
