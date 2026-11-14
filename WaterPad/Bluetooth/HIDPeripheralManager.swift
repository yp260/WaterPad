import Foundation
import CoreBluetooth

/// iOS 侧的蓝牙低功耗外设。广播 HID over GATT 服务，把虚拟手柄状态发给主机。
///
/// 已知边界（均来自实测与苹果开发者论坛）：
/// 1. 标准 16 位 0x1812 服务会被 CBPeripheralManager 拒绝（CBError Code 8），
///    GATT 服务树必须用完整 128 位形式；代码保留 16 位探测开关，被拒时自动回退。
/// 2. 广播包必须用 16 位 SIG 编号（1812 / 180F / 180A），否则主机不会把它列进蓝牙设置。
///    广播与注册是两条独立路径，这一点由并行项目 PocketTrackpad 真机验证确认。
/// 3. iPadOS 是否接管「手柄」这一 HID 类别尚未真机验证；同一条链路上的「鼠标」类别
///    已在 iPad 上配对成功，不能再断言 iPad 是系统级硬墙。日志措辞按未验证处理。
/// 4. 应用退到后台或锁屏后广播会受限，本应用必须保持前台。
final class HIDPeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    @Published private(set) var bluetoothStateText = "未启动"
    @Published private(set) var isAdvertising = false
    @Published private(set) var connectedCount = 0
    @Published private(set) var activeUUIDFormat = "完整 128 位"
    @Published private(set) var lastErrorMessage: String?

    /// 主机通过输出报告下发力反馈时回调，参数是大马达与小马达力度（0 到 255）。
    var onRumble: ((UInt8, UInt8) -> Void)?

    private let settings: SettingsStore
    private let log: LogStore

    private let bleQueue = DispatchQueue(label: "com.water.waterpad.ble", qos: .userInteractive)
    private var manager: CBPeripheralManager?
    private var serviceSet: HIDServiceSet?

    private var usingFullUUID = true
    private var didFallback = false
    private var pendingAddCount = 0
    private var completedAddCount = 0

    /// 用数组加对象身份判断，避免依赖 CBCentral 的哈希实现。
    private var subscribedCentrals: [CBCentral] = []

    private let reportLock = NSLock()
    private var latestReport: Data?
    private var sendTimer: DispatchSourceTimer?
    private var droppedReportCount = 0
    private var lastDroppedLogTime: Date = .distantPast

    private var suspendedByHost = false
    private var protocolModeValue: UInt8 = 0x01

    init(settings: SettingsStore, log: LogStore) {
        self.settings = settings
        self.log = log
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard manager == nil else {
            // 管理器还在但服务树为空（例如蓝牙刚从关闭状态恢复），补一次重建，
            // 避免出现「点开始广播没有任何反应」。
            resumeIfNeeded()
            return
        }
        manager = CBPeripheralManager(
            delegate: self,
            queue: bleQueue,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
        )
        log.add("蓝牙外设管理器初始化")
    }

    /// 停止广播并主动断开当前主机。CBPeripheralManager 没有公开的 disconnect(central:)，
    /// stopAdvertising() 不会拆掉已建立的连接，必须释放整个 manager 实例。
    func stop() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.sendTimer?.cancel()
            self.sendTimer = nil
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager?.delegate = nil
            self.manager = nil
            self.serviceSet = nil
            self.subscribedCentrals.removeAll()
            self.suspendedByHost = false
            self.reportLock.lock()
            self.latestReport = nil
            self.reportLock.unlock()
            DispatchQueue.main.async {
                self.isAdvertising = false
                self.connectedCount = 0
                self.bluetoothStateText = "未启动"
            }
            self.log.add("已停止广播并断开当前主机；点「开始广播」会重建全部服务")
        }
    }

    /// 设置里影响 GATT 结构的项目变化时调用。参数在主线程捕获后送入蓝牙队列，
    /// 避免蓝牙队列直接读取被界面修改的设置对象。
    func reconfigure() {
        let profile = settings.profile
        let spoof = settings.spoofIdentity
        let attemptShort = settings.attemptStandardUUID
        let includePrefix = settings.includeReportIDPrefix
        let name = settings.advertisedName
        let interval = settings.reportInterval
        bleQueue.async { [weak self] in
            guard let self, self.manager?.state == .poweredOn else { return }
            self.rebuild(profile: profile, spoof: spoof, attemptShort: attemptShort,
                         includePrefix: includePrefix, name: name, interval: interval)
        }
    }

    /// 仅调整发送频率，不重建 GATT 服务。
    func applyFrequency() {
        let interval = settings.reportInterval
        bleQueue.async { [weak self] in
            self?.restartSendLoop(interval: interval)
        }
    }

    /// 仅同步报告编号前缀开关，避免为了一个字节的打包差异让主机断开重连。
    func applyPacketFormat() {
        let includePrefix = settings.includeReportIDPrefix
        bleQueue.async { [weak self] in
            self?.currentIncludeReportIDPrefix = includePrefix
        }
    }

    func resumeIfNeeded() {
        bleQueue.async { [weak self] in
            guard let self, self.manager?.state == .poweredOn else { return }
            if self.serviceSet == nil {
                DispatchQueue.main.async { self.reconfigure() }
            }
        }
    }

    /// 由界面在主线程按固定节奏调用，生成输入报告后交给蓝牙队列发送。
    func submit(snapshot: GamepadSnapshot, profile: ControllerProfile, includeReportIDPrefix: Bool) {
        let data = GamepadReport.makeBytes(
            snapshot: snapshot,
            profile: profile,
            includeReportIDPrefix: includeReportIDPrefix
        )
        reportLock.lock()
        latestReport = data
        reportLock.unlock()
    }

    // MARK: - 服务构建与广播

    private func rebuild(profile: ControllerProfile,
                         spoof: Bool,
                         attemptShort: Bool,
                         includePrefix: Bool,
                         name: String,
                         interval: TimeInterval) {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        subscribedCentrals.removeAll()
        suspendedByHost = false
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.connectedCount = 0
        }

        didFallback = false
        usingFullUUID = !attemptShort
        let set = HIDServiceBuilder.build(
            profile: profile,
            spoofIdentity: spoof,
            useFullHIDUUID: usingFullUUID
        )
        serviceSet = set

        DispatchQueue.main.async { self.activeUUIDFormat = set.uuidFormatDescription }

        let analysis = HIDSpec.analyzeDescriptor()
        if analysis.isValid {
            log.add("描述符自检通过：" + analysis.summary)
        } else {
            for issue in analysis.issues { log.add(issue, level: .error) }
        }

        pendingAddCount = set.allServices.count
        completedAddCount = 0
        currentAdvertisedName = name
        currentInterval = interval
        currentProfile = profile
        currentSpoofIdentity = spoof
        currentIncludeReportIDPrefix = includePrefix
        log.add("添加 \(pendingAddCount) 个 GATT 服务，HID 服务编号形式：\(set.uuidFormatDescription)")
        for service in set.allServices { manager?.add(service) }
    }

    private var currentAdvertisedName = "WaterPad"
    private var currentInterval: TimeInterval = 1.0 / 60
    /// 当前生效配置的队列内副本，回调里不直接读取被界面修改的设置对象。
    private var currentProfile: ControllerProfile = .generic
    private var currentSpoofIdentity = false
    private var currentIncludeReportIDPrefix = false
    /// 16 位广播被系统拒绝时才切到 true，日志会明确提示主机大概率发现不了。
    private var advertisingUsesFullUUIDs = false

    private func startAdvertising(fullUUIDs: Bool = false) {
        guard let set = serviceSet, let manager else { return }
        advertisingUsesFullUUIDs = fullUUIDs
        let uuids: [CBUUID] = fullUUIDs
            ? [SIGUUID.full(SIGUUID.hidService),
               SIGUUID.full(SIGUUID.deviceInformationService),
               SIGUUID.full(SIGUUID.batteryService)]
            : set.advertisedUUIDs
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: currentAdvertisedName,
            CBAdvertisementDataServiceUUIDsKey: uuids
        ]
        log.add("请求广播，设备名称：\(currentAdvertisedName)，服务编号：\(fullUUIDs ? "完整 128 位（回退）" : "标准 16 位")")
        manager.startAdvertising(advertisement)
        restartSendLoop(interval: currentInterval)
    }

    private func restartSendLoop(interval: TimeInterval) {
        sendTimer?.cancel()
        currentInterval = interval
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sendLatestReport() }
        sendTimer = timer
        timer.resume()
    }

    private func sendLatestReport() {
        guard let set = serviceSet,
              !subscribedCentrals.isEmpty,
              !suspendedByHost,
              let manager else { return }

        reportLock.lock()
        let data = latestReport
        reportLock.unlock()
        guard let data else { return }

        let sent = manager.updateValue(
            data,
            for: set.inputReportCharacteristic,
            onSubscribedCentrals: subscribedCentrals
        )
        if !sent {
            droppedReportCount += 1
            let now = Date()
            if now.timeIntervalSince(lastDroppedLogTime) > 3 {
                lastDroppedLogTime = now
                log.add("发送队列已满，累计丢弃 \(droppedReportCount) 帧，可下调发送频率", level: .warn)
            }
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let text: String
        switch peripheral.state {
        case .unknown: text = "状态未知"
        case .resetting: text = "正在重置"
        case .unsupported: text = "设备不支持蓝牙外设模式"
        case .unauthorized: text = "未获蓝牙权限"
        case .poweredOff: text = "蓝牙已关闭"
        case .poweredOn: text = "蓝牙已开启"
        @unknown default: text = "未知状态"
        }
        DispatchQueue.main.async { self.bluetoothStateText = text }
        log.add(text, level: peripheral.state == .poweredOn ? .info : .warn)

        if peripheral.state == .poweredOn {
            let profile = settings.profile
            let spoof = settings.spoofIdentity
            let attemptShort = settings.attemptStandardUUID
            let includePrefix = settings.includeReportIDPrefix
            let name = settings.advertisedName
            let interval = settings.reportInterval
            rebuild(profile: profile, spoof: spoof, attemptShort: attemptShort,
                    includePrefix: includePrefix, name: name, interval: interval)
        } else {
            DispatchQueue.main.async { self.isAdvertising = false }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        guard let set = serviceSet,
              set.allServices.contains(where: { $0 === service }) else { return }

        let code = SIGUUID.shortCode(service.uuid) ?? 0
        if let error {
            log.add(String(format: "服务 0x%04X 添加失败：%@", code, error.localizedDescription),
                    level: .error)
            if code == SIGUUID.hidService && !usingFullUUID && !didFallback {
                didFallback = true
                log.add("标准 16 位 HID 服务被系统拒绝，自动回退到完整 128 位", level: .warn)
                DispatchQueue.main.async {
                    self.lastErrorMessage = "标准 16 位被拒，已自动回退"
                }
                rebuild(profile: currentProfile,
                        spoof: currentSpoofIdentity,
                        attemptShort: false,
                        includePrefix: currentIncludeReportIDPrefix,
                        name: currentAdvertisedName,
                        interval: currentInterval)
                return
            }
            if code == SIGUUID.hidService {
                DispatchQueue.main.async {
                    self.lastErrorMessage = "HID 服务被系统拒绝，当前系统版本可能已封锁此路径"
                }
            }
        } else {
            log.add(String(format: "服务 0x%04X 添加成功", code))
        }

        completedAddCount += 1
        if completedAddCount >= pendingAddCount {
            startAdvertising()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                              error: Error?) {
        if let error {
            // 某些 iOS 版本可能拒绝广播 16 位 SIG 编号，此时退回 128 位保证广播仍在，
            // 但要明确告诉用户主机大概率不会把设备列进蓝牙设置。
            if !advertisingUsesFullUUIDs {
                log.add("16 位标准广播被拒：\(error.localizedDescription)，改用完整 128 位重试", level: .warn)
                startAdvertising(fullUUIDs: true)
                return
            }
            log.add("广播失败：\(error.localizedDescription)", level: .error)
            DispatchQueue.main.async {
                self.isAdvertising = false
                self.lastErrorMessage = error.localizedDescription
            }
        } else {
            DispatchQueue.main.async {
                self.isAdvertising = true
                self.lastErrorMessage = nil
            }
            log.add("广播已开启，请在主机的系统蓝牙设置里搜索并配对")
            if advertisingUsesFullUUIDs {
                log.add("当前为 128 位回退广播，多数主机不会把设备列进蓝牙列表", level: .warn)
            }
            log.add("主机显示的名称可能是 iPhone 整机名称（GAP Device Name），不是广播名；可在主机侧重命名", level: .info)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard let set = serviceSet, set.isInputReport(characteristic) else { return }
        if !subscribedCentrals.contains(where: { $0 === central }) {
            subscribedCentrals.append(central)
        }
        let count = subscribedCentrals.count
        DispatchQueue.main.async { self.connectedCount = count }
        log.add("主机订阅输入报告，当前连接数 \(count)")
        sendLatestReport()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let set = serviceSet, set.isInputReport(characteristic) else { return }
        subscribedCentrals.removeAll { $0 === central }
        let count = subscribedCentrals.count
        DispatchQueue.main.async { self.connectedCount = count }
        log.add("主机取消订阅，当前连接数 \(count)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard let set = serviceSet else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }

        let value: Data?
        if request.characteristic === set.inputReportCharacteristic {
            reportLock.lock()
            let cached = latestReport
            reportLock.unlock()
            value = cached ?? GamepadReport.makeBytes(
                snapshot: .neutral,
                profile: currentProfile,
                includeReportIDPrefix: currentIncludeReportIDPrefix
            )
        } else {
            value = set.readValue(for: request.characteristic)
        }

        guard let data = value else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let offset = max(0, request.offset)
        request.value = offset >= data.count ? Data() : data.subdata(in: offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        guard let set = serviceSet, let first = requests.first else { return }

        for request in requests {
            let bytes = Array(request.value ?? Data())
            if request.characteristic === set.outputReportCharacteristic {
                if let rumble = GamepadReport.parseRumble(Data(bytes)) {
                    log.add("收到力反馈：大马达 \(rumble.low)，小马达 \(rumble.high)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onRumble?(rumble.low, rumble.high)
                    }
                }
            } else if request.characteristic === set.hidControlPointCharacteristic {
                let command = bytes.first ?? 0x01
                suspendedByHost = command == 0x00
                log.add("主机控制点指令：\(suspendedByHost ? "挂起" : "退出挂起")")
            } else if request.characteristic === set.protocolModeCharacteristic {
                protocolModeValue = bytes.first ?? 0x01
                log.add("主机设置协议模式：\(protocolModeValue == 0 ? "启动协议" : "报告协议")")
            }
        }

        if first.characteristic.properties.contains(.write) {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
