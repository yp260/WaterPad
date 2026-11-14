import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var haptics: HapticEngineController
    @EnvironmentObject private var peripheral: HIDPeripheralManager
    @EnvironmentObject private var motion: MotionProvider
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

                Section("搜不到设备时按这个顺序排查") {
                    Text("1. 点「开始广播」，确认本页「广播」显示进行中，日志出现「广播已开启」。若没有，点「复制全部」把日志发回。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("2. 主机列表显示的是 iPhone 整机名称，不是 WP-Pad。请在列表里找你的手机名，配对后再重命名。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("3. Windows：先打开「设置 → 蓝牙和设备 → 添加设备 → 蓝牙」让电脑保持扫描，再回 iPhone 点开始广播；发现窗口很短，可重复点停止再开始。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("4. iPad：若此前连过同一台 iPhone，先在蓝牙设置里「忽略此设备」，再重新扫描。安卓：打开定位与附近设备权限，系统蓝牙扫描依赖定位权限。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("5. 决定性判据：用 nRF Connect 扫描这台 iPhone。扫得到并含 0x1812，说明广播正常、是主机按设备类别过滤；完全扫不到说明广播未真正发出。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("6. 关闭手机上其他会占用蓝牙外设的应用（例如 PocketTrackpad），同一时间只允许一个应用注册 HID 服务。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("查看连接日志并复制") { showingLog = true }
                }

                Section("已知边界") {
                    Text("主机得到的是通用 HID 游戏手柄，不是 XInput 的 Xbox 设备，也不会通过 PS4、Switch 或 Xbox 主机的认证握手。iOS 不向 App 开放广播包的 GAP Appearance，Windows 与多数安卓机的蓝牙发现列表依赖该字段判定设备类别，因此纯 iOS 软件无法保证被它们列出；并行项目 PocketTrackpad 已真机确认这一点，并为此改走 ESP32 硬件桥。iPadOS 能否接管「手柄」这一 HID 类别尚未真机验证；同一条蓝牙链路上「鼠标」类别已在 iPad 上配对成功，请以本机实测为准。GATT 服务用完整 128 位编号、广播用 16 位编号属于利用系统检查口径差异，系统更新可能封掉此路径，上架审核亦有风险。应用必须保持前台，退到后台或锁屏后广播会受限。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("广播与设备类别") {
                    Picker("GAP Appearance", selection: $settings.appearanceID) {
                        ForEach(HIDAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance.id)
                        }
                    }
                    Text("写入 GATT 的 0x1800 / 0x2A01。iOS 不允许 App 把 Appearance 放进广播包，主机绑定阶段可能读取、也可能完全忽略。切换后会自动重建服务并重新广播，可逐个试哪一类能被主机列出。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("广播只放 0x1812（极简模式）", isOn: $settings.advertiseHIDOnly)
                    Text("默认广播 1812 / 180F / 180A 三个编号，估算占用 21/31 字节。打开后只放 HID 服务，留足广播预算，用于排查是否被挤进 overflow 区。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("运动传感器") {
                    row(title: "传感器", value: motion.availabilityText)
                    row(title: "采集状态", value: motion.isActive ? "进行中" : "已停止")
                    Toggle("发送陀螺仪与加速度", isOn: $settings.motionEnabled)
                    Text("按 HID 传感器用法页报告陀螺仪三轴角速度（±2000 度/秒）与加速度计三轴（±16G），随独立的运动报告特征发送。主机不订阅该特征时零开销；Windows 与安卓把数据交给游戏的程度取决于游戏本身，多数游戏不会读取通用 HID 手柄的运动数据。")
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
