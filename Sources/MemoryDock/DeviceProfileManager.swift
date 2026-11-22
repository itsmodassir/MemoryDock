import Foundation

struct DeviceProfileInfo: Sendable {
    let fullName: String
    let username: String
    let computerName: String
    let appleID: String
    let modelName: String
    let modelIdentifier: String
    let chip: String
    let totalRAM: String
    let serialNumber: String
    let hardwareUUID: String
    let macOSVersion: String
    let macOSBuild: String
    let kernelVersion: String
    let uptimeText: String
    let localIP: String
    let wifiName: String
    let batteryStatus: String
}

enum DeviceProfileManager {
    static func fetchProfile() -> DeviceProfileInfo {
        let fullName = NSFullUserName()
        let username = NSUserName()
        let computerName = Host.current().localizedName ?? "Mac"

        // Apple ID / iCloud email from MobileMeAccounts
        let icloudOut = SystemMonitor.runShell("/usr/bin/defaults read MobileMeAccounts Accounts 2>/dev/null | grep -m1 'AccountID' | awk -F'\"' '{print $2}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appleID = icloudOut.isEmpty ? "Not signed in / Restricted" : icloudOut

        // Hardware info via system_profiler
        let hwOut = SystemMonitor.runShell("/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null")
        var modelName = "Mac"
        var modelID = ""
        var chip = ""
        var totalRAM = ""
        var serial = ""
        var hwUUID = ""
        for line in hwOut.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Model Name:") {
                modelName = trimmed.replacingOccurrences(of: "Model Name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Model Identifier:") {
                modelID = trimmed.replacingOccurrences(of: "Model Identifier:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Chip:") {
                chip = trimmed.replacingOccurrences(of: "Chip:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Processor Name:") && chip.isEmpty {
                chip = trimmed.replacingOccurrences(of: "Processor Name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Memory:") {
                totalRAM = trimmed.replacingOccurrences(of: "Memory:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Serial Number (system):") {
                serial = trimmed.replacingOccurrences(of: "Serial Number (system):", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Hardware UUID:") {
                hwUUID = trimmed.replacingOccurrences(of: "Hardware UUID:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        let osVer = SystemMonitor.runShell("/usr/bin/sw_vers -productVersion").trimmingCharacters(in: .whitespacesAndNewlines)
        let osBuild = SystemMonitor.runShell("/usr/bin/sw_vers -buildVersion").trimmingCharacters(in: .whitespacesAndNewlines)
        let kernel = SystemMonitor.runShell("/usr/bin/uname -sr").trimmingCharacters(in: .whitespacesAndNewlines)
        let uptime = SystemMonitor.runShell("/usr/bin/uptime | sed 's/.*up //' | sed 's/, [0-9]* user.*//'").trimmingCharacters(in: .whitespacesAndNewlines)
        let localIP = RemoteHostServer.localIPAddress() ?? "Offline"

        let wifiOut = SystemMonitor.runShell("/usr/sbin/networksetup -getairportnetwork en0 2>/dev/null")
            .replacingOccurrences(of: "Current Wi-Fi Network:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wifiName = wifiOut.isEmpty || wifiOut.contains("not associated") ? "Not connected" : wifiOut

        let battOut = SystemMonitor.runShell("/usr/bin/pmset -g batt 2>/dev/null | tail -n 1")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return DeviceProfileInfo(
            fullName: fullName,
            username: username,
            computerName: computerName,
            appleID: appleID,
            modelName: modelName,
            modelIdentifier: modelID,
            chip: chip,
            totalRAM: totalRAM,
            serialNumber: serial,
            hardwareUUID: hwUUID,
            macOSVersion: osVer,
            macOSBuild: osBuild,
            kernelVersion: kernel,
            uptimeText: uptime,
            localIP: localIP,
            wifiName: wifiName,
            batteryStatus: battOut.isEmpty ? "Desktop / AC Power" : battOut
        )
    }

    static func checkSoftwareUpdates() -> String {
        let out = SystemMonitor.runShell("/usr/sbin/softwareupdate -l 2>&1")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No new macOS updates found." : trimmed
    }
}
