import Charts
import SwiftUI

struct AppInspectorSheet: View {
    @ObservedObject var vm: AppViewModel
    let app: AppItem
    @Environment(\.dismiss) private var dismiss

    @State private var subProcesses: [SubProcessItem] = []
    @State private var isLoading = true

    var body: some View {
        let history = vm.appMemoryHistory[app.id] ?? []

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(app.name) — Memory & Sub-Process Inspector")
                        .font(.headline)
                    Text("PID \(app.pid) · Total RAM: \(formatBytes(app.rssBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    loadSubProcesses()
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            GroupBox("Recent RAM History (MB)") {
                if history.count >= 2 {
                    Chart(history) { pt in
                        AreaMark(
                            x: .value("Time", pt.timestamp),
                            y: .value("MB", pt.rssMB)
                        )
                        .foregroundStyle(Color.blue.opacity(0.25))
                        LineMark(
                            x: .value("Time", pt.timestamp),
                            y: .value("MB", pt.rssMB)
                        )
                        .foregroundStyle(Color.blue)
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 110)
                    .padding(4)
                } else {
                    Text("Collecting samples for \(app.name)... (updates on refresh)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }

            GroupBox("Child & Helper Processes (\(subProcesses.count))") {
                if isLoading {
                    ProgressView("Inspecting process tree...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(subProcesses) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(sub.name).fontWeight(.medium)
                                    Text("PID \(sub.pid)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if sub.pid == app.pid {
                                        Text("Main")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.18), in: Capsule())
                                            .foregroundStyle(.blue)
                                    }
                                }
                                Text(sub.command)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(formatBytes(sub.rssBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if sub.pid != app.pid {
                                Button("Kill", role: .destructive) {
                                    kill(sub.pid, SIGTERM)
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(400))
                                        loadSubProcesses()
                                        vm.refresh()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            loadSubProcesses()
        }
    }

    private func loadSubProcesses() {
        isLoading = true
        let rootPID = app.pid
        Task.detached(priority: .userInitiated) {
            let list = SystemMonitor.fetchSubProcesses(rootPID: rootPID)
            await MainActor.run {
                self.subProcesses = list
                self.isLoading = false
            }
        }
    }
}
