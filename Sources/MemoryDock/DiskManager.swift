import AppKit
import Foundation

struct VolumeItem: Identifiable, Sendable {
    let id: String
    let name: String
    let mountPath: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let fileSystem: String
    let isExternal: Bool
    let isNetwork: Bool
    let isWritable: Bool

    var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }
}

struct DiskAppItem: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let resolvedPath: String
    let sizeBytes: UInt64
    let isExternal: Bool
    let isMounted: Bool
    let volumeLabel: String
}

struct CleanupFolderItem: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: UInt64
    let canEmptyTrash: Bool
}

struct UserFolderItem: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: UInt64
    let itemCount: Int
}

struct MoveProgress: Sendable {
    let appName: String
    let targetVolumeName: String
    let copiedBytes: UInt64
    let totalBytes: UInt64
    let speedBytesPerSec: Double
    let phase: String

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(copiedBytes) / Double(totalBytes))
    }
}

enum DiskManager {
    static func fetchVolumes() -> [VolumeItem] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var items: [VolumeItem] = []
        for url in urls {
            let path = url.path
            if path.hasPrefix("/System/Volumes") { continue }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = vals.volumeName ?? url.lastPathComponent
            let total = UInt64(vals.volumeTotalCapacity ?? 0)
            let avail = UInt64(vals.volumeAvailableCapacityForImportantUsage ?? Int64(vals.volumeAvailableCapacity ?? 0))
            let isInternal = vals.volumeIsInternal ?? (path == "/")
            let isLocal = vals.volumeIsLocal ?? true
            let isReadOnly = vals.volumeIsReadOnly ?? false
            let fs = vals.volumeLocalizedFormatDescription ?? "Unknown"

            items.append(
                VolumeItem(
                    id: path,
                    name: name,
                    mountPath: path,
                    totalBytes: total,
                    availableBytes: avail,
                    fileSystem: fs,
                    isExternal: !isInternal || !isLocal,
                    isNetwork: !isLocal,
                    isWritable: !isReadOnly
                )
            )
        }

        return items.sorted {
            if $0.mountPath == "/" { return true }
            if $1.mountPath == "/" { return false }
            if $0.isWritable != $1.isWritable { return $0.isWritable && !$1.isWritable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func fetchInstalledApps() -> [DiskAppItem] {
        let fm = FileManager.default
        let appsDir = "/Applications"
        guard let entries = try? fm.contentsOfDirectory(atPath: appsDir) else { return [] }

        let appPaths = entries
            .filter { $0.hasSuffix(".app") }
            .map { "\(appsDir)/\($0)" }

        var items: [DiskAppItem] = []
        for path in appPaths {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            let isExt = resolved.hasPrefix("/Volumes/")
            let volLabel: String
            if isExt {
                let comps = resolved.split(separator: "/")
                volLabel = comps.count >= 2 ? String(comps[1]) : "External"
            } else {
                volLabel = "Internal SSD"
            }

            let isMounted = fm.fileExists(atPath: resolved)
            let sizeOut = isMounted
                ? SystemMonitor.runShell("/usr/bin/du -sk \"\(resolved)\" 2>/dev/null | awk '{print $1}'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : "0"
            let kb = UInt64(sizeOut) ?? 0
            items.append(
                DiskAppItem(
                    id: path,
                    name: url.deletingPathExtension().lastPathComponent,
                    path: path,
                    resolvedPath: resolved,
                    sizeBytes: kb * 1024,
                    isExternal: isExt,
                    isMounted: isMounted,
                    volumeLabel: volLabel
                )
            )
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func fetchCleanupFolders() -> [CleanupFolderItem] {
        let home = NSHomeDirectory()
        let targets: [(name: String, path: String, isTrash: Bool)] = [
            ("Trash", "\(home)/.Trash", true),
            ("User Caches", "\(home)/Library/Caches", false),
            ("Downloads", "\(home)/Downloads", false)
        ]

        return targets.compactMap { target in
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            let sizeOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(target.path)\" 2>/dev/null | awk '{print $1}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let kb = UInt64(sizeOut) ?? 0
            return CleanupFolderItem(
                id: target.path,
                name: target.name,
                path: target.path,
                sizeBytes: kb * 1024,
                canEmptyTrash: target.isTrash
            )
        }
    }

    static func moveAppToExternal(
        app: DiskAppItem,
        targetVolumePath: String,
        onProgress: @Sendable @escaping (MoveProgress) -> Void
    ) async -> String {
        let appFileName = URL(fileURLWithPath: app.path).lastPathComponent
        let targetVolName = URL(fileURLWithPath: targetVolumePath).lastPathComponent
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == appFileName
        }
        if isRunning {
            return "Quit \(app.name) first before moving it."
        }

        let destDir = "\(targetVolumePath)/Applications"
        let destApp = "\(destDir)/\(appFileName)"
        let totalBytes = max(app.sizeBytes, 1)

        onProgress(
            MoveProgress(
                appName: app.name,
                targetVolumeName: targetVolName,
                copiedBytes: 0,
                totalBytes: totalBytes,
                speedBytesPerSec: 0,
                phase: "Copying..."
            )
        )

        let startTime = Date()
        let isUserWritable = FileManager.default.isWritableFile(atPath: app.path)

        let copyTask = Process()
        if isUserWritable {
            copyTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
            copyTask.arguments = ["-c", "mkdir -p \"\(destDir)\" && /bin/cp -a \"\(app.path)\" \"\(destApp)\""]
        } else {
            let script = "mkdir -p \"\(destDir)\" && /bin/cp -a \"\(app.path)\" \"\(destApp)\""
            let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
            copyTask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            copyTask.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        }

        do {
            try copyTask.run()
        } catch {
            return "Failed to start move for \(app.name)."
        }

        while copyTask.isRunning {
            try? await Task.sleep(for: .milliseconds(350))
            let kbOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(destApp)\" 2>/dev/null | awk '{print $1}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let copied = min((UInt64(kbOut) ?? 0) * 1024, totalBytes)
            let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
            let speed = Double(copied) / elapsed

            onProgress(
                MoveProgress(
                    appName: app.name,
                    targetVolumeName: targetVolName,
                    copiedBytes: copied,
                    totalBytes: totalBytes,
                    speedBytesPerSec: speed,
                    phase: "Copying..."
                )
            )
        }

        copyTask.waitUntilExit()
        guard copyTask.terminationStatus == 0 else {
            return "Move cancelled or failed for \(app.name)."
        }

        let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
        onProgress(
            MoveProgress(
                appName: app.name,
                targetVolumeName: targetVolName,
                copiedBytes: totalBytes,
                totalBytes: totalBytes,
                speedBytesPerSec: Double(totalBytes) / elapsed,
                phase: "Linking..."
            )
        )

        let linkCmd = "rm -rf \"\(app.path)\" && ln -s \"\(destApp)\" \"\(app.path)\""
        if isUserWritable {
            SystemMonitor.runShell(linkCmd)
        } else {
            let escaped = linkCmd.replacingOccurrences(of: "\"", with: "\\\"")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            try? task.run()
            task.waitUntilExit()
        }

        return "Moved \(app.name) to \(targetVolName)"
    }

    static func moveAppBackToInternal(
        app: DiskAppItem,
        onProgress: @Sendable @escaping (MoveProgress) -> Void
    ) async -> String {
        guard app.isExternal, app.isMounted else {
            return "\(app.name) drive is not mounted."
        }
        let appFileName = URL(fileURLWithPath: app.path).lastPathComponent
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == appFileName
        }
        if isRunning {
            return "Quit \(app.name) first before moving it back."
        }

        let tempDest = "/Applications/.\(appFileName).tmp"
        let totalBytes = max(app.sizeBytes, 1)
        let startTime = Date()
        let isUserWritable = FileManager.default.isWritableFile(atPath: app.resolvedPath)

        onProgress(
            MoveProgress(
                appName: app.name,
                targetVolumeName: "Internal SSD",
                copiedBytes: 0,
                totalBytes: totalBytes,
                speedBytesPerSec: 0,
                phase: "Copying..."
            )
        )

        let copyTask = Process()
        let copyCmd = "rm -rf \"\(tempDest)\" && /bin/cp -a \"\(app.resolvedPath)\" \"\(tempDest)\""
        if isUserWritable {
            copyTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
            copyTask.arguments = ["-c", copyCmd]
        } else {
            let escaped = copyCmd.replacingOccurrences(of: "\"", with: "\\\"")
            copyTask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            copyTask.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        }

        do {
            try copyTask.run()
        } catch {
            return "Failed to start move back for \(app.name)."
        }

        while copyTask.isRunning {
            try? await Task.sleep(for: .milliseconds(350))
            let kbOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(tempDest)\" 2>/dev/null | awk '{print $1}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let copied = min((UInt64(kbOut) ?? 0) * 1024, totalBytes)
            let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
            onProgress(
                MoveProgress(
                    appName: app.name,
                    targetVolumeName: "Internal SSD",
                    copiedBytes: copied,
                    totalBytes: totalBytes,
                    speedBytesPerSec: Double(copied) / elapsed,
                    phase: "Copying..."
                )
            )
        }

        copyTask.waitUntilExit()
        guard copyTask.terminationStatus == 0 else {
            SystemMonitor.runShell("rm -rf \"\(tempDest)\"")
            return "Move back cancelled or failed for \(app.name)."
        }

        let swapCmd = "rm -f \"\(app.path)\" && mv \"\(tempDest)\" \"\(app.path)\" && rm -rf \"\(app.resolvedPath)\""
        if isUserWritable {
            SystemMonitor.runShell(swapCmd)
        } else {
            let escaped = swapCmd.replacingOccurrences(of: "\"", with: "\\\"")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            try? task.run()
            task.waitUntilExit()
        }

        return "Moved \(app.name) back to Internal SSD"
    }

    static func fetchUserFolders() -> [UserFolderItem] {
        let home = NSHomeDirectory()
        let targets: [(name: String, path: String)] = [
            ("Desktop", "\(home)/Desktop"),
            ("Downloads", "\(home)/Downloads"),
            ("Documents", "\(home)/Documents")
        ]

        return targets.compactMap { target in
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            let sizeOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(target.path)\" 2>/dev/null | awk '{print $1}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let kb = UInt64(sizeOut) ?? 0
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: target.path))?
                .filter { $0 != ".DS_Store" && $0 != ".localized" } ?? []
            return UserFolderItem(
                id: target.path,
                name: target.name,
                path: target.path,
                sizeBytes: kb * 1024,
                itemCount: entries.count
            )
        }
    }

    static func moveUserFolderContents(
        folder: UserFolderItem,
        targetVolumePath: String,
        onProgress: @Sendable @escaping (MoveProgress) -> Void
    ) async -> String {
        let fm = FileManager.default
        let targetVolName = URL(fileURLWithPath: targetVolumePath).lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return "Cannot read \(folder.name) (check Privacy & Security permissions)."
        }

        let itemsToMove = entries.filter { $0 != ".DS_Store" && $0 != ".localized" }
        guard !itemsToMove.isEmpty else {
            return "\(folder.name) is already empty."
        }

        let destFolder = "\(targetVolumePath)/UserData/\(folder.name)"
        try? fm.createDirectory(atPath: destFolder, withIntermediateDirectories: true)

        let totalBytes = max(folder.sizeBytes, 1)
        let startTime = Date()

        onProgress(
            MoveProgress(
                appName: "\(folder.name) (\(itemsToMove.count) items)",
                targetVolumeName: targetVolName,
                copiedBytes: 0,
                totalBytes: totalBytes,
                speedBytesPerSec: 0,
                phase: "Copying..."
            )
        )

        let baseKBOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(destFolder)\" 2>/dev/null | awk '{print $1}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDestBytes = (UInt64(baseKBOut) ?? 0) * 1024

        let copyTask = Process()
        copyTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
        copyTask.arguments = [
            "-c",
            "setopt nullglob dotglob; for f in \"\(folder.path)\"/*; do b=$(basename \"$f\"); [ \"$b\" = \".DS_Store\" ] || [ \"$b\" = \".localized\" ] && continue; /bin/cp -a \"$f\" \"\(destFolder)/\"; done"
        ]

        do {
            try copyTask.run()
        } catch {
            return "Failed to start copy for \(folder.name)."
        }

        while copyTask.isRunning {
            try? await Task.sleep(for: .milliseconds(350))
            let kbOut = SystemMonitor.runShell("/usr/bin/du -sk \"\(destFolder)\" 2>/dev/null | awk '{print $1}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentDestBytes = (UInt64(kbOut) ?? 0) * 1024
            let copied = min(currentDestBytes > baseDestBytes ? currentDestBytes - baseDestBytes : 0, totalBytes)
            let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
            onProgress(
                MoveProgress(
                    appName: "\(folder.name) (\(itemsToMove.count) items)",
                    targetVolumeName: targetVolName,
                    copiedBytes: copied,
                    totalBytes: totalBytes,
                    speedBytesPerSec: Double(copied) / elapsed,
                    phase: "Copying..."
                )
            )
        }

        copyTask.waitUntilExit()
        guard copyTask.terminationStatus == 0 else {
            return "Copy failed for \(folder.name); original files kept."
        }

        let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
        onProgress(
            MoveProgress(
                appName: "\(folder.name) (\(itemsToMove.count) items)",
                targetVolumeName: targetVolName,
                copiedBytes: totalBytes,
                totalBytes: totalBytes,
                speedBytesPerSec: Double(totalBytes) / elapsed,
                phase: "Cleaning up originals..."
            )
        )

        SystemMonitor.runShell("setopt nullglob dotglob; for f in \"\(folder.path)\"/*; do b=$(basename \"$f\"); [ \"$b\" = \".DS_Store\" ] || [ \"$b\" = \".localized\" ] && continue; rm -rf \"$f\"; done")

        return "Moved \(itemsToMove.count) items from \(folder.name) to \(targetVolName)/UserData/\(folder.name)"
    }

    static func runningAppsOnVolume(mountPath: String) -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let resolved = app.bundleURL?.resolvingSymlinksInPath().path,
                  resolved.hasPrefix(mountPath + "/") else { return nil }
            return app.localizedName ?? app.bundleURL?.lastPathComponent
        }
    }

    static func ejectVolume(mountPath: String) -> String {
        let blocking = runningAppsOnVolume(mountPath: mountPath)
        if !blocking.isEmpty {
            return "Cannot eject: quit \(blocking.joined(separator: ", ")) first."
        }
        let out = SystemMonitor.runShell("/usr/sbin/diskutil eject \"\(mountPath)\" 2>&1")
        return out.isEmpty ? "Ejected \(URL(fileURLWithPath: mountPath).lastPathComponent)" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func emptyTrash() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        try? task.run()
        task.waitUntilExit()
    }
}
