import Foundation

/// 全部设置用 UserDefaults 持久化。rebuildToken 变化时蓝牙层会重建 GATT 服务并重新广播；
/// 只影响打包或触感的项目不触发重建。
final class SettingsStore: ObservableObject {
    private enum Key {
        static let profileID = "waterpad.profileID"
        static let spoofIdentity = "waterpad.spoofIdentity"
        static let attemptStandardUUID = "waterpad.attemptStandardUUID"
        static let includeReportIDPrefix = "waterpad.includeReportIDPrefix"
        static let reportFrequency = "waterpad.reportFrequency"
        static let hapticsEnabled = "waterpad.hapticsEnabled"
        static let tapIntensity = "waterpad.tapIntensity"
        static let tapSharpness = "waterpad.tapSharpness"
        static let rumbleEnabled = "waterpad.rumbleEnabled"
        static let rumbleIntensity = "waterpad.rumbleIntensity"
        static let motionEnabled = "waterpad.motionEnabled"
        static let appearanceID = "waterpad.appearanceID"
        static let advertiseHIDOnly = "waterpad.advertiseHIDOnly"
        static let layout = "waterpad.layout"
    }

    private let defaults = UserDefaults.standard

    @Published var profileID: String { didSet { defaults.set(profileID, forKey: Key.profileID); rebuildToken += 1 } }
    @Published var spoofIdentity: Bool { didSet { defaults.set(spoofIdentity, forKey: Key.spoofIdentity); rebuildToken += 1 } }
    @Published var attemptStandardUUID: Bool { didSet { defaults.set(attemptStandardUUID, forKey: Key.attemptStandardUUID); rebuildToken += 1 } }
    @Published var includeReportIDPrefix: Bool { didSet { defaults.set(includeReportIDPrefix, forKey: Key.includeReportIDPrefix) } }
    @Published var reportFrequency: Int { didSet { defaults.set(reportFrequency, forKey: Key.reportFrequency) } }

    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    @Published var tapIntensity: Double { didSet { defaults.set(tapIntensity, forKey: Key.tapIntensity) } }
    @Published var tapSharpness: Double { didSet { defaults.set(tapSharpness, forKey: Key.tapSharpness) } }
    @Published var rumbleEnabled: Bool { didSet { defaults.set(rumbleEnabled, forKey: Key.rumbleEnabled) } }
    @Published var rumbleIntensity: Double { didSet { defaults.set(rumbleIntensity, forKey: Key.rumbleIntensity) } }
    /// 陀螺仪与加速度采集开关。只影响采集与发送内容，不改变 GATT 结构，无需重建服务。
    @Published var motionEnabled: Bool { didSet { defaults.set(motionEnabled, forKey: Key.motionEnabled) } }
    /// GATT 中 0x2A01 Appearance 声明的设备类别，改动需重建 GATT 服务。
    @Published var appearanceID: String { didSet { defaults.set(appearanceID, forKey: Key.appearanceID); rebuildToken += 1 } }
    /// 排查开关：广播包只放 0x1812，尽量留足 31 字节预算。
    @Published var advertiseHIDOnly: Bool { didSet { defaults.set(advertiseHIDOnly, forKey: Key.advertiseHIDOnly); rebuildToken += 1 } }

    /// 手柄控件布局（位置与缩放），可编辑并持久化。
    @Published var layout: PadLayout = .default
    /// 是否处于布局编辑态。不持久化，仅本次会话内的临时状态。
    @Published var isEditingLayout: Bool = false

    @Published private(set) var rebuildToken: Int = 0

    static let availableFrequencies = [60, 90, 125]

    init() {
        let stored = UserDefaults.standard
        profileID = stored.string(forKey: Key.profileID) ?? "generic"
        spoofIdentity = stored.object(forKey: Key.spoofIdentity) as? Bool ?? false
        attemptStandardUUID = stored.object(forKey: Key.attemptStandardUUID) as? Bool ?? false
        includeReportIDPrefix = stored.object(forKey: Key.includeReportIDPrefix) as? Bool ?? false

        let frequency = stored.integer(forKey: Key.reportFrequency)
        reportFrequency = Self.availableFrequencies.contains(frequency) ? frequency : 60

        hapticsEnabled = stored.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        tapIntensity = stored.object(forKey: Key.tapIntensity) as? Double ?? 0.55
        tapSharpness = stored.object(forKey: Key.tapSharpness) as? Double ?? 0.45
        rumbleEnabled = stored.object(forKey: Key.rumbleEnabled) as? Bool ?? true
        rumbleIntensity = stored.object(forKey: Key.rumbleIntensity) as? Double ?? 0.70
        motionEnabled = stored.object(forKey: Key.motionEnabled) as? Bool ?? true
        appearanceID = stored.string(forKey: Key.appearanceID) ?? HIDAppearance.gamepad.rawValue
        advertiseHIDOnly = stored.object(forKey: Key.advertiseHIDOnly) as? Bool ?? false

        if let data = stored.data(forKey: Key.layout),
           let decoded = try? JSONDecoder().decode(PadLayout.self, from: data) {
            layout = decoded
        }
    }

    /// 把当前布局编码写入 UserDefaults。编辑完成时调用。
    func persistLayout() {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Key.layout)
        }
    }

    var profile: ControllerProfile { .withID(profileID) }
    var reportInterval: TimeInterval { 1.0 / Double(reportFrequency) }

    /// 广播用的设备名称。压到 6 字符，给 31 字节广播包留余量；
    /// 与并行项目已真机配对成功的 PT-Pad 同长度。
    var advertisedName: String {
        spoofIdentity ? profile.spoofedName : "WP-Pad"
    }

    var appearance: HIDAppearance { .withID(appearanceID) }
}
