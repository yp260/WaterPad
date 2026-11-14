import Foundation

enum LogLevel: String {
    case info = "信息"
    case warn = "警告"
    case error = "错误"
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let message: String
}

/// 应用内日志。蓝牙回调在专用队列上触发，这里统一切回主线程更新界面。
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    private let limit = 300
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func add(_ message: String, level: LogLevel = .info) {
        let line = LogLine(time: Date(), level: level, message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(line)
            if self.lines.count > self.limit {
                self.lines.removeFirst(self.lines.count - self.limit)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
        }
    }

    func formattedTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
