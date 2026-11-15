// WaterPad 硬件桥固件（ESP32-C3，NimBLE-Arduino 1.4.x）
//
// 角色：iPhone 把 9 字节手柄输入报告通过 WiFi UDP 发给本设备，
// 本设备以「标准 BLE HID 游戏手柄」转发给 Windows / Android / iPad。
//
// 为什么需要它：iOS 的 CoreBluetooth 外设无法在广播包里设置 GAP Appearance 字段，
// Windows 与多数安卓机的蓝牙设置列表依赖该字段判断设备类别，因此根本不会把
// iPhone 列出来。ESP32 能在广播里自由设置 Appearance，所以「被主机发现」这一步
// 交给它，iPhone 只负责触控 / 陀螺仪采集与界面。
//
// 报告布局（9 字节输入报告，与 iOS 端 HIDSpec 的精简描述符逐字节对应）：
//   字节 0 左摇杆 X，字节 1 左摇杆 Y，字节 2 右摇杆 X，字节 3 右摇杆 Y，
//   字节 4 左扳机，字节 5 右扳机，字节 6 按钮低位，字节 7 按钮高位，
//   字节 8 低四位 Hat Switch（1~8，0 为空位态），高四位为常量填充（保持 0）。
// 输出报告（2 字节）：主机下发的力反馈，字节 0 大马达、字节 1 小马达，各 0~255。
// 该输出报告由本固件通过 UDP 回传给 iPhone，驱动手机震动。
//
// Appearance = HID Gamepad (0x03C4)：让主机把设备当游戏手柄对待，
// 这是 iOS 外设做不到、而 ESP32 可以做的，也是三端都能搜到它的关键。
//
// 配套 iPhone 端：WaterPad/BridgeTransport.swift 的 UDP 协议
//   hello:   ['W','P'] (0x57 0x50)   iPhone -> 桥，握手
//   welcome: ['P','W'] (0x50 0x57)   桥 -> iPhone，确认链路
//   input:   9 字节输入报告           iPhone -> 桥，每帧
//   rumble:  ['R', big, small]       桥 -> iPhone，主机下发力反馈时回传
//
// 烧录与配网见仓库根目录 BRIDGE.md。

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

// ---- 网络 ----
static const char* AP_SSID = "WP-Bridge";   // iPhone 在「无线局域网」里连接此热点
static const char* AP_PASS = "";            // 开放网络，无需密码
static const uint16_t UDP_PORT = 5001;
static WiFiUDP udp;

// iPhone 最后一次发包的地址，力反馈包要原路回传。
static IPAddress clientIP;
static uint16_t clientPort = 0;

// ---- BLE HID 描述符 ----
// 与 iOS 端精简描述符（去掉传感器集合）完全一致：游戏手柄应用集合，
// 输入报告编号 1（9 字节），输出报告编号 2（2 字节力反馈）。
static const uint8_t reportMap[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x05,        // Usage (Gamepad)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)
    // 四个八位轴：左 X / 左 Y / 右 X / 右 Y（用法 Z / Rz 复用作右摇杆）
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x35,        //   Usage (Rz)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    // 两个八位模拟扳机：Rx / Ry
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x33,        //   Usage (Rx)
    0x09, 0x34,        //   Usage (Ry)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x02,        //   Report Count (2)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    // 十六个一位按钮
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (Button 1)
    0x29, 0x10,        //   Usage Maximum (Button 16)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x10,        //   Report Count (16)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    // 四位 Hat Switch，取值 1~8，0 为空位态
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x39,        //   Usage (Hat switch)
    0x15, 0x01,        //   Logical Minimum (1)
    0x25, 0x08,        //   Logical Maximum (8)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x65, 0x14,        //   Unit (System: SI Linear, Length: Degree)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null)
    // 四位常量填充，凑满整字节
    0x65, 0x00,        //   Unit (None)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x01,        //   Input (Const,Array,Abs)
    // 输出报告编号 2：厂商自定义两个八位力度字段（力反馈）
    0x85, 0x02,        //   Report ID (2)
    0x06, 0x00, 0xFF,  //   Usage Page (Vendor Defined)
    0x09, 0x01,        //   Usage (Vendor 1)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x02,        //   Report Count (2)
    0x91, 0x02,        //   Output (Data,Var,Abs)
    0xC0               // End Collection
};

// NimBLE 1.4.x 的 HID 外设对象；特征在 setup 里一次性创建并缓存。
static NimBLEHIDDevice* hid = nullptr;
static NimBLECharacteristic* inputReportChar = nullptr;

// 把一条 9 字节 HID 输入报告发给已订阅的主机。
static void sendHidReport(const uint8_t* data, size_t len) {
    if (inputReportChar == nullptr) return;
    inputReportChar->setValue((uint8_t*)data, len);
    inputReportChar->notify();
}

// 把主机下发的力反馈回传给 iPhone，驱动手机震动。
static void forwardRumble(uint8_t big, uint8_t small) {
    if (clientPort == 0) return;
    uint8_t buf[3] = { 0x52, big, small };  // 'R'
    udp.beginPacket(clientIP, clientPort);
    udp.write(buf, sizeof(buf));
    udp.endPacket();
}

// 输出报告（力反馈）回调：主机把大/小马达力度写进输出报告编号 2。
class OutputCallback : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string value = pCharacteristic->getValue();
        if (value.size() >= 2) {
            forwardRumble((uint8_t)value[0], (uint8_t)value[1]);
        }
    }
};

void setup() {
    Serial.begin(115200);
    Serial.println("\nWaterPad ESP32 硬件桥启动（游戏手柄 / Appearance=Gamepad）");

    // ---- WiFi 热点：iPhone 连上来后通过 UDP 发输入报告 ----
    WiFi.softAP(AP_SSID, AP_PASS);
    Serial.print("AP SSID: ");
    Serial.print(AP_SSID);
    Serial.print("  IP: ");
    Serial.println(WiFi.softAPIP());
    udp.begin(UDP_PORT);
    Serial.printf("UDP 监听端口: %u\n", UDP_PORT);

    // ---- BLE HID：以标准游戏手柄被主机发现 ----
    // 关键：GAP Appearance = 0x03C4 (HID Gamepad)，这是 iOS 外设做不到、
    // 而 ESP32 可以做的。手柄类设备在 Windows / iPadOS / Android 上都能被发现并接管。
    // 不强制配对（bonding/mitm/secure 全 false）。Windows 可能仍弹出配对提示，配对一次即可。
    NimBLEDevice::init("WP-Pad");
    NimBLEDevice::setSecurityAuth(false, false, false);

    NimBLEServer* pServer = NimBLEDevice::createServer();
    hid = new NimBLEHIDDevice(pServer);
    hid->manufacturer("WaterPad");
    hid->pnp(0x02 /*USB*/, 0x1234 /*VID*/, 0x0100 /*PID*/, 0x0100 /*版本*/);
    hid->hidInfo(0x00 /*国家码*/, 0x02 /*Normally Connectable*/);
    hid->reportMap((uint8_t*)reportMap, sizeof(reportMap));
    hid->startServices();
    // 我们的描述符带 Report ID：输入 1、输出 2，与 iOS 端一致。
    inputReportChar = hid->inputReport(1);
    NimBLECharacteristic* outputReportChar = hid->outputReport(2);
    outputReportChar->setCallbacks(new OutputCallback());
    hid->setBatteryLevel(100);

    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    pAdv->setAppearance(0x03C4);
    pAdv->addServiceUUID(NimBLEUUID((uint16_t)0x1812));  // HID Service
    pAdv->start();
    Serial.println("BLE HID 广播中：WP-Pad（游戏手柄，Appearance=Gamepad）");
}

void loop() {
    int len = udp.parsePacket();
    if (len > 0) {
        uint8_t buf[64];
        int n = udp.read(buf, sizeof(buf));
        if (n <= 0) return;

        // 记录 iPhone 的地址，力反馈原路回传。
        clientIP = udp.remoteIP();
        clientPort = udp.remotePort();

        if (n == 2 && buf[0] == 0x57 && buf[1] == 0x50) {
            // iPhone 的 hello 包（"WP"）：回 welcome（"PW"）确认链路，
            // 这样 iPhone 端才会把状态切到「已连接硬件桥」。
            udp.beginPacket(clientIP, clientPort);
            udp.write(0x50);
            udp.write(0x57);
            udp.endPacket();
        } else if (n == 9) {
            // 9 字节输入报告，原样转发给主机。
            sendHidReport(buf, 9);
        }
    }
    delay(1);
}
