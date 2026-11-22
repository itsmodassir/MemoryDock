import AppKit
import SwiftUI

struct DeviceProfileView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let info = vm.deviceProfile {
                    GroupBox {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 56, height: 56)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(info.fullName)
                                    .font(.title2.bold())
                                Text("@\(info.username) · \(info.computerName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Label("iCloud / Apple ID: \(info.appleID)", systemImage: "icloud.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            Spacer()
                            Button("Refresh Info") {
                                vm.refreshDeviceProfile()
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("Hardware & Device Identifiers") {
                        VStack(spacing: 8) {
                            infoRow("Model Name", info.modelName)
                            Divider()
                            infoRow("Model Identifier", info.modelIdentifier)
                            Divider()
                            infoRow("Chip / Processor", info.chip)
                            Divider()
                            infoRow("Memory (RAM)", info.totalRAM)
                            Divider()
                            infoRow("Serial Number", info.serialNumber)
                            Divider()
                            infoRow("Hardware UUID", info.hardwareUUID)
                        }
                        .padding(6)
                    }

                    GroupBox("macOS, Kernel & Power") {
                        VStack(spacing: 8) {
                            infoRow("macOS Version", "macOS \(info.macOSVersion) (Build \(info.macOSBuild))")
                            Divider()
                            infoRow("Kernel", info.kernelVersion)
                            Divider()
                            infoRow("System Uptime", info.uptimeText)
                            Divider()
                            infoRow("Battery / Power", info.batteryStatus)
                        }
                        .padding(6)
                    }

                    GroupBox("Connected Network & Drives") {
                        VStack(spacing: 8) {
                            infoRow("Wi-Fi Network", info.wifiName)
                            Divider()
                            infoRow("Local IP Address", info.localIP)
                            Divider()
                            infoRow("Mounted Volumes", "\(vm.volumes.count) (\(vm.volumes.filter(\.isExternal).count) external / Wi-Fi)")
                            Divider()
                            infoRow("Cloud Drives", "\(vm.cloudMounts.count) local · \(vm.s3Configs.count) S3/R2")
                        }
                        .padding(6)
                    }

                    GroupBox("macOS Software Update") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button(vm.isCheckingUpdates ? "Checking..." : "Check for macOS Updates") {
                                    vm.checkSoftwareUpdates()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(vm.isCheckingUpdates)

                                Button("Open Software Update Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                Spacer()
                            }
                            if let updateOut = vm.softwareUpdateOutput {
                                Text(updateOut)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(6)
                    }
                } else {
                    ProgressView("Loading device profile...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
        }
        .onAppear {
            if vm.deviceProfile == nil {
                vm.refreshDeviceProfile()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}
