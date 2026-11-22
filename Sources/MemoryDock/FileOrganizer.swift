import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case documents = "Documents"
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case archives = "Archives"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .documents: return "doc.text.fill"
        case .images: return "photo.fill"
        case .videos: return "film.fill"
        case .audio: return "music.note"
        case .archives: return "archivebox.fill"
        case .other: return "folder.fill"
        }
    }

    var color: Color {
        switch self {
        case .documents: return .blue
        case .images: return .green
        case .videos: return .purple
        case .audio: return .pink
        case .archives: return .orange
        case .other: return .gray
        }
    }

    static func classify(extension ext: String) -> FileCategory {
        switch ext.lowercased() {
        case "pdf", "doc", "docx", "txt", "md", "rtf", "xls", "xlsx", "csv",
             "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp":
            return .documents
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg",
             "bmp", "tiff", "tif", "ico", "psd", "raw", "cr2", "nef":
            return .images
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "3gp":
            return .videos
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "wma", "opus":
            return .audio
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "apk", "ipa":
            return .archives
        default:
            return .other
        }
    }
}

struct OrganizedFileItem: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: UInt64
    let category: FileCategory
    let sourceFolder: String
    let modifiedDate: Date
}

enum FileOrganizer {
    static func scanUserFiles() -> [OrganizedFileItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let roots: [(label: String, path: String)] = [
            ("Desktop", "\(home)/Desktop"),
            ("Downloads", "\(home)/Downloads"),
            ("Documents", "\(home)/Documents")
        ]

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let skipDirNames: Set<String> = [
            "node_modules", ".git", "Pods", "build", ".build", "DerivedData", "venv", ".venv", "__pycache__"
        ]
        var results: [OrganizedFileItem] = []

        for root in roots {
            let rootURL = URL(fileURLWithPath: root.path)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if skipDirNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let vals = try? fileURL.resourceValues(forKeys: keys) else { continue }
                let isRegular = vals.isRegularFile ?? false
                let isPackage = vals.isPackage ?? false
                guard isRegular || isPackage else { continue }

                let sizeBytes = UInt64(vals.fileSize ?? 0)
                let category = FileCategory.classify(extension: fileURL.pathExtension)
                results.append(
                    OrganizedFileItem(
                        id: fileURL.path,
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        sizeBytes: sizeBytes,
                        category: category,
                        sourceFolder: root.label,
                        modifiedDate: vals.contentModificationDate ?? .distantPast
                    )
                )
                if results.count >= 1500 { break }
            }
            if results.count >= 1500 { break }
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func moveFilesToDisk(
        files: [OrganizedFileItem],
        label: String,
        targetVolumePath: String,
        onProgress: @Sendable @escaping (MoveProgress) -> Void
    ) async -> String {
        guard !files.isEmpty else { return "No files to move." }
        let fm = FileManager.default
        let targetVolName = URL(fileURLWithPath: targetVolumePath).lastPathComponent
        let totalBytes = max(files.reduce(UInt64(0)) { $0 + $1.sizeBytes }, 1)
        let startTime = Date()
        var movedBytes: UInt64 = 0
        var movedCount = 0

        for file in files {
            let destDir = "\(targetVolumePath)/Organized/\(file.category.rawValue)"
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

            var destPath = "\(destDir)/\(file.name)"
            if fm.fileExists(atPath: destPath) {
                let url = URL(fileURLWithPath: file.name)
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let stamp = Int(Date().timeIntervalSince1970)
                let uniqueName = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
                destPath = "\(destDir)/\(uniqueName)"
            }

            let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
            onProgress(
                MoveProgress(
                    appName: label,
                    targetVolumeName: targetVolName,
                    copiedBytes: movedBytes,
                    totalBytes: totalBytes,
                    speedBytesPerSec: Double(movedBytes) / elapsed,
                    phase: "Moving \(file.name) (\(movedCount + 1)/\(files.count))"
                )
            )

            let escapedSrc = file.path.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedDst = destPath.replacingOccurrences(of: "\"", with: "\\\"")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", "/bin/cp -a \"\(escapedSrc)\" \"\(escapedDst)\" && rm -rf \"\(escapedSrc)\""]
            try? proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0 {
                movedBytes += file.sizeBytes
                movedCount += 1
            }
        }

        let elapsed = max(Date().timeIntervalSince(startTime), 0.1)
        onProgress(
            MoveProgress(
                appName: label,
                targetVolumeName: targetVolName,
                copiedBytes: totalBytes,
                totalBytes: totalBytes,
                speedBytesPerSec: Double(movedBytes) / elapsed,
                phase: "Done"
            )
        )

        return "Moved \(movedCount) \(label) files to \(targetVolName)/Organized/"
    }

    static func findDuplicateIDs(in files: [OrganizedFileItem]) -> Set<String> {
        let nonEmpty = files.filter { $0.sizeBytes > 0 }
        let bySize = Dictionary(grouping: nonEmpty, by: \.sizeBytes)
        var duplicateIDs: Set<String> = []

        for (_, group) in bySize where group.count > 1 {
            var byHash: [String: [String]] = [:]
            for file in group {
                if let digest = sha256Hex(forPath: file.path) {
                    byHash[digest, default: []].append(file.id)
                }
            }
            for (_, ids) in byHash where ids.count > 1 {
                duplicateIDs.formUnion(ids)
            }
        }
        return duplicateIDs
    }

    private static func sha256Hex(forPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 262_144), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func deleteFilePermanently(_ file: OrganizedFileItem) -> String {
        do {
            try FileManager.default.removeItem(atPath: file.path)
            return "Permanently deleted \(file.name)"
        } catch {
            return "Failed to delete \(file.name): \(error.localizedDescription)"
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()

    func image(forPath path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func loadThumbnail(forPath path: String, maxPixelSize: Int = 96) async -> NSImage? {
        if let existing = cache.object(forKey: path as NSString) {
            return existing
        }
        return await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            ThumbnailCache.shared.cache.setObject(nsImg, forKey: path as NSString)
            return nsImg
        }.value
    }
}

struct FileThumbnailView: View {
    let file: OrganizedFileItem
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: file.category.icon)
                    .foregroundStyle(file.category.color)
                    .frame(width: 34, height: 34)
                    .background(file.category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: file.id) {
            guard file.category == .images else { return }
            thumbnail = await ThumbnailCache.shared.loadThumbnail(forPath: file.path)
        }
    }
}
