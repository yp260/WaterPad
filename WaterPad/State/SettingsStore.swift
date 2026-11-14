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
    }

    var profile: ControllerProfile { .withID(profileID) }
    var reportInterval: TimeInterval { 1.0 / Double(reportFrequency) }

    /// 广播用的设备名称。伪装开关默认关闭，避免触发主机侧真实厂商驱动误加载。
    var advertisedName: String {
        spoofIdentity ? profile.spoofedName : "WaterPad"
    }
}
