import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var haptics: HapticEngineController
    @EnvironmentObject private var peripheral: HIDPeripheralManager
    @EnvironmentObject private var log: LogStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingLog = false

    var body: some View {
        NavigationView {
            Form {
                Section("连接状态") {
                    row(title: "蓝牙", value: peripheral.bluetoothStateText)
                    row(title: "广播", value: peripheral.isAdvertising ? "进行中" : "未开启")
                    row(title: "已连接主机", value: "\(peripheral.connectedCount) 台")
                    row(title: "HID 服务编号", value: peripheral.activeUUIDFormat)
                    if let message = peripheral.lastErrorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("重新构建服务并广播") {
                        peripheral.reconfigure()
                    }
                }

                Section("手柄身份") {
                    Picker("手柄档位", selection: $settings.profileID) {
                        ForEach(ControllerProfile.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    Text(settings.profile.caveat)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("伪装厂商名称与编号", isOn: $settings.spoofIdentity)
                    Text("关闭时广播名称为 WaterPad，PnP ID 中的厂商与产品编号填零，避免主机误加载真实厂商驱动。切换后会自动重新广播。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("协议参数") {
                    Toggle("先尝试标准 16 位 HID 服务编号", isOn: $settings.attemptStandardUUID)
                    Text("当前系统大概率拒绝，日志会记录拒绝并自动回退到完整 128 位。留作未来苹果放开接口时的探测开关。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("输入报告带一字节编号前缀", isOn: $settings.includeReportIDPrefix)
                    Text("HID over GATT 规范要求不带前缀；若主机收不到输入，可打开此项再试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("发送频率", selection: $settings.reportFrequency) {
                        ForEach(SettingsStore.availableFrequencies, id: \.self) { frequency in
                            Text("\(frequency) 赫兹").tag(frequency)
                        }
                    }
                }

                Section("震动反馈") {
                    row(title: "触感引擎", value: haptics.capabilityText)
                    Toggle("启用触感反馈", isOn: $settings.hapticsEnabled)
                    intensitySlider(title: "按键反馈强度", value: $settings.tapIntensity)
                    intensitySlider(title: "触感锐度", value: $settings.tapSharpness)
                    Toggle("启用游戏震动回传", isOn: $settings.rumbleEnabled)
                    intensitySlider(title: "游戏震动强度", value: $settings.rumbleIntensity)
                    Button("按当前设置试震") {
                        haptics.preview(intensity: settings.tapIntensity,
                                        sharpness: settings.tapSharpness)
                    }
                    Text("低电量模式或系统关闭触感时，Core Haptics 不会生效。游戏震动依赖主机向通用 HID 手柄下发力反馈，多数只认 XInput 的游戏不会下发。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("已知边界") {
                    Text("主机得到的是通用 HID 游戏手柄，不是 XInput 的 Xbox 设备，也不会通过 PS4、Switch 或 Xbox 主机的认证握手。iPadOS 能否接管「手柄」这一 HID 类别尚未真机验证；同一条蓝牙链路上「鼠标」类别已在 iPad 上配对成功，请以本机实测为准。GATT 服务用完整 128 位编号、广播用 16 位编号属于利用系统检查口径差异，系统更新可能封掉此路径，上架审核亦有风险。应用必须保持前台，退到后台或锁屏后广播会受限。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("布局") {
                    Button("编辑布局") {
                        dismiss()
                        settings.isEditingLayout = true
                    }
                    Button("重置为默认布局") {
                        settings.layout = .default
                        settings.persistLayout()
                    }
                }

                Section {
                    Button("查看连接日志") { showingLog = true }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLog) {
                LogView().environmentObject(log)
            }
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func intensitySlider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }
}
