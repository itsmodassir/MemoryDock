import Foundation

struct CacheItem: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let paths: [String]
    let sizeBytes: UInt64
    let isSafe: Bool
    let impactDescription: String
}

enum CacheManager {
    static func scanCaches() -> [CacheItem] {
        let home = NSHomeDirectory()
        let specs: [(id: String, name: String, category: String, paths: [String], isSafe: Bool, impact: String)] = [
            (
                "user-caches",
                "User App Caches",
                "macOS",
                ["\(home)/Library/Caches"],
                true,
                "Safe to clear. Apps recreate temporary caches on next launch (may take 1–2s longer once). Your logins, documents, and settings stay untouched."
            ),
            (
                "trash",
                "Trash",
                "macOS",
                ["\(home)/.Trash"],
                false,
                "Permanently deletes all files currently sitting in Trash. This cannot be undone."
            ),
            (
                "logs",
                "User App Logs & Crash Reports",
                "macOS",
                ["\(home)/Library/Logs"],
                true,
                "Safe to clear. Removes old diagnostic logs and crash reports; apps keep working normally."
            ),
            (
                "xcode-derived",
                "Xcode DerivedData",
                "Developer",
                ["\(home)/Library/Developer/Xcode/DerivedData"],
                true,
                "Safe for developers. Deletes compiled Xcode build intermediates; your source code is untouched, and your next Xcode build will do a clean rebuild."
            ),
            (
                "xcode-devicesupport",
                "Xcode iOS DeviceSupport",
                "Developer",
                ["\(home)/Library/Developer/Xcode/iOS DeviceSupport"],
                true,
                "Safe. Removes cached debug symbols for physical iPhones/iPads; Xcode re-downloads them only if you reconnect that device."
            ),
            (
                "homebrew",
                "Homebrew Download Cache",
                "Developer",
                ["\(home)/Library/Caches/Homebrew"],
                true,
                "Safe. Deletes old downloaded installer bottles; already-installed Homebrew packages are not affected."
            ),
            (
                "npm",
                "npm Package Cache",
                "Developer",
                ["\(home)/.npm/_cacache"],
                true,
                "Safe. Removes cached npm tarballs; existing node_modules folders in your projects stay untouched."
            ),
            (
                "gradle",
                "Gradle Build Cache",
                "Developer",
                ["\(home)/.gradle/caches"],
                true,
                "Safe for Android devs. Clears cached Gradle dependencies; Gradle will re-download needed jars on your next Android build."
            ),
            (
                "python",
                "Python (pip & uv) Cache",
                "Developer",
                ["\(home)/Library/Caches/pip", "\(home)/.cache/uv"],
                true,
                "Safe. Deletes cached Python wheel downloads; your existing virtual environments (.venv) are untouched."
            ),
            (
                "ai-models",
                "Local AI Models Cache (Hugging Face / PyTorch)",
                "AI & ML",
                ["\(home)/.cache/huggingface", "\(home)/.cache/torch"],
                false,
                "Caution: Deletes downloaded local AI models (e.g. Qwen2.5-3B, BGE-Small, MobileNet). Local AI apps like EmotiSenseAI will need to re-download them."
            )
        ]

        var items: [CacheItem] = []
        let fm = FileManager.default
        for spec in specs {
            let existingPaths = spec.paths.filter { fm.fileExists(atPath: $0) }
            guard !existingPaths.isEmpty else { continue }
            var totalBytes: UInt64 = 0
            for p in existingPaths {
                let out = SystemMonitor.runShell("/usr/bin/du -sk \"\(p)\" 2>/dev/null | awk '{print $1}'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                totalBytes += (UInt64(out) ?? 0) * 1024
            }
            items.append(
                CacheItem(
                    id: spec.id,
                    name: spec.name,
                    category: spec.category,
                    paths: existingPaths,
                    sizeBytes: totalBytes,
                    isSafe: spec.isSafe,
                    impactDescription: spec.impact
                )
            )
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func clearCache(_ item: CacheItem) -> String {
        if item.id == "trash" {
            DiskManager.emptyTrash()
            return "Emptied Trash"
        }

        let fm = FileManager.default
        var errors = 0
        for dirPath in item.paths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for entry in entries {
                let full = "\(dirPath)/\(entry)"
                do {
                    try fm.removeItem(atPath: full)
                } catch {
                    errors += 1
                }
            }
        }
        if errors > 0 {
            return "Cleared \(item.name) (\(errors) locked/in-use items skipped)"
        }
        return "Cleared \(item.name) (\(formatBytes(item.sizeBytes)) freed)"
    }
}
