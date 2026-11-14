import Foundation
import CoreBluetooth

/// 一次构建出来的完整 GATT 服务集合。外围管理器持有它，用于响应读请求与定位特征。
struct HIDServiceSet {
    let hidService: CBMutableService
    let deviceInformationService: CBMutableService
    let batteryService: CBMutableService

    let inputReportCharacteristic: CBMutableCharacteristic
    let outputReportCharacteristic: CBMutableCharacteristic
    let motionReportCharacteristic: CBMutableCharacteristic
    let protocolModeCharacteristic: CBMutableCharacteristic
    let hidControlPointCharacteristic: CBMutableCharacteristic

    let allServices: [CBMutableService]
    let advertisedUUIDs: [CBUUID]
    let uuidFormatDescription: String

    /// 键为 16 位特征编号。所有特征的 value 都设为 nil，读请求统一在外围管理器里应答，
    /// 这样能记录主机到底读了哪些内容，也避免静态值与动态值混用导致的口径不一致。
    let staticReadValues: [UInt16: Data]

    func readValue(for characteristic: CBCharacteristic) -> Data? {
        if characteristic === inputReportCharacteristic { return nil }
        if characteristic === motionReportCharacteristic { return nil }
        if characteristic === outputReportCharacteristic { return Data([0x00, 0x00]) }
        guard let code = SIGUUID.shortCode(characteristic.uuid) else { return nil }
        return staticReadValues[code]
    }

    func isInputReport(_ characteristic: CBCharacteristic) -> Bool {
        if characteristic === outputReportCharacteristic { return false }
        guard let code = SIGUUID.shortCode(characteristic.uuid) else { return false }
        return code == SIGUUID.hidReport
    }
}

enum HIDServiceBuilder {
    /// useFullHIDUUID 为 true 时使用完整 128 位 HID 服务编号，这是当前实测唯一可添加的形式。
    /// 为 false 时使用标准 16 位，预计会被系统拒绝，外围管理器会自动回退。
    static func build(
        profile: ControllerProfile,
        spoofIdentity: Bool,
        useFullHIDUUID: Bool
    ) -> HIDServiceSet {
        let hidServiceUUID = useFullHIDUUID
            ? SIGUUID.full(SIGUUID.hidService)
            : SIGUUID.short(SIGUUID.hidService)

        // MARK: HID 服务
        let hidService = CBMutableService(type: hidServiceUUID, primary: true)

        let hidInformation = characteristic(
            SIGUUID.hidInformation,
            properties: [.read],
            permissions: [.readEncryptionRequired]
        )
        let reportMap = characteristic(
            SIGUUID.reportMap,
            properties: [.read],
            permissions: [.readEncryptionRequired]
        )
        let protocolMode = characteristic(
            SIGUUID.protocolMode,
            properties: [.read, .writeWithoutResponse],
            permissions: [.readable, .writeable]
        )
        let controlPoint = characteristic(
            SIGUUID.hidControlPoint,
            properties: [.writeWithoutResponse],
            permissions: [.writeable]
        )

        let inputReport = characteristic(
            SIGUUID.hidReport,
            properties: [.read, .notify],
            permissions: [.readable, .readEncryptionRequired]
        )
        inputReport.descriptors = [
            CBMutableDescriptor(type: SIGUUID.full(SIGUUID.reportReference),
                                value: HIDSpec.inputReportReference)
        ]

        let outputReport = characteristic(
            SIGUUID.hidReport,
            properties: [.read, .write, .writeWithoutResponse],
            permissions: [.readable, .writeable]
        )
        outputReport.descriptors = [
            CBMutableDescriptor(type: SIGUUID.full(SIGUUID.reportReference),
                                value: HIDSpec.outputReportReference)
        ]

        // 运动报告特征：陀螺仪三轴加加速度计三轴。主机不认识也能正常用手柄，
        // 该特征只在主机主动订阅后才开始发送。
        let motionReport = characteristic(
            SIGUUID.hidReport,
            properties: [.read, .notify],
            permissions: [.readable, .readEncryptionRequired]
        )
        motionReport.descriptors = [
            CBMutableDescriptor(type: SIGUUID.full(SIGUUID.reportReference),
                                value: HIDSpec.motionReportReference)
        ]

        hidService.characteristics = [
            hidInformation, reportMap, protocolMode, controlPoint,
            inputReport, motionReport, outputReport
        ]

        // MARK: 设备信息服务
        let deviceInformationService = CBMutableService(
            type: SIGUUID.full(SIGUUID.deviceInformationService), primary: true
        )
        let pnpID = characteristic(SIGUUID.pnpID, properties: [.read], permissions: [.readable])
        let manufacturer = characteristic(SIGUUID.manufacturerName, properties: [.read], permissions: [.readable])
        let model = characteristic(SIGUUID.modelNumber, properties: [.read], permissions: [.readable])
        let firmware = characteristic(SIGUUID.firmwareRevision, properties: [.read], permissions: [.readable])
        deviceInformationService.characteristics = [pnpID, manufacturer, model, firmware]

        // MARK: 电池服务
        let batteryService = CBMutableService(
            type: SIGUUID.full(SIGUUID.batteryService), primary: true
        )
        let batteryLevel = characteristic(SIGUUID.batteryLevel, properties: [.read], permissions: [.readable])
        batteryService.characteristics = [batteryLevel]

        let staticReadValues: [UInt16: Data] = [
            SIGUUID.hidInformation: HIDSpec.hidInformation,
            SIGUUID.reportMap: HIDSpec.reportDescriptorData,
            SIGUUID.protocolMode: HIDSpec.protocolModeReport,
            SIGUUID.pnpID: profile.pnpIDData(spoofing: spoofIdentity),
            SIGUUID.manufacturerName: Data("Water".utf8),
            SIGUUID.modelNumber: Data("WP-01".utf8),
            SIGUUID.firmwareRevision: Data("1.0.0".utf8),
            SIGUUID.batteryLevel: Data([0x64])
        ]

        return HIDServiceSet(
            hidService: hidService,
            deviceInformationService: deviceInformationService,
            batteryService: batteryService,
            inputReportCharacteristic: inputReport,
            outputReportCharacteristic: outputReport,
            motionReportCharacteristic: motionReport,
            protocolModeCharacteristic: protocolMode,
            hidControlPointCharacteristic: controlPoint,
            allServices: [hidService, deviceInformationService, batteryService],
            // 广播与 GATT 注册是两回事，必须分开处理：
            // - CBPeripheralManager.add() 会拒绝 16 位 0x1812（CBError Code 8），所以服务树用完整 128 位；
            // - 广播包必须放 16 位 SIG 编号，主机才会把设备列进系统蓝牙设置。
            //   128 位广播会被主机当成「自定义未知服务」屏蔽，且单条占 18 字节，
            //   极易挤进 31 字节广播包的 overflow 区，导致 Windows / iPad 都搜不到。
            // 此结论来自并行项目 PocketTrackpad 的真机验证（v0.0.3 修复后配对成功）。
            advertisedUUIDs: [
                SIGUUID.short(SIGUUID.hidService),
                SIGUUID.short(SIGUUID.deviceInformationService),
                SIGUUID.short(SIGUUID.batteryService)
            ],
            uuidFormatDescription: useFullHIDUUID ? "完整 128 位" : "标准 16 位",
            staticReadValues: staticReadValues
        )
    }

    private static func characteristic(
        _ short: UInt16,
        properties: CBCharacteristicProperties,
        permissions: CBAttributePermissions
    ) -> CBMutableCharacteristic {
        CBMutableCharacteristic(
            type: SIGUUID.full(short),
            properties: properties,
            value: nil,
            permissions: permissions
        )
    }
}
