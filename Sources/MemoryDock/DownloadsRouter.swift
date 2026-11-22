import AppKit
import Foundation

@MainActor
final class DownloadsRouter: ObservableObject {
    @Published var isEnabled: Bool
    @Published var targetVolumePath: String
    @Published var lastRoutedNote: String?

    private let enabledKey = "MemoryDock.downloadsRouterEnabled"
    private let volumeKey = "MemoryDock.downloadsRouterVolume"

    private var dirFD: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    var targetFolder: String {
        targetVolumePath.isEmpty ? NSHomeDirectory() + "/Downloads" : "\(targetVolumePath)/Downloads"
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        self.targetVolumePath = UserDefaults.standard.string(forKey: volumeKey) ?? ""
        if isEnabled && !targetVolumePath.isEmpty {
            startWatcher()
        }
    }

    func setDefaultDrive(_ volumePath: String) {
        targetVolumePath = volumePath
        isEnabled = true
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(volumePath, forKey: volumeKey)

        let dest = "\(volumePath)/Downloads"
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        startWatcher()
        routeCompletedDownloads()
        lastRoutedNote = "Default downloads set to \(dest)"

        Task.detached(priority: .utility) {
            Self.applyBrowserDownloadFolder(dest)
        }
    }

    func resetToInternal() {
        isEnabled = false
        targetVolumePath = ""
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.set("", forKey: volumeKey)
        stopWatcher()
        let internalDownloads = NSHomeDirectory() + "/Downloads"
        lastRoutedNote = "Reset default downloads to ~/Downloads"

        Task.detached(priority: .utility) {
            Self.applyBrowserDownloadFolder(internalDownloads)
        }
    }

    func toggleAutoRoute(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled && !targetVolumePath.isEmpty {
            startWatcher()
            routeCompletedDownloads()
        } else {
            stopWatcher()
        }
    }

    private func startWatcher() {
        stopWatcher()
        let downloadsPath = NSHomeDirectory() + "/Downloads"
        let fd = open(downloadsPath, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: DispatchQueue.main
        )
        let onEvent: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRoute()
            }
        }
        let onCancel: @Sendable () -> Void = {
            close(fd)
        }
        src.setEventHandler(handler: onEvent)
        src.setCancelHandler(handler: onCancel)
        src.resume()
        source = src
    }

    private func stopWatcher() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        dirFD = -1
    }

    private func scheduleRoute() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            routeCompletedDownloads()
        }
    }

    func routeCompletedDownloads() {
        guard isEnabled, !targetVolumePath.isEmpty else { return }
        let destDir = targetFolder
        guard FileManager.default.fileExists(atPath: targetVolumePath) else {
            lastRoutedNote = "Target drive not mounted: \(targetVolumePath)"
            return
        }

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let srcDir = NSHomeDirectory() + "/Downloads"
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            guard let entries = try? fm.contentsOfDirectory(atPath: srcDir) else { return }

            let tempExtensions: Set<String> = ["crdownload", "download", "part", "tmp", "partial"]
            var movedCount = 0

            for name in entries {
                if name.hasPrefix(".") { continue }
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                if tempExtensions.contains(ext) { continue }

                let srcPath = "\(srcDir)/\(name)"
                var dstPath = "\(destDir)/\(name)"
                if fm.fileExists(atPath: dstPath) {
                    let u = URL(fileURLWithPath: name)
                    let base = u.deletingPathExtension().lastPathComponent
                    let stamp = Int(Date().timeIntervalSince1970)
                    let unique = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
                    dstPath = "\(destDir)/\(unique)"
                }

                let escSrc = srcPath.replacingOccurrences(of: "\"", with: "\\\"")
                let escDst = dstPath.replacingOccurrences(of: "\"", with: "\\\"")
                let res = SystemMonitor.runShell("/bin/cp -a \"\(escSrc)\" \"\(escDst)\" && rm -rf \"\(escSrc)\"")
                _ = res
                if fm.fileExists(atPath: dstPath) && !fm.fileExists(atPath: srcPath) {
                    movedCount += 1
                }
            }

            if movedCount > 0 {
                await MainActor.run {
                    self.lastRoutedNote = "Auto-moved \(movedCount) download(s) to \(destDir)"
                }
            }
        }
    }

    nonisolated private static func applyBrowserDownloadFolder(_ folderPath: String) {
        // Safari preference
        SystemMonitor.runShell("/usr/bin/defaults write com.apple.Safari DownloadsPath -string \"\(folderPath)\"")

        // Chrome & Brave preferences (takes effect if browser is closed or on next launch)
        let browserPrefs = [
            NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Default/Preferences",
            NSHomeDirectory() + "/Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences"
        ]
        for prefPath in browserPrefs where FileManager.default.fileExists(atPath: prefPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefPath)),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var downloadDict = (json["download"] as? [String: Any]) ?? [:]
            downloadDict["default_directory"] = folderPath
            downloadDict["prompt_for_download"] = false
            json["download"] = downloadDict
            if let outData = try? JSONSerialization.data(withJSONObject: json) {
                try? outData.write(to: URL(fileURLWithPath: prefPath))
            }
        }
    }
}
