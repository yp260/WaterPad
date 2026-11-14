import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var pad: PadState
    @EnvironmentObject private var peripheral: HIDPeripheralManager
    @EnvironmentObject private var haptics: HapticEngineController
    @EnvironmentObject private var motion: MotionProvider
    @EnvironmentObject private var log: LogStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSettings = false
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            GamepadView()
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        // 刻意不自动启动蓝牙外设：万一注册 GATT 服务时抛出 Objective-C 异常，
        // Swift 捕获不到会直接杀掉进程，界面连诊断线索都来不及显示。
        // 由用户点「开始广播」触发，异常时能停在界面上查看日志。
        .onAppear {
            log.add("界面就绪，点「开始广播」启动蓝牙外设")
            motion.apply(enabled: settings.motionEnabled)
        }
        // 状态以 60 赫兹采样并生成输入报告；蓝牙层按设置中的频率发送。
        .onReceive(Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()) { _ in
            peripheral.submit(
                snapshot: pad.snapshot,
                profile: settings.profile,
                includeReportIDPrefix: settings.includeReportIDPrefix
            )
        }
        .onChange(of: settings.rebuildToken) { _ in
            peripheral.reconfigure()
        }
        .onChange(of: settings.reportFrequency) { _ in
            peripheral.applyFrequency()
        }
        .onChange(of: settings.includeReportIDPrefix) { _ in
            peripheral.applyPacketFormat()
        }
        .onChange(of: settings.motionEnabled) { enabled in
            motion.apply(enabled: enabled)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                peripheral.resumeIfNeeded()
                haptics.resumeIfNeeded()
                motion.apply(enabled: settings.motionEnabled)
            case .background:
                log.add("应用进入后台，蓝牙广播可能受限，建议保持前台常亮", level: .warn)
            default:
                break
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(haptics)
                .environmentObject(peripheral)
                .environmentObject(motion)
        }
        .sheet(isPresented: $showingLog) {
            LogView().environmentObject(log)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peripheral.isAdvertising ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(peripheral.isAdvertising ? "广播中" : "未广播")
                .font(.caption)
            Text(peripheral.bluetoothStateText)
                .font(.caption)
                .foregroundColor(.secondary)
            if peripheral.connectedCount > 0 {
                Text("已连接 \(peripheral.connectedCount) 台")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            Text(settings.profile.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Button(peripheral.isAdvertising ? "停止广播" : "开始广播") {
                if peripheral.isAdvertising {
                    peripheral.stop()
                } else {
                    peripheral.start()
                }
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            if !settings.isEditingLayout {
                Button("布局") { settings.isEditingLayout = true }
                    .font(.caption)
            }
            Button("日志") { showingLog = true }
                .font(.caption)
            Button("设置") { showingSettings = true }
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}
