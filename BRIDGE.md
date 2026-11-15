# WaterPad 硬件桥（ESP32-C3）使用与烧录说明

## 这份文档解决什么问题

单纯用 iPhone 模拟蓝牙手柄，会遇到一个 iOS 自身的硬限制：**iOS 不允许 App 在蓝牙广播包里写入 GAP Appearance 字段**。而 Windows 与多数安卓手机的蓝牙设置列表，正是靠这个字段来判断「这是什么设备」的——没有它，哪怕你广播了标准的 HID 服务（0x1812），Windows / 安卓也根本不会把设备列出来。这是系统级限制，纯软件改代码绕不过去（并行项目 PocketTrackpad 已真机验证）。

iPad 的情况稍好：它的鼠标类别在真机上能配对成功，但「游戏手柄」类别是否会被 iPadOS 接管尚未真机确认，而且之前的描述符里那段传感器集合（Usage Page 0x20）很可能直接让主机的 HID 解析器把整个设备拒掉。

**唯一被真机验证过、能在 Windows / 安卓 / iPad 三端都被正常发现并接管的方案，是加一块 ESP32-C3 小板当「硬件桥」：**

```
iPhone（触控 + 陀螺仪采集 + 界面）
   │  WiFi UDP（本地热点，无互联网）
   ▼
ESP32-C3（对外广播成真正的 BLE 游戏手柄，Appearance = Gamepad）
   │  蓝牙低功耗 HID over GATT
   ▼
Windows / 安卓 / iPad（主机）
```

ESP32 能在广播里自由设置 Appearance，所以「被主机发现」这一步交给它；iPhone 只负责采集输入和显示界面。主机下发的力反馈（大/小马达）由 ESP32 经 UDP 回传给 iPhone，用手机自身的触感引擎播放震动。

---

## 一、准备硬件

- 一块 **ESP32-C3 开发板**（任意型号均可，最便宜的「ESP32-C3 SuperMini」「ESP32-C3-DevKitM-1」即可，约 ¥15–30）。
- USB 数据线（能传数据的，不是只能充电的）。
- 一台电脑（Windows / macOS / Linux 都行），用于烧录固件。

> 不需要焊任何东西，ESP32-C3 插上 USB 就能烧。

---

## 二、烧录固件

固件源码在本仓库 `esp32/src/main.cpp`，基于已验证的 NimBLE-Arduino 1.4.x。

### 方式 A：Arduino IDE

1. 安装 [Arduino IDE](https://www.arduino.cc/en/software)。
2. 装板支持：首选项 → 附加开发板管理器网址，加入
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
   然后在「开发板管理器」里搜 `esp32` 并安装（用 2.x 或 3.x 均可，库版本 NimBLE-Arduino 1.4.x 自带）。
3. 选开发板：`ESP32C3 Dev Module`（或你手头板子的对应项），端口选烧录时出现的 COM 口。
4. 打开 `esp32/src/main.cpp`，点击「上传」。
5. 上传成功后在「串口监视器」应看到：
   ```
   WaterPad ESP32 硬件桥启动（游戏手柄 / Appearance=Gamepad）
   AP SSID: WP-Bridge  IP: 192.168.4.1
   UDP 监听端口: 5001
   BLE HID 广播中：WP-Pad（游戏手柄，Appearance=Gamepad）
   ```

### 方式 B：PlatformIO（VS Code 插件）

新建项目，平台 `espressif32`，板子选 `esp32-c3-devkitm-1`（或对应型号），把 `esp32/src/main.cpp` 作为 `src/main.cpp`，`platformio.ini` 至少包含：

```ini
[env:esp32-c3-devkitm-1]
platform = espressif32
board = esp32-c3-devkitm-1
framework = arduino
board_build.flash_mode = qio
lib_deps = h2zero/NimBLE-Arduino@^1.4.3
```

然后 `pio run -t upload`（串口监视 `pio device monitor -b 115200`）。

> 烧一次即可。以后每次上电，ESP32 会自动起热点 + 广播，不需要重烧。

---

## 三、iPhone 端设置

1. 用 Sideloadly / AltStore 把最新 WaterPad IPA 以你的 Apple ID 重签安装到 iPhone（免费账号签出的 App 7 天有效期，到期重签即可）。
2. 打开 iPhone 的「设置 → 无线局域网」，连上名为 **`WP-Bridge`** 的热点（开放网络，无需密码）。
   - 连上后 iPhone 可能弹出「无互联网连接」的提示，忽略它、保持连接即可——这个热点本来就不联网，只用来传手柄数据。
3. 打开 WaterPad App → 右上角「设置」→「传输模式」选 **硬件桥（ESP32）**。
4. 回到主界面，状态栏会出现「连接硬件桥」按钮，点它；连上后显示「已连接硬件桥」，并出现一个绿色圆点。
5. 现在你在屏幕上的虚拟手柄操作，就会经 WiFi 发给 ESP32，再由 ESP32 以 BLE 游戏手柄身份发给主机。

> 切换回「本机蓝牙」模式则走 iPhone 直连（仅 iPad 鼠标类别验证过，Windows/安卓大概率搜不到，属已知限制）。

---

## 四、主机配对（三端要点）

- **Windows**：设置 → 蓝牙和其他设备 → 添加设备 → 蓝牙。应能看到 `WP-Pad`（类别为游戏手柄）。配对时若弹 PIN，直接点「连接/是」即可（固件未强制配对）。连上后，支持通用 HID 手柄的游戏里就能用手柄了。
- **安卓**：打开系统蓝牙，扫描并配对 `WP-Pad`。部分游戏需在游戏内「控制器设置」里选「蓝牙/通用手柄」。
- **iPad**：蓝牙里配对 `WP-Pad`。支持 MFi/通用手柄的游戏与远程桌面类 App 会识别它。若之前连过同一台 iPhone 的纯蓝牙模式，先在蓝牙设置里「忽略此设备」再重扫。

---

## 五、力反馈（震动）

主机向手柄下发的力反馈（如赛车游戏的碰撞、射击游戏的后坐），由 ESP32 经 UDP 回传给 iPhone，触发手机触感引擎震动。强度在 App「设置 → 震动反馈」里调。注意：只有愿意向通用 HID 手柄下发力反馈的主机/游戏才会触发；很多只认 XInput 的 PC 游戏不会下发。

---

## 六、故障排查

- **iPhone 连不上 WP-Bridge 热点**：确认 ESP32 已上电且串口打印了 `AP SSID: WP-Bridge`；iPhone 离板子近一点；忘记该网络后重连。
- **App 显示「正在连接硬件桥」一直不变**：多半是 iPhone 还没真正连上 WP-Bridge WiFi。去系统无线局域网确认已连上 WP-Bridge，再在 App 里点「断开桥」后重连。
- **App 显示已连接，但主机收不到输入**：用 nRF Connect 扫 ESP32（不是 iPhone），确认能看到 `WP-Pad` 且含 0x1812 服务；确认主机已与 `WP-Pad` 配对；确认游戏本身支持通用蓝牙手柄。
- **主机搜不到 WP-Pad**：确认 ESP32 串口打印了 `BLE HID 广播中`；主机蓝牙列表显示的是 `WP-Pad` 这个名字；Windows 先开「添加设备 → 蓝牙」保持扫描再配对。
- **想改广播名/ WiFi 名**：改 `esp32/src/main.cpp` 里的 `AP_SSID`（热点名）和 `NimBLEDevice::init("WP-Pad")`（广播名），重烧即可；iPhone 端 `BridgeTransport.swift` 里的 `host`（`192.168.4.1`）是 ESP32 软 AP 网关地址，一般不用改。

---

## 七、协议细节（与 iPhone 端严格对应）

- iPhone → 桥 `hello`：`['W','P']`（0x57 0x50），握手。
- 桥 → iPhone `welcome`：`['P','W']`（0x50 0x57），确认链路。
- iPhone → 桥 输入报告：9 字节，与 `HIDSpec` 精简描述符逐字节对应（左 X/Y、右 X/Y、左扳机、右扳机、按钮低位、按钮高位、Hat Switch+填充）。
- 桥 → iPhone 力反馈：`['R', big, small]`（0x52 + 大马达 + 小马达）。
- BLE HID 报告描述符见 `esp32/src/main.cpp` 的 `reportMap`，与 iOS 端精简描述符完全一致；Appearance = `0x03C4`（Gamepad）。
