import AppKit
import ServiceManagement
import SwiftUI

@main
struct MemoryDockApp: App {
    @StateObject private var vm = AppViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MemoryDock Dashboard", id: "dashboard") {
            DashboardView(vm: vm)
        }
        .defaultSize(width: 860, height: 580)

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("RAM: \(formatBytes(vm.snapshot.usedBytes)) / \(formatBytes(vm.snapshot.totalBytes))")
                    .font(.headline)
                Text("Compressed: \(formatBytes(vm.snapshot.compressedBytes)) · Free/Reclaimable: \(formatBytes(vm.snapshot.freeBytes + vm.snapshot.inactiveBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                }

                Button {
                    vm.runLowRamMode()
                } label: {
                    Label("Free RAM Now (Low RAM Mode)", systemImage: "bolt.fill")
                }

                Divider()

                Text("Quick Turn Off (Top Apps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(vm.apps.filter { !$0.isProtected }.prefix(4)) { app in
                    Button("Quit \(app.name) (\(formatBytes(app.rssBytes)))") {
                        vm.quitApp(app)
                    }
                }

                Divider()

                Button("Refresh Now") {
                    vm.refresh()
                }
                Button(SMAppService.mainApp.status == .enabled ? "Disable Launch at Login" : "Enable Launch at Login") {
                    if SMAppService.mainApp.status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    } else {
                        try? SMAppService.mainApp.register()
                    }
                }
                Button("Quit MemoryDock") {
                    vm.unfreezeAllApps()
                    NSApp.terminate(nil)
                }
            }
            .padding(8)
            .frame(width: 280)
        } label: {
            Label(menuBarTitle, systemImage: "memorychip")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarTitle: String {
        guard vm.snapshot.totalBytes > 0 else { return "RAM" }
        let usedGB = Double(vm.snapshot.usedBytes) / 1_073_741_824.0
        let totalGB = Double(vm.snapshot.totalBytes) / 1_073_741_824.0
        return String(format: "%.1f/%.0f GB", usedGB, totalGB)
    }
}
