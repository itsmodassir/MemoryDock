import AppKit
import Foundation

struct ExternalDiskTarget: Identifiable, Hashable, Sendable {
    let id: String // e.g. "disk4"
    let deviceIdentifier: String
    let displayName: String
    let sizeText: String

    var devicePath: String { "/dev/\(deviceIdentifier)" }
    var rawDevicePath: String { "/dev/r\(deviceIdentifier)" }
}

enum DiskFormatOption: String, CaseIterable, Identifiable, Sendable {
    case apfs = "APFS"
    case jhfsPlus = "Mac OS Extended (JHFS+)"
    case exfat = "ExFAT"
    case fat32 = "MS-DOS (FAT32)"

    var id: String { rawValue }

    var diskutilFormat: String {
        switch self {
        case .apfs: return "APFS"
        case .jhfsPlus: return "JHFS+"
        case .exfat: return "ExFAT"
        case .fat32: return "FAT32"
        }
    }
}

enum BootableOSType: String, CaseIterable, Identifiable, Sendable {
    case macOS = "macOS"
    case linux = "Linux"
    case windows = "Windows"

    var id: String { rawValue }

    var sourceHint: String {
        switch self {
        case .macOS: return "Select Install macOS *.app"
        case .linux: return "Select Linux .iso image"
        case .windows: return "Select Windows 10/11 .iso image"
        }
    }
}

enum BootableUSBManager {
    static func listExternalPhysicalDisks() -> [ExternalDiskTarget] {
        let out = SystemMonitor.runShell("/usr/sbin/diskutil list external physical")
        var diskIDs: [String] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("/dev/disk") {
                let first = s.split(separator: " ").first.map(String.init) ?? ""
                let id = first.replacingOccurrences(of: "/dev/", with: "")
                if !id.isEmpty && !diskIDs.contains(id) {
                    diskIDs.append(id)
                }
            }
        }

        return diskIDs.map { id in
            let info = SystemMonitor.runShell("/usr/sbin/diskutil info /dev/\(id)")
            var mediaName = "External Disk"
            var sizeText = ""
            for line in info.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Device / Media Name:") {
                    mediaName = trimmed.replacingOccurrences(of: "Device / Media Name:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Disk Size:") {
                    sizeText = trimmed.replacingOccurrences(of: "Disk Size:", with: "")
                        .components(separatedBy: "(").first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                }
            }
            return ExternalDiskTarget(
                id: id,
                deviceIdentifier: id,
                displayName: "\(mediaName) (\(id))",
                sizeText: sizeText
            )
        }
    }

    static func runningAppsOnDisk(deviceIdentifier: String) -> [String] {
        let listOut = SystemMonitor.runShell("/usr/sbin/diskutil list /dev/\(deviceIdentifier)")
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var blocking: [String] = []
        for url in vols {
            let info = SystemMonitor.runShell("/usr/sbin/diskutil info \"\(url.path)\"")
            if info.contains("Part of Whole:             \(deviceIdentifier)") || listOut.contains(url.lastPathComponent) {
                blocking.append(contentsOf: DiskManager.runningAppsOnVolume(mountPath: url.path))
            }
        }
        return Array(Set(blocking))
    }

    static func formatVolume(mountPath: String, format: DiskFormatOption, newName: String) -> String {
        let blocking = DiskManager.runningAppsOnVolume(mountPath: mountPath)
        if !blocking.isEmpty {
            return "Blocked: quit \(blocking.joined(separator: ", ")) running on this volume first."
        }
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let escMount = mountPath.replacingOccurrences(of: "\"", with: "\\\"")
        let escName = cleanName.replacingOccurrences(of: "\"", with: "\\\"")
        let out = SystemMonitor.runShell("/usr/sbin/diskutil eraseVolume \(format.diskutilFormat) \"\(escName)\" \"\(escMount)\" 2>&1")
        return out.isEmpty ? "Formatted \(cleanName) (\(format.rawValue))" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatWholeDisk(disk: ExternalDiskTarget, format: DiskFormatOption, newName: String) -> String {
        let blocking = runningAppsOnDisk(deviceIdentifier: disk.deviceIdentifier)
        if !blocking.isEmpty {
            return "Blocked: quit \(blocking.joined(separator: ", ")) running on \(disk.deviceIdentifier) first."
        }
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "USB_DRIVE" : newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let escName = cleanName.replacingOccurrences(of: "\"", with: "\\\"")
        let scheme = (format == .fat32 || format == .exfat) ? "MBRFormat" : "GPT"
        let out = SystemMonitor.runShell("/usr/sbin/diskutil eraseDisk \(format.diskutilFormat) \"\(escName)\" \(scheme) \(disk.devicePath) 2>&1")
        return out.isEmpty ? "Erased \(disk.deviceIdentifier) as \(format.rawValue)" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func createBootableUSB(
        osType: BootableOSType,
        sourcePath: String,
        targetDisk: ExternalDiskTarget
    ) -> String {
        let blocking = runningAppsOnDisk(deviceIdentifier: targetDisk.deviceIdentifier)
        if !blocking.isEmpty {
            return "Blocked: quit \(blocking.joined(separator: ", ")) running on \(targetDisk.deviceIdentifier) first."
        }

        let escSrc = sourcePath.replacingOccurrences(of: "\"", with: "\\\"")
        switch osType {
        case .macOS:
            let tool = "\(sourcePath)/Contents/Resources/createinstallmedia"
            guard FileManager.default.isExecutableFile(atPath: tool) else {
                return "Invalid macOS installer app (createinstallmedia not found)."
            }
            let escTool = tool.replacingOccurrences(of: "\"", with: "\\\"")
            let cmd = "/usr/sbin/diskutil eraseDisk JHFS+ USB_INSTALL GPT \(targetDisk.devicePath) && \"\(escTool)\" --volume /Volumes/USB_INSTALL --nointeraction"
            return runAdminShell(cmd)

        case .linux:
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                return "Selected Linux ISO file not found."
            }
            let cmd = "/usr/sbin/diskutil unmountDisk \(targetDisk.devicePath) && /bin/dd if=\"\(escSrc)\" of=\(targetDisk.rawDevicePath) bs=4m && /usr/sbin/diskutil eject \(targetDisk.devicePath)"
            return runAdminShell(cmd)

        case .windows:
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                return "Selected Windows ISO file not found."
            }
            let script = """
            /usr/sbin/diskutil eraseDisk ExFAT WIN_USB MBRFormat \(targetDisk.devicePath) && \
            MNT=$(/usr/bin/hdiutil attach -nobrowse -readonly "\(escSrc)" | awk '/\\/Volumes\\//{for(i=3;i<=NF;i++) printf "%s%s", $i, (i==NF?"":" ")}') && \
            /bin/cp -R "$MNT"/* /Volumes/WIN_USB/ && \
            /usr/bin/hdiutil detach "$MNT" && \
            /usr/sbin/diskutil eject \(targetDisk.devicePath)
            """
            return SystemMonitor.runShell(script + " 2>&1")
        }
    }

    private static func runAdminShell(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus == 0 {
                return out.isEmpty ? "Bootable USB created successfully!" : out
            }
            return out.isEmpty ? "Operation cancelled or failed." : out
        } catch {
            return "Failed to launch privileged command: \(error.localizedDescription)"
        }
    }
}
