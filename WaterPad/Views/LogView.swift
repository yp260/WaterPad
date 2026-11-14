import SwiftUI

struct LogView: View {
    @EnvironmentObject private var log: LogStore
    @Environment(\.dismiss) private var dismiss

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
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { log.clear() }
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
