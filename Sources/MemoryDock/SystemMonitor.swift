import AppKit
import Darwin
import Foundation

struct ProcessInfoRow: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let rssBytes: UInt64
    let user: String
    let command: String
}

enum SystemMonitor {
    static func readMemorySnapshot() -> MemorySnapshot {
        var totalBytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemorySnapshot(
                totalBytes: totalBytes,
                activeBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                inactiveBytes: 0,
                freeBytes: 0
            )
        }

        return MemorySnapshot(
            totalBytes: totalBytes,
            activeBytes: UInt64(stats.active_count) * pageBytes,
            wiredBytes: UInt64(stats.wire_count) * pageBytes,
            compressedBytes: UInt64(stats.compressor_page_count) * pageBytes,
            inactiveBytes: (UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * pageBytes,
            freeBytes: UInt64(stats.free_count) * pageBytes
        )
    }

    static func listProcesses() -> [ProcessInfoRow] {
        let output = runShell("/bin/ps -ax -o pid=,ppid=,rss=,user=,command=")
        var rows: [ProcessInfoRow] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 5,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }
            rows.append(
                ProcessInfoRow(
                    pid: pid,
                    ppid: ppid,
                    rssBytes: rssKB * 1024,
                    user: String(parts[3]),
                    command: String(parts[4])
                )
            )
        }
        return rows
    }

    static func buildAppItems(
        processes: [ProcessInfoRow],
        protectedBundleIDs: Set<String>
    ) -> [AppItem] {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        // Build parent -> children map so helper processes (e.g. Chrome/Antigravity helpers) roll up to their parent app.
        var childrenByParent: [pid_t: [ProcessInfoRow]] = [:]
        for p in processes {
            childrenByParent[p.ppid, default: []].append(p)
        }
        let processByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

        func subtreeRSS(rootPID: pid_t) -> UInt64 {
            var total: UInt64 = processByPID[rootPID]?.rssBytes ?? 0
            var queue: [pid_t] = [rootPID]
            var visited: Set<pid_t> = [rootPID]
            while let current = queue.popLast() {
                for child in childrenByParent[current] ?? [] where !visited.contains(child.pid) {
                    visited.insert(child.pid)
                    total += child.rssBytes
                    queue.append(child.pid)
                }
            }
            return total
        }

        var items: [AppItem] = []
        for app in runningApps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "Unknown App"
            let bundleID = app.bundleIdentifier
            let key = bundleID ?? "pid-\(pid)"
            let rss = subtreeRSS(rootPID: pid)
            let isProtected = bundleID.map { protectedBundleIDs.contains($0) } ?? false
            items.append(
                AppItem(
                    id: key,
                    pid: pid,
                    name: name,
                    bundleIdentifier: bundleID,
                    rssBytes: rss,
                    isProtected: isProtected
                )
            )
        }

        return items.sorted { $0.rssBytes > $1.rssBytes }
    }

    @discardableResult
    static func runShell(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
