import Foundation
import CoreHaptics

/// 手机侧触感反馈。
///
/// 两类震动分开控制：
/// 1. 按键反馈：每次按下虚拟按键时播放瞬态事件，强度与锐度由设置页滑块给定。
/// 2. 游戏反馈：主机通过 HID 输出报告下发大马达与小马达力度，换算后按设置里的
///    「游戏震动强度」缩放，再播放连续事件。此路径依赖主机愿意向通用 HID 手柄
///    发送力反馈，多数只认 XInput 的游戏不会下发，日志里会记录是否收到。
final class HapticEngineController: ObservableObject {

    @Published private(set) var isAvailable = false
    @Published private(set) var capabilityText = "未检测"

    private var engine: CHHapticEngine?
    private let settings: SettingsStore
    private let log: LogStore
    private var lastRumbleTime: Date = .distantPast

    init(settings: SettingsStore, log: LogStore) {
        self.settings = settings
        self.log = log
        prepare()
    }

    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            capabilityText = "当前设备不支持 Core Haptics"
            log.add(capabilityText + "，模拟器与 iPhone 7 及更早机型无触感引擎", level: .warn)
            return
        }
        do {
            let newEngine = try CHHapticEngine()
            newEngine.stoppedHandler = { [weak self] reason in
                guard let self else { return }
                self.log.add("触感引擎停止：\(reason.rawValue)", level: .warn)
                DispatchQueue.main.async { self.isAvailable = false }
            }
            newEngine.resetHandler = { [weak self] in
                guard let self else { return }
                self.log.add("触感引擎重置，尝试重启")
                do {
                    try self.engine?.start()
                    DispatchQueue.main.async { self.isAvailable = true }
                } catch {
                    self.log.add("触感引擎重启失败：\(error.localizedDescription)", level: .error)
                }
            }
            engine = newEngine
            try newEngine.start()
            isAvailable = true
            capabilityText = "触感引擎就绪"
            log.add("触感引擎已启动")
        } catch {
            capabilityText = "触感引擎启动失败"
            log.add("触感引擎启动失败：\(error.localizedDescription)", level: .error)
        }
    }

    /// 应用回到前台时系统可能已经停掉触感引擎，需要重启。
    func resumeIfNeeded() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, !isAvailable else { return }
        do {
            try engine?.start()
            isAvailable = true
            log.add("触感引擎已随应用回到前台重启")
        } catch {
            log.add("触感引擎重启失败：\(error.localizedDescription)", level: .error)
        }
    }

    func playTap() {
        guard settings.hapticsEnabled,
              settings.tapIntensity > 0.01,
              isAvailable,
              let engine else { return }

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity,
                                                value: Float(clamp01(settings.tapIntensity)))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness,
                                                value: Float(clamp01(settings.tapSharpness)))
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [intensity, sharpness],
                                  relativeTime: 0)
        play(event: event, engine: engine, failureHint: "按键反馈")
    }

    func playRumble(low: UInt8, high: UInt8) {
        guard settings.hapticsEnabled,
              settings.rumbleEnabled,
              isAvailable,
              let engine else { return }

        // 主机可能每帧下发一次，这里限流到最多每 80 毫秒一次，避免触感引擎被压垮。
        let now = Date()
        guard now.timeIntervalSince(lastRumbleTime) >= 0.08 else { return }
        lastRumbleTime = now

        let raw = (Double(low) + Double(high)) / 510.0
        let scaled = clamp01(raw * clamp01(settings.rumbleIntensity))
        guard scaled > 0.02 else { return }

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(scaled))
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness,
                                                value: Float(clamp01(settings.tapSharpness)))
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [intensity, sharpness],
                                  relativeTime: 0,
                                  duration: 0.12)
        play(event: event, engine: engine, failureHint: "游戏震动")
    }

    /// 设置页试震按钮用。
    func preview(intensity: Double, sharpness: Double) {
        guard isAvailable, let engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(clamp01(intensity))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(clamp01(sharpness)))
            ],
            relativeTime: 0
        )
        play(event: event, engine: engine, failureHint: "试震")
    }

    private func play(event: CHHapticEvent, engine: CHHapticEngine, failureHint: String) {
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log.add("\(failureHint)播放失败：\(error.localizedDescription)", level: .error)
        }
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
