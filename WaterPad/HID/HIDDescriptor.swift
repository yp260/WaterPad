import Foundation
import CoreBluetooth

// MARK: - 蓝牙 SIG 标准 UUID

/// 把 16 位 SIG 编号展开为完整 128 位 UUID。
///
/// 关键背景：iOS 的 CBPeripheralManager 会拒绝以 16 位短形式添加 0x1812（HID）服务，
/// 回调给出 CBErrorDomain Code=8「The specified UUID is not allowed for this operation」。
/// 苹果技术支持确认 HID 服务由系统保留。实测以完整 128 位形式添加同一个 UUID 可以成功。
///
/// 注意区分两件事（并行项目 PocketTrackpad 已真机验证）：
/// - GATT 服务树注册：只能用完整 128 位，16 位会被 CBPeripheralManager 拒绝；
/// - 广播包里的服务编号：必须用 16 位 0x1812 / 0x180F / 0x180A，
///   用 128 位会被主机当成自定义未知服务，系统蓝牙设置里根本列不出来。
/// 该项目的鼠标类别已在 iPad 上配对成功并可用，所以 iPad 不是无条件硬墙；
/// 手柄类别能否被 iPadOS 接管仍待本工程真机验证。
///
/// 这属于利用系统检查口径的差异，不是公开支持的接口。系统更新随时可能封掉此路径，
/// 上架审核亦存在风险。代码同时保留标准 16 位探测路径，便于未来苹果放开时自动切换。
enum SIGUUID {
    static func full(_ short: UInt16) -> CBUUID {
        CBUUID(string: String(format: "0000%04X-0000-1000-8000-00805F9B34FB", short))
    }

    static func short(_ short: UInt16) -> CBUUID {
        CBUUID(string: String(format: "%04X", short))
    }

    /// 把短形式或完整 128 位形式的 CBUUID 归一化为 16 位编号，便于回调里做匹配。
    static func shortCode(_ uuid: CBUUID) -> UInt16? {
        let text = uuid.uuidString.uppercased()
        if text.count == 4 { return UInt16(text, radix: 16) }
        guard text.count == 36,
              text.hasPrefix("0000"),
              text.hasSuffix("-0000-1000-8000-00805F9B34FB") else { return nil }
        let start = text.index(text.startIndex, offsetBy: 4)
        let end = text.index(start, offsetBy: 4)
        return UInt16(text[start..<end], radix: 16)
    }

    static let hidService: UInt16          = 0x1812
    static let deviceInformationService: UInt16 = 0x180A
    static let batteryService: UInt16      = 0x180F

    static let hidInformation: UInt16      = 0x2A4A
    static let reportMap: UInt16           = 0x2A4B
    static let hidControlPoint: UInt16     = 0x2A4C
    static let hidReport: UInt16           = 0x2A4D
    static let protocolMode: UInt16        = 0x2A4E
    static let reportReference: UInt16     = 0x2908

    static let batteryLevel: UInt16        = 0x2A19
    static let manufacturerName: UInt16    = 0x2A29
    static let modelNumber: UInt16         = 0x2A24
    static let firmwareRevision: UInt16    = 0x2A26
    static let pnpID: UInt16               = 0x2A50
}

// MARK: - HID 报告描述符分析结果

struct HIDDescriptorAnalysis {
    var byteCount: Int = 0
    var itemCount: Int = 0
    var collectionDepth: Int = 0
    var negativeCollectionDepth = false
    var reportIDs: [UInt8] = []
    var inputBitsByReport: [UInt8: Int] = [:]
    var outputBitsByReport: [UInt8: Int] = [:]
    var issues: [String] = []

    var isValid: Bool { issues.isEmpty }

    var summary: String {
        let inputs = inputBitsByReport.keys.sorted()
            .map { "ID \($0): \(inputBitsByReport[$0] ?? 0) 位" }
            .joined(separator: "，")
        let outputs = outputBitsByReport.keys.sorted()
            .map { "ID \($0): \(outputBitsByReport[$0] ?? 0) 位" }
            .joined(separator: "，")
        return "描述符 \(byteCount) 字节 / \(itemCount) 项；输入报告 [\(inputs)]；输出报告 [\(outputs)]；集合深度归零：\(collectionDepth == 0)"
    }
}

// MARK: - HID 规范常量与报告描述符

enum HIDSpec {
    /// 输入报告编号：按键、摇杆、扳机、十字键
    static let inputReportID: UInt8 = 0x01
    /// 输出报告编号：主机下发的力反馈（大马达、小马达各一字节）
    static let outputReportID: UInt8 = 0x02
    /// 运动报告编号：陀螺仪三轴角速度加加速度计三轴
    static let motionReportID: UInt8 = 0x03

    /// 输入报告长度，不含报告编号。九个字段合计 72 位。
    static let inputReportLength = 9
    /// 输出报告长度，不含报告编号。
    static let outputReportLength = 2
    /// 运动报告长度，不含报告编号。六轴各 16 位，合计 96 位。
    static let motionReportLength = 12

    /// 陀螺仪满量程：度/秒。CoreMotion 的弧度/秒会换算到这里。
    static let gyroFullScale: Double = 2000
    /// 加速度计满量程：G。
    static let accelFullScale: Double = 16

    /// HID Information 特征值：bcdHID 1.11、国家码 0、可远程唤醒且正常可连接。
    static let hidInformation: Data = Data([0x11, 0x01, 0x00, 0x03])
    /// Protocol Mode 特征值：0x01 为报告协议，0x00 为启动协议。
    static let protocolModeReport: Data = Data([0x01])
    /// Report Reference 描述符：第一个字节为报告编号，第二个字节为报告类型。
    static let inputReportReference: Data = Data([0x01, 0x01])
    static let outputReportReference: Data = Data([0x02, 0x02])
    static let motionReportReference: Data = Data([0x03, 0x01])

    /// 标准游戏手柄加运动传感器报告描述符。
    ///
    /// 按键报告（编号一）字段顺序与 GamepadReport.makeBytes() 必须严格一致：
    ///   字节 0 左摇杆 X，字节 1 左摇杆 Y，字节 2 右摇杆 X，字节 3 右摇杆 Y，
    ///   字节 4 左扳机，字节 5 右扳机，字节 6 按钮低位，字节 7 按钮高位，
    ///   字节 8 低四位为 Hat Switch（1 到 8，0 表示松开），高四位为常量填充。
    /// 运动报告（编号三）字段顺序与 GamepadReport.makeMotionBytes() 一致：
    ///   字节 0 到 5 陀螺仪 X/Y/Z，字节 6 到 11 加速度计 X/Y/Z，各轴 16 位小端有符号。
    /// GATT HID 规范要求 Report 特征值的数据不含报告编号，编号由 0x2908 描述符指定。
    static let reportDescriptor: [UInt8] = [
        // 用途页：通用桌面
        0x05, 0x01,
        // 用途：游戏手柄
        0x09, 0x05,
        // 应用集合开始
        0xA1, 0x01,

        // 输入报告编号一
        0x85, 0x01,
        // 用途页：通用桌面；四个八位轴
        0x05, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x09, 0x32,
        0x09, 0x35,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x04,
        0x81, 0x02,
        // 两个八位模拟扳机
        0x05, 0x01,
        0x09, 0x33,
        0x09, 0x34,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x02,
        0x81, 0x02,
        // 十六个一位按钮
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x10,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x10,
        0x81, 0x02,
        // 四位 Hat Switch，取值一到八，零为空位态
        0x05, 0x01,
        0x09, 0x39,
        0x15, 0x01,
        0x25, 0x08,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x65, 0x14,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x42,
        // 四位常量填充，凑满整字节
        0x65, 0x00,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x01,

        // 运动报告编号三：陀螺仪三轴角速度，满量程 ±2000 度/秒。
        // 用法页 0x20（传感器）、Gyroscope 3D 0x076、角速度轴 0x0457 到 0x0459，
        // 编号来自 Linux hid-sensor-ids.h 与 USB HID 用法表传感器页，是跨平台标准编号。
        // 物理量程必须显式声明：HID 全局项会跨报告延续，不覆盖会沿用十字键的 0 到 315。
        0x85, 0x03,
        0x05, 0x20,
        0x09, 0x76,
        0xA1, 0x02,
        0x0A, 0x57, 0x04,
        0x0A, 0x58, 0x04,
        0x0A, 0x59, 0x04,
        0x16, 0x00, 0x80,
        0x26, 0xFF, 0x7F,
        0x36, 0x30, 0xF8,
        0x46, 0xD0, 0x07,
        0x55, 0x00,
        0x65, 0x15,
        0x75, 0x10,
        0x95, 0x03,
        0x81, 0x02,
        0xC0,
        // 加速度计三轴，满量程 ±16G
        0x05, 0x20,
        0x09, 0x73,
        0xA1, 0x02,
        0x0A, 0x53, 0x04,
        0x0A, 0x54, 0x04,
        0x0A, 0x55, 0x04,
        0x16, 0x00, 0x80,
        0x26, 0xFF, 0x7F,
        0x36, 0xF0, 0xFF,
        0x46, 0x10, 0x00,
        0x55, 0x00,
        0x65, 0x1A,
        0x75, 0x10,
        0x95, 0x03,
        0x81, 0x02,
        0xC0,

        // 输出报告编号二：厂商自定义两个八位力度字段
        0x85, 0x02,
        0x06, 0x00, 0xFF,
        0x09, 0x01,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x02,
        0x91, 0x02,

        // 应用集合结束
        0xC0
    ]

    static var reportDescriptorData: Data { Data(reportDescriptor) }

    /// 启动自检：把描述符按 HID 短项格式解析一遍，核对报告编号与位宽。
    /// 结果写入应用内日志，避免描述符与打包逻辑不同步时静默出错。
    static func analyzeDescriptor(_ bytes: [UInt8] = HIDSpec.reportDescriptor) -> HIDDescriptorAnalysis {
        var result = HIDDescriptorAnalysis(byteCount: bytes.count)
        var index = 0
        var reportSize = 0
        var reportCount = 0
        var currentReportID: UInt8 = 0

        while index < bytes.count {
            let header = bytes[index]
            index += 1
            let rawSize = Int(header & 0x03)
            let itemSize = rawSize == 3 ? 4 : rawSize
            let itemType = Int((header >> 2) & 0x03)
            let itemTag = Int((header >> 4) & 0x0F)

            guard index + itemSize <= bytes.count else {
                result.issues.append("第 \(result.itemCount + 1) 项数据被截断")
                break
            }
            let payload = Array(bytes[index..<(index + itemSize)])
            index += itemSize
            result.itemCount += 1

            let unsignedValue: Int = payload.enumerated().reduce(0) { acc, pair in
                acc + (Int(pair.element) << (8 * pair.offset))
            }

            switch itemType {
            case 0: // Main
                switch itemTag {
                case 0x08: // Input
                    result.inputBitsByReport[currentReportID, default: 0] += reportSize * reportCount
                case 0x09: // Output
                    result.outputBitsByReport[currentReportID, default: 0] += reportSize * reportCount
                case 0x0A: // Collection
                    result.collectionDepth += 1
                case 0x0C: // End Collection
                    result.collectionDepth -= 1
                    if result.collectionDepth < 0 { result.negativeCollectionDepth = true }
                default:
                    break
                }
            case 1: // Global
                switch itemTag {
                case 0x07: reportSize = unsignedValue
                case 0x09: reportCount = unsignedValue
                case 0x08:
                    currentReportID = UInt8(truncatingIfNeeded: unsignedValue)
                    if !result.reportIDs.contains(currentReportID) {
                        result.reportIDs.append(currentReportID)
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        if result.collectionDepth != 0 {
            result.issues.append("应用集合未闭合，剩余深度 \(result.collectionDepth)")
        }
        if result.negativeCollectionDepth {
            result.issues.append("出现多余的集合结束项")
        }
        if Set(result.reportIDs) != Set([inputReportID, outputReportID, motionReportID]) {
            result.issues.append("报告编号集合与预期不符：\(result.reportIDs)")
        }
        let expectedInputBits = inputReportLength * 8
        if result.inputBitsByReport[inputReportID] != expectedInputBits {
            result.issues.append("输入报告一为 \(result.inputBitsByReport[inputReportID] ?? 0) 位，预期 \(expectedInputBits) 位")
        }
        let expectedOutputBits = outputReportLength * 8
        if result.outputBitsByReport[outputReportID] != expectedOutputBits {
            result.issues.append("输出报告二为 \(result.outputBitsByReport[outputReportID] ?? 0) 位，预期 \(expectedOutputBits) 位")
        }
        let expectedMotionBits = motionReportLength * 8
        if result.inputBitsByReport[motionReportID] != expectedMotionBits {
            result.issues.append("运动报告三为 \(result.inputBitsByReport[motionReportID] ?? 0) 位，预期 \(expectedMotionBits) 位")
        }
        return result
    }
}
