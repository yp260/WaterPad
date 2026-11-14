import SwiftUI

@main
struct WaterPadApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var log: LogStore
    @StateObject private var pad: PadState
    @StateObject private var haptics: HapticEngineController
    @StateObject private var peripheral: HIDPeripheralManager

    init() {
        let settings = SettingsStore()
        let log = LogStore()
        let pad = PadState()
        let haptics = HapticEngineController(settings: settings, log: log)
        let peripheral = HIDPeripheralManager(settings: settings, log: log)

        peripheral.onRumble = { [weak haptics] low, high in
            haptics?.playRumble(low: low, high: high)
        }

        _settings = StateObject(wrappedValue: settings)
        _log = StateObject(wrappedValue: log)
        _pad = StateObject(wrappedValue: pad)
        _haptics = StateObject(wrappedValue: haptics)
        _peripheral = StateObject(wrappedValue: peripheral)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(pad)
                .environmentObject(haptics)
                .environmentObject(peripheral)
        }
    }
}
