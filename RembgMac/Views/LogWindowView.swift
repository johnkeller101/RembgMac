import SwiftUI

struct LogWindowView: View {
    @ObservedObject var appState: AppState

    var logText: String {
        appState.recentLogs.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("rembg Logs")
                    .font(.headline)
                Spacer()
                Text("\(appState.recentLogs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Clear") {
                    appState.recentLogs.removeAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("log-bottom")
                }
                .onChange(of: appState.recentLogs.count) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }
}
