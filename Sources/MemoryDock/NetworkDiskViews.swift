import AppKit
import SwiftUI

struct NetworkDiskSectionView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var discovery: NetworkDiscovery
    @Binding var smbAddress: String
    @Binding var smbUsername: String
    @Binding var smbPassword: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("smb://192.168.1.1/share or smb://MyPC.local/Shared", text: $smbAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Username (optional)", text: $smbUsername)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                SecureField("Password", text: $smbPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button(vm.isMountingShare ? "Connecting..." : "Connect") {
                    vm.connectNetworkDisk(address: smbAddress, username: smbUsername, password: smbPassword)
                }
                .buttonStyle(.borderedProminent)
                .disabled(smbAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isMountingShare)
            }

            HStack {
                Button {
                    if discovery.isScanning {
                        discovery.stopScan()
                    } else {
                        discovery.startScan()
                    }
                } label: {
                    Label(discovery.isScanning ? "Scanning Wi-Fi..." : "Scan Wi-Fi Devices", systemImage: "wifi")
                }

                if discovery.isScanning {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Text("Discovered SMB / AFP shares on your Wi-Fi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !discovery.hosts.isEmpty {
                Divider()
                ForEach(discovery.hosts) { host in
                    HStack {
                        Image(systemName: "wifi.circle.fill")
                            .foregroundStyle(.purple)
                        Text(host.name)
                            .fontWeight(.medium)
                        Text(host.protocolLabel)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Text(host.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Address") {
                            smbAddress = host.address
                        }
                        Button("Connect") {
                            smbAddress = host.address
                            vm.connectNetworkDisk(address: host.address, username: smbUsername, password: smbPassword)
                        }
                    }
                }
            }
        }
        .padding(6)
    }
}

struct VolumeBrowserSheet: View {
    @ObservedObject var vm: AppViewModel
    let volume: VolumeItem
    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String = ""
    @State private var entries: [RemoteEntry] = []
    @State private var entryToDelete: RemoteEntry? = nil
    @State private var newFolderName: String = ""
    @State private var showNewFolderAlert = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: volume.isNetwork ? "wifi" : "externaldrive.fill")
                            .foregroundStyle(volume.isNetwork ? .purple : .blue)
                        Text(volume.name).font(.headline)
                        if !volume.isWritable {
                            Text("Read-Only").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text(currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if currentPath != volume.mountPath {
                    Button("Up") {
                        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
                        load(path: parent.hasPrefix(volume.mountPath) ? parent : volume.mountPath)
                    }
                }

                if volume.isWritable {
                    Button("New Folder") {
                        newFolderName = ""
                        showNewFolderAlert = true
                    }
                    Button("Upload Files") {
                        pickAndUploadFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isMovingApp)
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let prog = vm.moveProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(prog.appName) (\(prog.phase))")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(prog.fraction * 100))% · \(String(format: "%.1f MB/s", prog.speedBytesPerSec / 1_048_576.0))")
                            .font(.caption.bold())
                            .monospacedDigit()
                    }
                    ProgressView(value: prog.fraction)
                }
            }

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Folder is Empty",
                    systemImage: "folder",
                    description: Text(volume.isWritable ? "Use Upload Files to copy files onto this disk." : "This volume is mounted read-only.")
                )
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                        Text(entry.name)
                            .lineLimit(1)
                        Spacer()
                        if !entry.isDirectory {
                            Text(formatBytes(entry.sizeBytes))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if entry.isDirectory {
                            Button("Open") {
                                load(path: entry.path)
                            }
                        } else {
                            Button("Open") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                            }
                        }
                        Button("Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        }
                        if volume.isWritable {
                            Button(role: .destructive) {
                                entryToDelete = entry
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            load(path: volume.mountPath)
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let target = "\(currentPath)/\(name)"
                try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                load(path: currentPath)
            }
        }
        .alert(
            "Delete Permanently?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            presenting: entryToDelete
        ) { entry in
            Button("Cancel", role: .cancel) { entryToDelete = nil }
            Button("Delete Permanently", role: .destructive) {
                try? FileManager.default.removeItem(atPath: entry.path)
                entryToDelete = nil
                load(path: currentPath)
                vm.refreshVolumesOnly()
            }
        } message: { entry in
            Text("\"\(entry.name)\" will be permanently deleted from \(volume.name) and cannot be undone.")
        }
    }

    private func load(path: String) {
        currentPath = path
        entries = NetworkDiskManager.listDirectory(at: path)
    }

    private func pickAndUploadFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            vm.uploadFilesToDisk(urls: panel.urls, toDirectory: currentPath) {
                load(path: currentPath)
            }
        }
    }
}

struct DefaultDownloadsDriveView: View {
    @ObservedObject var router: DownloadsRouter
    let writableVolumes: [VolumeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(router.isEnabled && !router.targetVolumePath.isEmpty
                         ? "Active Folder: \(router.targetFolder)"
                         : "Currently using Internal SSD (~/Downloads)")
                        .fontWeight(.medium)
                    Text("Auto-routes completed downloads from Safari, Chrome, Brave, AirDrop, or any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if router.isEnabled && !router.targetVolumePath.isEmpty {
                    Toggle("Auto-Route", isOn: Binding(
                        get: { router.isEnabled },
                        set: { router.toggleAutoRoute($0) }
                    ))
                    .labelsHidden()
                    Button("Reset to Internal") {
                        router.resetToInternal()
                    }
                }
                if !writableVolumes.isEmpty {
                    Menu("Set Default Drive") {
                        ForEach(writableVolumes) { vol in
                            Button("\(vol.name) (\(formatBytes(vol.availableBytes)) free)") {
                                router.setDefaultDrive(vol.mountPath)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Pick an external drive to automatically receive all new completed downloads from Safari, Chrome, Brave, or any app.")
                }
            }
            if let note = router.lastRoutedNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(6)
    }
}
