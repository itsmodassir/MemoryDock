import AppKit
import SwiftUI

struct CacheCleanerView: View {
    @ObservedObject var vm: AppViewModel

    @State private var cacheToClear: CacheItem? = nil
    @State private var confirmClearAllSafe = false

    var body: some View {
        let totalBytes = vm.cacheItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let safeBytes = vm.cacheItems.filter(\.isSafe).reduce(UInt64(0)) { $0 + $1.sizeBytes }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Cache Detected: \(formatBytes(totalBytes))")
                                .font(.title3.bold())
                            Text("Safe one-click cleanable: \(formatBytes(safeBytes)) (excludes Trash & Local AI Models)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            vm.scanCaches()
                        } label: {
                            Label(vm.isScanningCaches ? "Scanning..." : "Rescan", systemImage: "arrow.clockwise")
                        }
                        .disabled(vm.isScanningCaches || vm.isClearingCache)

                        Button {
                            confirmClearAllSafe = true
                        } label: {
                            Label("Clean All Safe Caches", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(vm.isClearingCache || safeBytes == 0)
                        .help("Clears all caches marked Safe (excludes Trash and Local AI Models) after confirmation.")
                    }
                    .padding(6)
                }

                if vm.isScanningCaches && vm.cacheItems.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning macOS, Developer & AI caches...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                } else {
                    ForEach(vm.cacheItems) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(.headline)
                                            Text(item.category)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.quaternary, in: Capsule())
                                            Text(item.isSafe ? "Safe" : "Caution")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    (item.isSafe ? Color.green : Color.orange).opacity(0.18),
                                                    in: Capsule()
                                                )
                                                .foregroundStyle(item.isSafe ? .green : .orange)
                                        }
                                        Text(item.paths.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(formatBytes(item.sizeBytes))
                                        .font(.title3.bold())
                                        .monospacedDigit()

                                    if let firstPath = item.paths.first {
                                        Button("Reveal") {
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: firstPath)
                                        }
                                    }

                                    Button("Clear", role: .destructive) {
                                        cacheToClear = item
                                    }
                                    .disabled(vm.isClearingCache || item.sizeBytes == 0)
                                    .help(item.impactDescription)
                                }

                                Text("What happens if cleared: \(item.impactDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(4)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            if vm.cacheItems.isEmpty {
                vm.scanCaches()
            }
        }
        .alert(
            "Clear \(cacheToClear?.name ?? "Cache")?",
            isPresented: Binding(
                get: { cacheToClear != nil },
                set: { if !$0 { cacheToClear = nil } }
            ),
            presenting: cacheToClear
        ) { item in
            Button("Cancel", role: .cancel) { cacheToClear = nil }
            Button("Clear (\(formatBytes(item.sizeBytes)))", role: .destructive) {
                vm.clearCache(item)
                cacheToClear = nil
            }
        } message: { item in
            Text("\(item.impactDescription)\n\nPath: \(item.paths.joined(separator: ", "))")
        }
        .alert("Clean All Safe Caches?", isPresented: $confirmClearAllSafe) {
            Button("Cancel", role: .cancel) {}
            Button("Clean All Safe (\(formatBytes(safeBytes)))", role: .destructive) {
                vm.clearAllSafeCaches()
            }
        } message: {
            Text("This will clear all caches marked 'Safe' (~ \(formatBytes(safeBytes))). Trash and Local AI Models will NOT be touched.")
        }
    }
}
