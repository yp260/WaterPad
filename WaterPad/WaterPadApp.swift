import SwiftUI

@main
struct WaterPadApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var log: LogStore
    @StateObject private var pad: PadState
    @StateObject private var haptics: HapticEngineController
    @StateObject private var peripheral: HIDPeripheralManager
    @StateObject private var motion: MotionProvider
    @StateObject private var bridge: BridgeTransport

    init() {
        let settings = SettingsStore()
        let log = LogStore()
        let pad = PadState()
        let haptics = HapticEngineController(settings: settings, log: log)
        let peripheral = HIDPeripheralManager(settings: settings, log: log)
        let motion = MotionProvider(pad: pad, log: log)
        let bridge = BridgeTransport()

        peripheral.onRumble = { [weak haptics] low, high in
            haptics?.playRumble(low: low, high: high)
        }
        // 硬件桥把主机下发的力反馈回传给 iPhone，用手机触感引擎播放。
        bridge.onRumble = { [weak haptics] low, high in
            haptics?.playRumble(low: low, high: high)
        }

        _settings = StateObject(wrappedValue: settings)
        _log = StateObject(wrappedValue: log)
        _pad = StateObject(wrappedValue: pad)
        _haptics = StateObject(wrappedValue: haptics)
        _peripheral = StateObject(wrappedValue: peripheral)
        _motion = StateObject(wrappedValue: motion)
        _bridge = StateObject(wrappedValue: bridge)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(pad)
                .environmentObject(haptics)
                .environmentObject(peripheral)
                .environmentObject(motion)
                .environmentObject(bridge)
        }
    }
}
