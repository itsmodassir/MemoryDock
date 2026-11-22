import AppKit
import SwiftUI

enum AppLocationFilter: String, CaseIterable, Identifiable {
    case all = "All Locations"
    case internalSSD = "Internal SSD"
    case external = "External Drives"
    case disconnected = "Disconnected"

    var id: String { rawValue }
}

enum AppCategory: String, CaseIterable, Identifiable {
    case developer = "Developer & IDEs"
    case browsers = "Browsers"
    case ai = "AI & Assistants"
    case productivity = "Productivity & Media"
    case utilities = "Utilities"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .developer: return "hammer.fill"
        case .browsers: return "globe"
        case .ai: return "sparkles"
        case .productivity: return "doc.richtext.fill"
        case .utilities: return "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .developer: return .blue
        case .browsers: return .purple
        case .ai: return .teal
        case .productivity: return .orange
        case .utilities: return .gray
        }
    }

    static func classify(appName: String) -> AppCategory {
        let lower = appName.lowercased()
        if lower.contains("xcode") || lower.contains("android studio") || lower.contains("docker")
            || lower.contains("developer") || lower.contains("vscode") || lower.contains("visual studio")
            || lower.contains("cursor") || lower.contains("terminal") || lower.contains("iterm")
            || lower.contains("postman") || lower.contains("git") {
            return .developer
        }
        if lower.contains("chrome") || lower.contains("safari") || lower.contains("brave")
            || lower.contains("firefox") || lower.contains("arc") || lower.contains("edge") {
            return .browsers
        }
        if lower.contains("chatgpt") || lower.contains("claude") || lower.contains("antigravity")
            || lower.contains("ollama") || lower.contains("lm studio") {
            return .ai
        }
        if lower.contains("keynote") || lower.contains("pages") || lower.contains("numbers")
            || lower.contains("recordly") || lower.contains("mkplayer") || lower.contains("vlc")
            || lower.contains("notion") || lower.contains("slack") || lower.contains("zoom") {
            return .productivity
        }
        return .utilities
    }
}

struct ApplicationsView: View {
    @ObservedObject var vm: AppViewModel
    let searchText: String

    @State private var locationFilter: AppLocationFilter = .all
    @State private var selectedCategory: AppCategory? = nil

    var body: some View {
        let writableExternalVolumes = vm.volumes.filter { $0.isExternal && $0.isWritable }

        let internalApps = vm.diskApps.filter { !$0.isExternal }
        let externalApps = vm.diskApps.filter { $0.isExternal && $0.isMounted }
        let disconnectedApps = vm.diskApps.filter { $0.isExternal && !$0.isMounted }

        let filtered = vm.diskApps.filter { app in
            let matchesLoc: Bool
            switch locationFilter {
            case .all: matchesLoc = true
            case .internalSSD: matchesLoc = !app.isExternal
            case .external: matchesLoc = app.isExternal && app.isMounted
            case .disconnected: matchesLoc = app.isExternal && !app.isMounted
            }
            let cat = AppCategory.classify(appName: app.name)
            let matchesCat = selectedCategory == nil || cat == selectedCategory
            let matchesSearch = searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
            return matchesLoc && matchesCat && matchesSearch
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let prog = vm.moveProgress {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.blue)
                                Text("Moving \(prog.appName) → \(prog.targetVolumeName)")
                                    .fontWeight(.semibold)
                                Text("(\(prog.phase))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(prog.fraction * 100))%")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            ProgressView(value: prog.fraction).tint(.blue)
                            HStack {
                                Text("\(formatBytes(prog.copiedBytes)) / \(formatBytes(prog.totalBytes))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f MB/s", prog.speedBytesPerSec / 1_048_576.0))
                                    .font(.caption.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(6)
                    }
                }

                // Location Summary Cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    locationCard(.all, count: vm.diskApps.count, bytes: vm.diskApps.reduce(0) { $0 + $1.sizeBytes }, color: .blue)
                    locationCard(.internalSSD, count: internalApps.count, bytes: internalApps.reduce(0) { $0 + $1.sizeBytes }, color: .orange)
                    locationCard(.external, count: externalApps.count, bytes: externalApps.reduce(0) { $0 + $1.sizeBytes }, color: .green)
                    if !disconnectedApps.isEmpty {
                        locationCard(.disconnected, count: disconnectedApps.count, bytes: 0, color: .red)
                    }
                }

                // Category Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedCategory = nil
                        } label: {
                            Text("All Categories")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedCategory == nil ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(selectedCategory == nil ? .white : .primary)
                        }
                        .buttonStyle(.plain)

                        ForEach(AppCategory.allCases) { cat in
                            let count = vm.diskApps.filter { AppCategory.classify(appName: $0.name) == cat }.count
                            let isSelected = selectedCategory == cat
                            Button {
                                selectedCategory = isSelected ? nil : cat
                            } label: {
                                Label("\(cat.rawValue) (\(count))", systemImage: cat.icon)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? cat.color : Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(isSelected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                GroupBox {
                    VStack(spacing: 8) {
                        HStack {
                            Text("\(selectedCategory?.rawValue ?? locationFilter.rawValue) (\(filtered.count))")
                                .font(.headline)
                            Spacer()
                            if vm.isDiskRefreshing {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(.bottom, 4)

                        Divider()

                        if vm.isDiskRefreshing && filtered.isEmpty {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Scanning /Applications...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        } else if filtered.isEmpty {
                            Text("No applications match this filter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(filtered) { app in
                                    let cat = AppCategory.classify(appName: app.name)
                                    HStack(spacing: 10) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                            .resizable()
                                            .frame(width: 30, height: 30)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(app.name).fontWeight(.medium)
                                                Text(cat.rawValue)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(cat.color.opacity(0.16), in: Capsule())
                                                    .foregroundStyle(cat.color)
                                                Text(app.isExternal && !app.isMounted ? "\(app.volumeLabel) (Disconnected)" : app.volumeLabel)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(
                                                        (app.isExternal ? (app.isMounted ? Color.green : Color.orange) : Color.secondary).opacity(0.18),
                                                        in: Capsule()
                                                    )
                                                    .foregroundStyle(app.isExternal ? (app.isMounted ? .green : .orange) : .secondary)
                                            }
                                            if app.isExternal {
                                                Text(app.resolvedPath)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        Text(formatBytes(app.sizeBytes))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)

                                        Button("Open") {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                                        }
                                        .disabled(app.isExternal && !app.isMounted)

                                        if app.isExternal && app.isMounted {
                                            Button("Move to Internal") {
                                                vm.moveAppBackToInternal(app)
                                            }
                                            .disabled(vm.isMovingApp)
                                        } else if !app.isExternal && !writableExternalVolumes.isEmpty {
                                            Menu("Move to External") {
                                                ForEach(writableExternalVolumes) { vol in
                                                    Button("\(vol.name) (\(formatBytes(vol.availableBytes)) free)") {
                                                        vm.moveAppToExternal(app, targetVolumePath: vol.mountPath)
                                                    }
                                                }
                                            }
                                            .disabled(vm.isMovingApp)
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .padding()
        }
        .onAppear {
            vm.refreshVolumesOnly()
            if vm.diskApps.isEmpty {
                vm.refreshDisk()
            }
        }
    }

    private func locationCard(_ filter: AppLocationFilter, count: Int, bytes: UInt64, color: Color) -> some View {
        let isSelected = locationFilter == filter
        return Button {
            locationFilter = filter
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count) apps")
                    .font(.title3.bold())
                    .foregroundStyle(color)
                Text(bytes > 0 ? formatBytes(bytes) : "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                isSelected ? color.opacity(0.16) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
