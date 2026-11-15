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
    /// 主机连接诊断：主机是否读过报告描述符、是否写过控制点、是否订阅了输入报告。
    /// 这三项决定 iPad 到底卡在哪一步排查。
    @Published private(set) var hostReadReportMap = false
    @Published private(set) var hostControlPointText = "未收到控制点指令"
    @Published private(set) var hostSubscribedInput = false
    @Published private(set) var hostConnectionText = "尚无主机连接"

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
    /// 按键报告与运动报告是两个独立特征，主机可能只订阅其中一个。
    private var subscribedCentrals: [CBCentral] = []
    private var motionCentrals: [CBCentral] = []
    /// 已建立链路的主机。连接数按这个算，而不是按订阅数——
    /// 主机连上但还没订阅报告时，订阅数是零，界面会误报「没连上」。
    private var connectedCentrals: [CBCentral] = []

    private let reportLock = NSLock()
    private var latestReport: Data?
    private var latestMotionReport: Data?
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
            self.motionCentrals.removeAll()
            self.connectedCentrals.removeAll()
            self.suspendedByHost = false
            self.reportLock.lock()
            self.latestReport = nil
            self.latestMotionReport = nil
            self.reportLock.unlock()
            DispatchQueue.main.async {
                self.isAdvertising = false
                self.connectedCount = 0
                self.bluetoothStateText = "未启动"
                self.hostConnectionText = "尚无主机连接"
                self.hostControlPointText = "未收到控制点指令"
                self.hostSubscribedInput = false
                self.hostReadReportMap = false
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
        let appearance = settings.appearance.data
        let hidOnly = settings.advertiseHIDOnly
        let category = settings.hidCategory
        let includeMotion = !settings.compactHIDDescriptor
        bleQueue.async { [weak self] in
            guard let self, self.manager?.state == .poweredOn else { return }
            self.rebuild(profile: profile, spoof: spoof, attemptShort: attemptShort,
                         includePrefix: includePrefix, name: name, interval: interval,
                         appearance: appearance, hidOnly: hidOnly, category: category,
                         includeMotion: includeMotion)
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
    /// 运动报告由同一份快照打包，字段顺序与描述符报告三一致。
    func submit(snapshot: GamepadSnapshot, profile: ControllerProfile, includeReportIDPrefix: Bool) {
        let data = GamepadReport.makeBytes(
            snapshot: snapshot,
            profile: profile,
            includeReportIDPrefix: includeReportIDPrefix
        )
        let motionData = GamepadReport.makeMotionBytes(
            snapshot: snapshot,
            includeReportIDPrefix: includeReportIDPrefix
        )
        reportLock.lock()
        latestReport = data
        latestMotionReport = motionData
        reportLock.unlock()
    }

    // MARK: - 服务构建与广播

    private func rebuild(profile: ControllerProfile,
                         spoof: Bool,
                         attemptShort: Bool,
                         includePrefix: Bool,
                         name: String,
                         interval: TimeInterval,
                         appearance: Data,
                         hidOnly: Bool,
                         category: HIDDeviceCategory,
                         includeMotion: Bool) {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        subscribedCentrals.removeAll()
        motionCentrals.removeAll()
        connectedCentrals.removeAll()
        suspendedByHost = false
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.connectedCount = 0
            self.hostConnectionText = "尚无主机连接"
            self.hostControlPointText = "未收到控制点指令"
            self.hostSubscribedInput = false
            self.hostReadReportMap = false
        }

        didFallback = false
        usingFullUUID = !attemptShort
        let set = HIDServiceBuilder.build(
            profile: profile,
            spoofIdentity: spoof,
            useFullHIDUUID: usingFullUUID,
            appearance: appearance,
            category: category,
            deviceName: name,
            includeMotion: includeMotion
        )
        serviceSet = set

        DispatchQueue.main.async { self.activeUUIDFormat = set.uuidFormatDescription }

        let analysis = HIDSpec.analyzeDescriptor()
        if analysis.isValid {
            log.add("描述符自检通过：" + analysis.summary)
        } else {
            for issue in analysis.issues { log.add(issue, level: .error) }
        }
        log.add("HID 顶层用途类别：\(category.displayName)（用途编号 0x\(String(category.topLevelUsage, radix: 16))）。\(category.hostHint)")
        log.add(includeMotion
                ? "报告描述符含运动传感器集合（陀螺仪与加速度）"
                : "报告描述符已精简：不含运动传感器集合，只保留手柄与力反馈")

        pendingAddCount = set.allServices.count
        completedAddCount = 0
        currentAdvertisedName = name
        currentInterval = interval
        currentProfile = profile
        currentSpoofIdentity = spoof
        currentIncludeReportIDPrefix = includePrefix
        currentAppearance = appearance
        currentAdvertiseHIDOnly = hidOnly
        currentCategory = category
        currentIncludeMotion = includeMotion
        log.add("添加 \(pendingAddCount) 个 GATT 服务，HID 服务编号形式：\(set.uuidFormatDescription)")
        for service in set.allServices { manager?.add(service) }
    }

    private var currentAdvertisedName = "WP-Pad"
    private var currentInterval: TimeInterval = 1.0 / 60
    /// 当前生效配置的队列内副本，回调里不直接读取被界面修改的设置对象。
    private var currentProfile: ControllerProfile = .generic
    private var currentSpoofIdentity = false
    private var currentIncludeReportIDPrefix = false
    private var currentAppearance = HIDAppearance.gamepad.data
    private var currentAdvertiseHIDOnly = false
    /// 当前生效的 HID 顶层用途类别。
    private var currentCategory: HIDDeviceCategory = .gamepad
    /// 当前描述符里是否带运动传感器集合。
    private var currentIncludeMotion = true
    /// 16 位广播被系统拒绝时才切到 true，日志会明确提示主机大概率发现不了。
    private var advertisingUsesFullUUIDs = false

    private func startAdvertising(fullUUIDs: Bool = false) {
        guard let set = serviceSet, let manager else { return }
        advertisingUsesFullUUIDs = fullUUIDs
        let uuids: [CBUUID] = fullUUIDs
            ? [SIGUUID.full(SIGUUID.hidService),
               SIGUUID.full(SIGUUID.deviceInformationService),
               SIGUUID.full(SIGUUID.batteryService)]
            : (currentAdvertiseHIDOnly
               ? [SIGUUID.short(SIGUUID.hidService)]
               : set.advertisedUUIDs)
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: currentAdvertisedName,
            CBAdvertisementDataServiceUUIDsKey: uuids
        ]
        // 31 字节广播预算估算：Flags 3 字节 + 名称 2+n + 16 位服务列表 2+2n。
        let budget = 3 + 2 + currentAdvertisedName.utf8.count + 2 + uuids.count * 2
        log.add("请求广播：名称 \(currentAdvertisedName)，\(uuids.count) 个服务编号，估算占用 \(budget)/31 字节\(currentAdvertiseHIDOnly ? "（极简模式）" : "")")
        log.add("服务编号：\(fullUUIDs ? "完整 128 位（回退）" : "标准 16 位 1812" + (currentAdvertiseHIDOnly ? "" : " / 180F / 180A"))；GATT Appearance：\(currentAppearance.map { String(format: "%02X", $0) }.joined())")
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
              !suspendedByHost,
              let manager else { return }

        reportLock.lock()
        let data = latestReport
        let motionData = latestMotionReport
        reportLock.unlock()

        // 两个报告走不同特征、不同订阅列表；主机没订阅运动特征时不发。
        if let data, !subscribedCentrals.isEmpty {
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
        if let motionData,
           let motionCharacteristic = set.motionReportCharacteristic,
           !motionCentrals.isEmpty {
            // 运动报告满量程 ±2000 度/秒、±16G；主机不订阅则零开销。
            _ = manager.updateValue(
                motionData,
                for: motionCharacteristic,
                onSubscribedCentrals: motionCentrals
            )
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
            let appearance = settings.appearance.data
            let hidOnly = settings.advertiseHIDOnly
            let category = settings.hidCategory
            let includeMotion = !settings.compactHIDDescriptor
            rebuild(profile: profile, spoof: spoof, attemptShort: attemptShort,
                    includePrefix: includePrefix, name: name, interval: interval,
                    appearance: appearance, hidOnly: hidOnly, category: category,
                    includeMotion: includeMotion)
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
                        interval: currentInterval,
                        appearance: currentAppearance,
                        hidOnly: currentAdvertiseHIDOnly,
                        category: currentCategory,
                        includeMotion: currentIncludeMotion)
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
            log.add("主机列表显示的通常是 iPhone 整机 GAP 名称，不是 \(currentAdvertisedName)；请在列表里找手机名，配对后可重命名", level: .info)
            log.add("排查：用 nRF Connect 扫描本 iPhone。扫得到 0x1812 说明广播正常、是主机按设备类别过滤；扫不到说明广播未真正发出", level: .info)
            log.add("已知硬限制：iOS 不开放广播包的 GAP Appearance，Windows 与部分安卓机的蓝牙设置会因此不列出本设备；GATT 中的 0x1800/0x2A01 只是尽力而为", level: .warn)
            if advertisingUsesFullUUIDs {
                log.add("当前为 128 位回退广播，多数主机不会把设备列进蓝牙列表", level: .warn)
            }
            log.add("若 iPad 之前连过同一台 iPhone，先在 iPad 蓝牙设置里「忽略此设备」再重新扫描", level: .info)
        }
    }

    // MARK: - 链路建立与断开
    //
    // 外设侧没有可靠的「已连接」回调：CBPeripheralManagerDelegate 只提供
    // 订阅与退订，连接成立与否要从主机读特征、写控制点这些回调里拿到 central。
    // 以前这些 central 全被丢掉，界面上的「已连接 0 台」其实分不清
    // 「主机根本没连」和「连上了但没订阅报告」这两种完全不同的故障。
    // 现在统一由 registerCentral 登记，掉线靠「主机退订输入报告」来判定。

    /// 记录已建立链路的主机。
    ///
    /// 外设侧没有可靠的「已连接」回调，主机一旦连上必然会读报告描述符、
    /// 写控制点或订阅报告特征，这些回调里都带着 central，
    /// 以此作为连接成立的证据，比等订阅更早也更准。
    private func registerCentral(_ central: CBCentral) {
        guard !connectedCentrals.contains(where: { $0 === central }) else { return }
        connectedCentrals.append(central)
        DispatchQueue.main.async {
            self.hostConnectionText = "已连接，握手进行中"
        }
        publishConnectedCount()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard let set = serviceSet else { return }
        registerCentral(central)
        if characteristic === set.inputReportCharacteristic {
            if !subscribedCentrals.contains(where: { $0 === central }) {
                subscribedCentrals.append(central)
            }
            log.add("主机订阅输入报告，当前已连接 \(connectedCentrals.count) 台")
            DispatchQueue.main.async { self.hostSubscribedInput = true }
        } else if let motion = set.motionReportCharacteristic, characteristic === motion {
            if !motionCentrals.contains(where: { $0 === central }) {
                motionCentrals.append(central)
            }
            log.add("主机订阅运动报告（陀螺仪与加速度），当前已连接 \(connectedCentrals.count) 台")
        } else {
            return
        }
        publishConnectedCount()
        sendLatestReport()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let set = serviceSet else { return }
        var linkClosed = false
        if characteristic === set.inputReportCharacteristic {
            subscribedCentrals.removeAll { $0 === central }
            // 主机退订输入报告，基本意味着链路已经断开。
            // 外设侧没有断开回调，这是不依赖不确定接口的判定方式。
            connectedCentrals.removeAll { $0 === central }
            linkClosed = true
            DispatchQueue.main.async {
                self.hostSubscribedInput = false
                if linkClosed { self.hostConnectionText = "已断开" }
            }
        } else if let motion = set.motionReportCharacteristic, characteristic === motion {
            motionCentrals.removeAll { $0 === central }
        } else {
            return
        }
        log.add(linkClosed
                ? "主机退订输入报告，判定链路已断"
                : "主机取消订阅，当前已连接 \(connectedCentrals.count) 台")
        publishConnectedCount()
    }

    /// 两个报告特征独立订阅，界面显示的连接数取已建立链路的 centrals，
    /// 不再用订阅数——主机连上但还没订阅时订阅数是零，会被误判成没连上。
    private var connectedTotal: Int {
        var seen: [CBCentral] = []
        for central in subscribedCentrals + motionCentrals {
            if !seen.contains(where: { $0 === central }) { seen.append(central) }
        }
        return seen.count
    }

    private func publishConnectedCount() {
        let total = connectedCentrals.count
        let subscribed = connectedTotal
        DispatchQueue.main.async {
            self.connectedCount = total
            if total > 0 {
                self.hostConnectionText = subscribed > 0
                    ? "已连接 \(total) 台，输入报告已被订阅"
                    : "已连接 \(total) 台，等待主机订阅输入报告"
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        registerCentral(request.central)
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
        } else if let motion = set.motionReportCharacteristic,
                  request.characteristic === motion {
            reportLock.lock()
            let cached = latestMotionReport
            reportLock.unlock()
            value = cached ?? GamepadReport.makeMotionBytes(
                snapshot: .neutral,
                includeReportIDPrefix: currentIncludeReportIDPrefix
            )
        } else {
            value = set.readValue(for: request.characteristic)
        }

        guard let data = value else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        // 主机读报告描述符是建立 HID 连接的关键一步，读到了才算真正认了这个设备。
        if SIGUUID.shortCode(request.characteristic.uuid) == SIGUUID.reportMap {
            DispatchQueue.main.async {
                self.hostReadReportMap = true
                self.hostConnectionText = "已连接，主机已读取报告描述符"
            }
            log.add("主机读取报告描述符，共 \(data.count) 字节，顶层用途 \(currentCategory.displayName)")
        }
        let offset = max(0, request.offset)
        request.value = offset >= data.count ? Data() : data.subdata(in: offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        guard let set = serviceSet else { return }

        for request in requests {
            registerCentral(request.central)
            let bytes = Array(request.value ?? Data())
            if request.characteristic === set.outputReportCharacteristic {
                if let rumble = GamepadReport.parseRumble(Data(bytes)) {
                    log.add("收到力反馈：大马达 \(rumble.low)，小马达 \(rumble.high)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onRumble?(rumble.low, rumble.high)
                    }
                }
            } else if request.characteristic === set.hidControlPointCharacteristic {
                handleControlPoint(peripheral: peripheral, central: request.central, command: bytes.first)
            } else if request.characteristic === set.protocolModeCharacteristic {
                protocolModeValue = bytes.first ?? 0x01
                log.add("主机设置协议模式：\(protocolModeValue == 0 ? "启动协议" : "报告协议")")
            }
            // 带响应的写必须逐条应答；Write Without Response 的不能应答，
            // 否则系统会当成写失败。
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    /// 处理 HID Control Point 指令。
    ///
    /// 蓝牙 SIG 官方 Assigned Numbers 对 0x2A4C 的口径是：
    /// 写入 0x00 表示挂起、0x01 表示退出挂起，并注明这两个命令没有定义响应码。
    /// 主线行为按官方口径：收到挂起就停发输入报告，收到退出挂起就恢复。
    ///
    /// 另有一套流传口径（0x01 挂起 / 0x02 退出挂起 / 0x03、0x04 为接受响应），
    /// 它在 0x01、0x02 上与官方口径重叠，没法完全区分。
    /// 为兼顾「主机会等响应」的情况，这里补一条回声通知，
    /// 回声字节取主机写进来的那个值：官方口径下等于标准响应，
    /// 另一套口径下至少不会让主机无限等待。
    private func handleControlPoint(peripheral: CBPeripheralManager,
                                    central: CBCentral,
                                    command: UInt8?) {
        let value = command ?? HIDControlPoint.suspend
        var suspendRequested = false
        var resumeRequested = false

        if value == HIDControlPoint.suspend {
            suspendRequested = true
        } else if value == HIDControlPoint.exitSuspend {
            resumeRequested = true
        } else if value == HIDControlPoint.legacyExitSuspend {
            resumeRequested = true
        } else {
            log.add("未知的控制点指令 0x\(String(value, radix: 16))，按忽略处理", level: .warn)
            return
        }

        if suspendRequested {
            suspendedByHost = true
            log.add("主机请求挂起（控制点 0x00），停止发送输入报告")
        }
        if resumeRequested {
            suspendedByHost = false
            log.add("主机请求退出挂起（控制点 0x\(String(value, radix: 16))），恢复发送输入报告")
        }
        // HID over GATT 控制点只写无响应，主机不期待回包，按规范不发送任何通知。
        let text = suspendRequested
            ? "已收到挂起请求（控制点 0x00）"
            : "已收到退出挂起请求（控制点 0x\(String(value, radix: 16))）"
        DispatchQueue.main.async { self.hostControlPointText = text }
    }
}
