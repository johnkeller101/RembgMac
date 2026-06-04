import SwiftUI

struct LogWindowView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("rembg Logs")
                    .font(.headline)
                Spacer()
                Text("\(appState.recentLogs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(appState.recentLogs.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: appState.recentLogs.count) {
                    if let last = appState.recentLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }
}
