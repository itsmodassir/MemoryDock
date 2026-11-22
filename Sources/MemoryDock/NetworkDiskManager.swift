import AppKit
import Foundation
import NetFS

struct DiscoveredNetworkHost: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let serviceType: String
    let address: String

    var protocolLabel: String {
        serviceType.contains("afp") ? "AFP" : "SMB"
    }
}

@MainActor
final class NetworkDiscovery: NSObject, ObservableObject {
    @Published var hosts: [DiscoveredNetworkHost] = []
    @Published var isScanning = false

    private var browsers: [NetServiceBrowser] = []
    private var resolvingServices: [NetService] = []

    func startScan() {
        stopScan()
        hosts = []
        isScanning = true

        for type in ["_smb._tcp.", "_afpovertcp._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }

        Task {
            try? await Task.sleep(for: .seconds(8))
            stopScan()
        }
    }

    func stopScan() {
        for b in browsers {
            b.stop()
        }
        browsers.removeAll()
        for s in resolvingServices {
            s.stop()
        }
        resolvingServices.removeAll()
        isScanning = false
    }
}

extension NetworkDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name
        let type = service.type
        let domain = service.domain
        Task { @MainActor in
            let resolver = NetService(domain: domain, type: type, name: name)
            resolver.delegate = self
            resolvingServices.append(resolver)
            resolver.resolve(withTimeout: 5.0)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let type = sender.type
        let hostName = sender.hostName ?? name
        let scheme = type.contains("afp") ? "afp" : "smb"
        let cleanHost = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let urlStr = "\(scheme)://\(cleanHost)"

        Task { @MainActor in
            let item = DiscoveredNetworkHost(
                id: "\(type)-\(name)",
                name: name,
                serviceType: type,
                address: urlStr
            )
            if !hosts.contains(where: { $0.id == item.id }) {
                hosts.append(item)
            }
        }
    }
}

enum NetworkDiskManager {
    static func mountShare(address: String, username: String, password: String) -> String {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "smb://\(trimmed)"
        }
        guard let url = URL(string: trimmed) else {
            return "Invalid network address: \(trimmed)"
        }

        var mountPoints: Unmanaged<CFArray>?
        let userArg: CFString? = username.isEmpty ? nil : (username as CFString)
        let passArg: CFString? = password.isEmpty ? nil : (password as CFString)

        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            userArg,
            passArg,
            nil,
            nil,
            &mountPoints
        )

        if status == 0 {
            if let arr = mountPoints?.takeRetainedValue() as? [String], let first = arr.first {
                return "Connected: \(first)"
            }
            return "Connected to \(trimmed)"
        }

        return "Connection failed (error \(status)). Check address, share name, or credentials."
    }

    static func listDirectory(at path: String) -> [RemoteEntry] {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [RemoteEntry] = []
        for url in urls {
            let vals = try? url.resourceValues(forKeys: keys)
            let isDir = vals?.isDirectory ?? false
            let size = UInt64(vals?.fileSize ?? 0)
            entries.append(
                RemoteEntry(
                    id: url.path,
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: isDir,
                    sizeBytes: size
                )
            )
        }

        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func uploadFiles(
        urls: [URL],
        toDirectory destDir: String,
        onProgress: @Sendable @escaping (MoveProgress) -> Void
    ) async -> String {
        let fm = FileManager.default
        let destName = URL(fileURLWithPath: destDir).lastPathComponent
        var totalBytes: UInt64 = 0
        for u in urls {
            let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += UInt64(sz)
        }
        totalBytes = max(totalBytes, 1)

        let start = Date()
        var copied: UInt64 = 0
        var count = 0

        for u in urls {
            let dst = "\(destDir)/\(u.lastPathComponent)"
            let elapsed = max(Date().timeIntervalSince(start), 0.1)
            onProgress(
                MoveProgress(
                    appName: u.lastPathComponent,
                    targetVolumeName: destName,
                    copiedBytes: copied,
                    totalBytes: totalBytes,
                    speedBytesPerSec: Double(copied) / elapsed,
                    phase: "Uploading \(count + 1)/\(urls.count)"
                )
            )

            let escapedSrc = u.path.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedDst = dst.replacingOccurrences(of: "\"", with: "\\\"")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", "/bin/cp -a \"\(escapedSrc)\" \"\(escapedDst)\""]
            try? proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0 {
                let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                copied += UInt64(sz)
                count += 1
            } else if fm.fileExists(atPath: dst) {
                count += 1
            }
        }

        return "Copied \(count) item(s) to \(destName)"
    }
}

struct RemoteEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: UInt64
}
