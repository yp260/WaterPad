import Foundation
import CoreBluetooth

/// 一次构建出来的完整 GATT 服务集合。外围管理器持有它，用于响应读请求与定位特征。
struct HIDServiceSet {
    let hidService: CBMutableService
    let deviceInformationService: CBMutableService
    let batteryService: CBMutableService

    let inputReportCharacteristic: CBMutableCharacteristic
    let outputReportCharacteristic: CBMutableCharacteristic
    /// 运动报告特征。精简描述符模式下不注册这个特征，为 nil。
    let motionReportCharacteristic: CBMutableCharacteristic?
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
        if let motion = motionReportCharacteristic, characteristic === motion { return nil }
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
        useFullHIDUUID: Bool,
        appearance: Data,
        category: HIDDeviceCategory = .gamepad,
        deviceName: String = "WP-Pad",
        includeMotion: Bool = true
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
        // HID Control Point（0x2A4C）：主机写 Suspend / Resume，设备必须用通知回送
        // 接受响应（0x03 / 0x04）。缺了 .notify 就无法回包，主机会在建立 HID 连接
        // 阶段一直等不到响应，表现为「能搜到、连上又断」。
        let controlPoint = characteristic(
            SIGUUID.hidControlPoint,
            properties: [.writeWithoutResponse, .notify],
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
        // 精简描述符模式下整个特征都不注册，免得主机看到有报告编号却找不到对应描述。
        var motionReport: CBMutableCharacteristic?
        if includeMotion {
            let characteristic = characteristic(
                SIGUUID.hidReport,
                properties: [.read, .notify],
                permissions: [.readable, .readEncryptionRequired]
            )
            characteristic.descriptors = [
                CBMutableDescriptor(type: SIGUUID.full(SIGUUID.reportReference),
                                    value: HIDSpec.motionReportReference)
            ]
            motionReport = characteristic
        }

        var hidCharacteristics: [CBMutableCharacteristic] = [
            hidInformation, reportMap, protocolMode, controlPoint, inputReport
        ]
        if let motionReport = motionReport {
            hidCharacteristics.append(motionReport)
        }
        hidCharacteristics.append(outputReport)
        hidService.characteristics = hidCharacteristics

        // MARK: 设备信息服务
        let deviceInformationService = CBMutableService(
            type: SIGUUID.full(SIGUUID.deviceInformationService), primary: true
        )
        let pnpID = characteristic(SIGUUID.pnpID, properties: [.read], permissions: [.readable])
        let manufacturer = characteristic(SIGUUID.manufacturerName, properties: [.read], permissions: [.readable])
        let model = characteristic(SIGUUID.modelNumber, properties: [.read], permissions: [.readable])
        let firmware = characteristic(SIGUUID.firmwareRevision, properties: [.read], permissions: [.readable])
        deviceInformationService.characteristics = [pnpID, manufacturer, model, firmware]

        // MARK: Generic Access 服务（GAP Appearance 与设备名）
        // iOS 不允许 App 在广播包里写 Appearance AD Type，只能在 GATT 里补 0x1800/0x2A01。
        // 若系统拒绝注册该服务，didAdd 会记日志但不会阻断 HID 主链路与广播。
        // 0x2A00 设备名同理：主机列表优先显示整机 GAP 名称，自建 GAP 若被系统忽略则无效，
        // 但留着没有副作用，万一主机读了自建 GAP 就能显示 WP-Pad 而不是 iPhone 的名字。
        let genericAccessService = CBMutableService(
            type: SIGUUID.full(SIGUUID.genericAccessService), primary: false
        )
        let appearanceCharacteristic = characteristic(
            SIGUUID.appearance, properties: [.read], permissions: [.readable]
        )
        let gapDeviceName = characteristic(
            SIGUUID.deviceName, properties: [.read], permissions: [.readable]
        )
        genericAccessService.characteristics = [appearanceCharacteristic, gapDeviceName]

        // MARK: 电池服务
        let batteryService = CBMutableService(
            type: SIGUUID.full(SIGUUID.batteryService), primary: true
        )
        let batteryLevel = characteristic(SIGUUID.batteryLevel, properties: [.read], permissions: [.readable])
        batteryService.characteristics = [batteryLevel]

        let staticReadValues: [UInt16: Data] = [
            SIGUUID.hidInformation: HIDSpec.hidInformation,
            SIGUUID.reportMap: HIDSpec.reportDescriptorData(for: category, includeMotion: includeMotion),
            SIGUUID.protocolMode: HIDSpec.protocolModeReport,
            SIGUUID.pnpID: profile.pnpIDData(spoofing: spoofIdentity),
            SIGUUID.manufacturerName: Data("Water".utf8),
            SIGUUID.modelNumber: Data("WP-01".utf8),
            SIGUUID.firmwareRevision: Data("1.0.0".utf8),
            SIGUUID.batteryLevel: Data([0x64]),
            SIGUUID.appearance: appearance,
            SIGUUID.deviceName: Data(deviceName.utf8)
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
            allServices: [hidService, deviceInformationService, batteryService, genericAccessService],
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
