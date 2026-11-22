import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiskToolsView: View {
    @ObservedObject var vm: AppViewModel

    // Format Volume state
    @State private var selectedVolumePath: String = ""
    @State private var formatChoice: DiskFormatOption = .apfs
    @State private var formatVolumeName: String = "ExternalUSB"
    @State private var confirmFormatVolume: VolumeItem? = nil

    // Bootable USB state
    @State private var selectedOS: BootableOSType = .linux
    @State private var isoOrAppPath: String = ""
    @State private var selectedDiskID: String = ""
    @State private var confirmBootableDisk: ExternalDiskTarget? = nil

    var body: some View {
        let externalVolumes = vm.volumes.filter { $0.isExternal && !$0.isNetwork }

        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Format External Volume (APFS / JHFS+ / ExFAT / FAT32)") {
                VStack(alignment: .leading, spacing: 10) {
                    if externalVolumes.isEmpty {
                        Text("Plug in an external USB drive to format a volume.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Picker("Volume", selection: $selectedVolumePath) {
                                ForEach(externalVolumes) { vol in
                                    Text("\(vol.name) (\(formatBytes(vol.totalBytes)))").tag(vol.mountPath)
                                }
                            }
                            .onAppear {
                                if selectedVolumePath.isEmpty, let first = externalVolumes.first {
                                    selectedVolumePath = first.mountPath
                                }
                            }

                            Picker("Format", selection: $formatChoice) {
                                ForEach(DiskFormatOption.allCases) { opt in
                                    Text(opt.rawValue).tag(opt)
                                }
                            }
                            .frame(width: 210)

                            TextField("New Volume Name", text: $formatVolumeName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)

                            Button("Format Volume", role: .destructive) {
                                confirmFormatVolume = externalVolumes.first { $0.mountPath == selectedVolumePath }
                            }
                            .disabled(vm.isDiskToolBusy || selectedVolumePath.isEmpty)
                            .help("Erases and formats ONLY the selected external volume (asks for confirmation first).")
                        }
                    }
                    if let msg = vm.diskToolMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            GroupBox("Create Bootable USB / Pendrive (macOS · Linux · Windows)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("OS", selection: $selectedOS) {
                            ForEach(BootableOSType.allCases) { os in
                                Text(os.rawValue).tag(os)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .onChange(of: selectedOS) { _, _ in
                            isoOrAppPath = ""
                        }

                        Spacer()

                        Button("Refresh USB Disks") {
                            vm.refreshExternalPhysicalDisks()
                        }
                    }

                    HStack(spacing: 8) {
                        TextField(selectedOS.sourceHint, text: $isoOrAppPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            pickBootSource()
                        }
                    }

                    HStack(spacing: 8) {
                        if vm.externalPhysicalDisks.isEmpty {
                            Text("No external physical USB disks found.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Target USB", selection: $selectedDiskID) {
                                ForEach(vm.externalPhysicalDisks) { d in
                                    Text("\(d.displayName) — \(d.sizeText)").tag(d.id)
                                }
                            }
                            .onAppear {
                                if selectedDiskID.isEmpty, let first = vm.externalPhysicalDisks.first {
                                    selectedDiskID = first.id
                                }
                            }
                        }

                        Spacer()

                        Button(vm.isDiskToolBusy ? "Working..." : "Create Bootable USB", role: .destructive) {
                            confirmBootableDisk = vm.externalPhysicalDisks.first { $0.id == selectedDiskID }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(vm.isDiskToolBusy || isoOrAppPath.isEmpty || selectedDiskID.isEmpty)
                        .help("Erases the selected external USB drive and writes the macOS, Linux, or Windows installer onto it.")
                    }
                }
                .padding(6)
            }
        }
        .onAppear {
            vm.refreshExternalPhysicalDisks()
        }
        .alert(
            "Erase & Format Volume?",
            isPresented: Binding(
                get: { confirmFormatVolume != nil },
                set: { if !$0 { confirmFormatVolume = nil } }
            ),
            presenting: confirmFormatVolume
        ) { vol in
            Button("Cancel", role: .cancel) { confirmFormatVolume = nil }
            Button("Erase & Format", role: .destructive) {
                vm.formatExternalVolume(vol, format: formatChoice, newName: formatVolumeName)
                confirmFormatVolume = nil
            }
        } message: { vol in
            Text("ALL DATA on \"\(vol.name)\" (\(vol.mountPath)) will be permanently erased and formatted as \(formatChoice.rawValue).")
        }
        .alert(
            "Erase Whole USB & Write \(selectedOS.rawValue) Installer?",
            isPresented: Binding(
                get: { confirmBootableDisk != nil },
                set: { if !$0 { confirmBootableDisk = nil } }
            ),
            presenting: confirmBootableDisk
        ) { disk in
            Button("Cancel", role: .cancel) { confirmBootableDisk = nil }
            Button("Erase & Create Bootable USB", role: .destructive) {
                vm.createBootableUSB(osType: selectedOS, sourcePath: isoOrAppPath, disk: disk)
                confirmBootableDisk = nil
            }
        } message: { disk in
            Text("ALL PARTITIONS and DATA on \(disk.displayName) (\(disk.sizeText)) will be completely erased to create a bootable \(selectedOS.rawValue) USB.")
        }
    }

    private func pickBootSource() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if selectedOS == .macOS {
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        } else {
            panel.canChooseFiles = true
            panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        }
        if panel.runModal() == .OK, let url = panel.url {
            isoOrAppPath = url.path
        }
    }
}
