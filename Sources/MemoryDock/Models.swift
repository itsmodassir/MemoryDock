import Foundation

struct MemorySnapshot: Sendable {
    let totalBytes: UInt64
    let activeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let inactiveBytes: UInt64
    let freeBytes: UInt64

    var usedBytes: UInt64 {
        activeBytes + wiredBytes + compressedBytes
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }

    static let empty = MemorySnapshot(
        totalBytes: 0,
        activeBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        inactiveBytes: 0,
        freeBytes: 0
    )
}

struct AppItem: Identifiable, Sendable {
    let id: String // bundleIdentifier or pid fallback
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let rssBytes: UInt64
    let isProtected: Bool
}

struct BrowserTabItem: Identifiable, Hashable, Sendable {
    let id: String
    let browserName: String
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isActive: Bool
}

struct ServiceItem: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let pid: pid_t?
    let rssBytes: UInt64
    let isRunning: Bool
    let requiresAdmin: Bool
    let stopCommand: String
    let startCommand: String
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview & Presets"
    case apps = "Running Apps"
    case tabs = "Browser Tabs"
    case services = "Databases & Background"
    case disk = "Disk Management"
    case files = "File Organizer"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .apps: return "macwindow.on.rectangle"
        case .tabs: return "globe"
        case .services: return "cylinder.split.1x2"
        case .disk: return "externaldrive.connected.to.line.below"
        case .files: return "folder.badge.gearshape"
        }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 {
        return String(format: "%.2f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576.0
    return String(format: "%.0f MB", mb)
}
