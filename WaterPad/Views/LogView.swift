import SwiftUI
import UIKit

struct LogView: View {
    @EnvironmentObject private var log: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(log.lines.reversed())) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(log.formattedTime(line.time))
                                .font(.caption2.monospacedDigit())
                            Text("[\(line.level.rawValue)]")
                                .font(.caption2)
                                .foregroundColor(color(for: line.level))
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        Text(line.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if log.lines.isEmpty {
                    Text("暂无日志")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("连接日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        Button(copied ? "已复制" : "复制全部") { copyAll() }
                        Button("清空") { log.clear() }
                    }
                }
            }
        }
    }

    /// 一键把全部日志放进剪贴板，真机排查时直接粘贴出来定位，不用逐条截图。
    private func copyAll() {
        let text = log.lines.map {
            "\(log.formattedTime($0.time)) [\($0.level.rawValue)] \($0.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
