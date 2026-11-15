import Foundation
import Network

/// 硬件桥传输层：iPhone 经由 WiFi UDP 把 HID 报告发给 ESP32-C3 小板，
/// 由小板对外扮演真正的 BLE 游戏手柄。这样绕开了 iOS 外设无法设置
/// GAP Appearance 的系统限制，Windows / 安卓 / iPad 都能正常发现并接管。
///
/// 链路协议（与 esp32/src/main.cpp 严格一致）：
///   iPhone -> 桥  hello:   [0x57, 0x50] = "WP"
///   桥 -> iPhone  welcome: [0x50, 0x57] = "PW"
///   iPhone -> 桥  input:   9 字节输入报告（与 HIDSpec 精简描述符逐字节对应）
///   桥 -> iPhone  rumble:  [0x52, big, small] = 'R' + 大马达 + 小马达
///
/// 使用前提：iPhone 已在系统「无线局域网」里连上 ESP32 发出的 "WP-Bridge" 热点。
final class BridgeTransport: ObservableObject {
    enum State: String {
        case disconnected
        case connecting
        case connected
        var text: String {
            switch self {
            case .disconnected: return "未连接硬件桥"
            case .connecting: return "正在连接硬件桥…"
            case .connected: return "已连接硬件桥"
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastError: String?

    /// 主机下发力反馈时由桥回传，外部接 haptics 播放手机震动。
    var onRumble: ((UInt8, UInt8) -> Void)?

    private let host = "192.168.4.1"
    private let port: UInt16 = 5001
    private let queue = DispatchQueue(label: "com.water.waterpad.bridge", qos: .userInteractive)
    private var connection: NWConnection?
    private var helloTimer: DispatchSourceTimer?
    private var isCancelled = false

    // MARK: - 连接管理

    func connect() {
        guard connection == nil else { return }
        isCancelled = false
        DispatchQueue.main.async {
            self.state = .connecting
            self.lastError = nil
        }

        var params = NWParameters.udp
        // 强制走 WiFi：硬件桥是本地无互联网热点，避免 iOS 误走蜂窝。
        params.requiredInterfaceType = .wifi

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleState(newState)
        }
        conn.start(queue: queue)
        receiveLoop(conn)
        startHelloTimer(conn)
    }

    func disconnect() {
        isCancelled = true
        helloTimer?.cancel()
        helloTimer = nil
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async {
            self.state = .disconnected
        }
    }

    /// 每帧把 9 字节输入报告发往硬件桥。未连接时静默丢弃。
    func sendInput(_ data: Data) {
        guard state == .connected, let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed({ _ in }))
    }

    // MARK: - 内部

    private func handleState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            // 链路就绪即发握手包，并在收到 welcome 前周期性重发。
            sendHello()
        case .failed(let error):
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.state = .disconnected
            }
            connection = nil
        case .cancelled:
            connection = nil
        default:
            break
        }
    }

    private func startHelloTimer(_ conn: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.state != .connected, !self.isCancelled else { return }
            self.sendHello()
        }
        timer.resume()
        helloTimer = timer
    }

    private func sendHello() {
        let hello = Data([0x57, 0x50]) // "WP"
        connection?.send(content: hello, completion: .contentProcessed({ _ in }))
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(data)
            }
            if error == nil, !self.isCancelled {
                self.receiveLoop(conn)
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count >= 1 else { return }
        if bytes.count == 2, bytes[0] == 0x50, bytes[1] == 0x57 {
            // welcome："PW"，确认链路建立。
            helloTimer?.cancel()
            helloTimer = nil
            DispatchQueue.main.async { self.state = .connected }
            return
        }
        if bytes.count >= 3, bytes[0] == 0x52 {
            // rumble：'R' + 大马达 + 小马达
            let low = bytes[1]
            let high = bytes[2]
            DispatchQueue.main.async { self.onRumble?(low, high) }
        }
    }
}
