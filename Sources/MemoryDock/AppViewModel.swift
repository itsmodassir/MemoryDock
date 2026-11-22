import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot: MemorySnapshot = .empty
    @Published var apps: [AppItem] = []
    @Published var tabs: [BrowserTabItem] = []
    @Published var services: [ServiceItem] = []
    @Published var volumes: [VolumeItem] = []
    @Published var diskApps: [DiskAppItem] = []
    @Published var userFolders: [UserFolderItem] = []
    @Published var cleanupFolders: [CleanupFolderItem] = []
    @Published var organizedFiles: [OrganizedFileItem] = []
    @Published var duplicateFileIDs: Set<String> = []
    @Published var isRefreshing = false
    @Published var isDiskRefreshing = false
    @Published var isScanningFiles = false
    @Published var isMovingApp = false
    @Published var isMountingShare = false
    @Published var moveProgress: MoveProgress?
    @Published var statusMessage: String?

    let networkDiscovery = NetworkDiscovery()
    let remoteServer = RemoteHostServer()
    let remoteClient = RemoteMacClient()

    @Published var presetCloseUnpinnedApps = true
    @Published var presetCloseInactiveTabs = true
    @Published var presetStopBackgroundServices = true

    private let protectedKey = "MemoryDock.protectedBundleIDs"
    private var protectedBundleIDs: Set<String>
    private var refreshTimer: Timer?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: protectedKey) {
            self.protectedBundleIDs = Set(saved)
        } else {
            self.protectedBundleIDs = [
                "com.apple.finder",
                "com.google.antigravity",
                "com.apple.Terminal",
                "com.modassir.MemoryDock"
            ]
        }
        if let selfID = Bundle.main.bundleIdentifier {
            self.protectedBundleIDs.insert(selfID)
        }
        remoteServer.attach(viewModel: self)
        refresh()
        startAutoRefresh()
        observeVolumeChanges()
    }

    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVolumesOnly()
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVolumesOnly()
            }
        }
    }

    func refreshVolumesOnly() {
        Task.detached(priority: .userInitiated) {
            let vols = DiskManager.fetchVolumes()
            await MainActor.run {
                self.volumes = vols
            }
        }
    }

    func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLight()
            }
        }
    }

    /// Ultra-lightweight 4s refresh: only Mach memory stats + mounted volumes (no subprocesses).
    func refreshLight() {
        Task.detached(priority: .utility) {
            let snap = SystemMonitor.readMemorySnapshot()
            let volList = DiskManager.fetchVolumes()
            await MainActor.run {
                self.snapshot = snap
                self.volumes = volList
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let protected = protectedBundleIDs

        Task.detached(priority: .userInitiated) {
            let snap = SystemMonitor.readMemorySnapshot()
            let procs = SystemMonitor.listProcesses()
            let appList = SystemMonitor.buildAppItems(processes: procs, protectedBundleIDs: protected)
            let tabList = BrowserManager.fetchOpenTabs()
            let svcList = ServiceManager.fetchServices(processes: procs)
            let volList = DiskManager.fetchVolumes()

            await MainActor.run {
                self.snapshot = snap
                self.apps = appList
                self.tabs = tabList
                self.services = svcList
                self.volumes = volList
                self.isRefreshing = false
            }
        }
    }

    func toggleProtection(for app: AppItem) {
        guard let bundleID = app.bundleIdentifier else { return }
        if protectedBundleIDs.contains(bundleID) {
            protectedBundleIDs.remove(bundleID)
        } else {
            protectedBundleIDs.insert(bundleID)
        }
        UserDefaults.standard.set(Array(protectedBundleIDs), forKey: protectedKey)
        refresh()
    }

    func quitApp(_ app: AppItem, force: Bool = false) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if force {
            running.forceTerminate()
        } else {
            running.terminate()
        }
        statusMessage = "\(force ? "Force quit" : "Quit") \(app.name)"
        scheduleQuickRefresh()
    }

    func closeTab(_ tab: BrowserTabItem) {
        Task.detached {
            BrowserManager.closeTab(tab)
            await MainActor.run {
                self.statusMessage = "Closed tab: \(tab.title)"
                self.scheduleQuickRefresh()
            }
        }
    }

    func closeAllInactiveTabs() {
        Task.detached {
            BrowserManager.closeAllInactiveTabs()
            await MainActor.run {
                self.statusMessage = "Closed inactive browser tabs"
                self.scheduleQuickRefresh()
            }
        }
    }

    func toggleService(_ service: ServiceItem) {
        Task.detached {
            ServiceManager.toggleService(service)
            await MainActor.run {
                self.statusMessage = "\(service.isRunning ? "Stopped" : "Started") \(service.name)"
                self.scheduleQuickRefresh()
            }
        }
    }

    func runLowRamMode() {
        let appsToQuit = presetCloseUnpinnedApps ? apps.filter { !$0.isProtected } : []
        let closeTabs = presetCloseInactiveTabs
        let servicesToStop = presetStopBackgroundServices ? services.filter { $0.isRunning } : []

        for app in appsToQuit {
            NSRunningApplication(processIdentifier: app.pid)?.terminate()
        }

        Task.detached {
            if closeTabs {
                BrowserManager.closeAllInactiveTabs()
            }
            for svc in servicesToStop {
                ServiceManager.toggleService(svc)
            }
            await MainActor.run {
                self.statusMessage = "Low RAM Mode applied"
                self.scheduleQuickRefresh()
            }
        }
    }

    private func scheduleQuickRefresh() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            refresh()
        }
    }

    func refreshDisk() {
        guard !isDiskRefreshing else { return }
        isDiskRefreshing = true
        Task.detached(priority: .userInitiated) {
            let vols = DiskManager.fetchVolumes()
            let apps = DiskManager.fetchInstalledApps()
            let userDirs = DiskManager.fetchUserFolders()
            let folders = DiskManager.fetchCleanupFolders()
            await MainActor.run {
                self.volumes = vols
                self.diskApps = apps
                self.userFolders = userDirs
                self.cleanupFolders = folders
                self.isDiskRefreshing = false
            }
        }
    }

    func moveAppToExternal(_ app: DiskAppItem, targetVolumePath: String) {
        guard !isMovingApp else { return }
        isMovingApp = true
        statusMessage = "Moving \(app.name)..."
        Task.detached(priority: .userInitiated) {
            let msg = await DiskManager.moveAppToExternal(app: app, targetVolumePath: targetVolumePath) { progress in
                Task { @MainActor in
                    self.moveProgress = progress
                }
            }
            await MainActor.run {
                self.moveProgress = nil
                self.statusMessage = msg
                self.isMovingApp = false
                self.refreshDisk()
            }
        }
    }

    func moveUserFolder(_ folder: UserFolderItem, targetVolumePath: String) {
        guard !isMovingApp else { return }
        isMovingApp = true
        statusMessage = "Moving \(folder.name)..."
        Task.detached(priority: .userInitiated) {
            let msg = await DiskManager.moveUserFolderContents(folder: folder, targetVolumePath: targetVolumePath) { progress in
                Task { @MainActor in
                    self.moveProgress = progress
                }
            }
            await MainActor.run {
                self.moveProgress = nil
                self.statusMessage = msg
                self.isMovingApp = false
                self.refreshDisk()
            }
        }
    }

    func moveAppBackToInternal(_ app: DiskAppItem) {
        guard !isMovingApp else { return }
        isMovingApp = true
        statusMessage = "Moving \(app.name) to Internal SSD..."
        Task.detached(priority: .userInitiated) {
            let msg = await DiskManager.moveAppBackToInternal(app: app) { progress in
                Task { @MainActor in
                    self.moveProgress = progress
                }
            }
            await MainActor.run {
                self.moveProgress = nil
                self.statusMessage = msg
                self.isMovingApp = false
                self.refreshDisk()
            }
        }
    }

    func ejectVolume(_ volume: VolumeItem) {
        Task.detached {
            let msg = DiskManager.ejectVolume(mountPath: volume.mountPath)
            await MainActor.run {
                self.statusMessage = msg
                self.refreshDisk()
            }
        }
    }

    func emptyTrash() {
        Task.detached {
            DiskManager.emptyTrash()
            await MainActor.run {
                self.statusMessage = "Emptied Trash"
                self.refreshDisk()
            }
        }
    }

    func scanFiles() {
        guard !isScanningFiles else { return }
        isScanningFiles = true
        Task.detached(priority: .userInitiated) {
            let files = FileOrganizer.scanUserFiles()
            let dupes = FileOrganizer.findDuplicateIDs(in: files)
            await MainActor.run {
                self.organizedFiles = files
                self.duplicateFileIDs = dupes
                self.isScanningFiles = false
            }
        }
    }

    func moveOrganizedFiles(_ files: [OrganizedFileItem], label: String, targetVolumePath: String) {
        guard !isMovingApp else { return }
        isMovingApp = true
        statusMessage = "Moving \(label)..."
        Task.detached(priority: .userInitiated) {
            let msg = await FileOrganizer.moveFilesToDisk(
                files: files,
                label: label,
                targetVolumePath: targetVolumePath
            ) { progress in
                Task { @MainActor in
                    self.moveProgress = progress
                }
            }
            await MainActor.run {
                self.moveProgress = nil
                self.statusMessage = msg
                self.isMovingApp = false
                self.scanFiles()
                self.refreshDisk()
            }
        }
    }

    func deleteFilePermanently(_ file: OrganizedFileItem) {
        Task.detached(priority: .userInitiated) {
            let msg = FileOrganizer.deleteFilePermanently(file)
            await MainActor.run {
                self.organizedFiles.removeAll { $0.id == file.id }
                self.statusMessage = msg
                self.refreshVolumesOnly()
            }
        }
    }

    func connectNetworkDisk(address: String, username: String, password: String) {
        guard !isMountingShare else { return }
        isMountingShare = true
        statusMessage = "Connecting to \(address)..."
        Task.detached(priority: .userInitiated) {
            let msg = NetworkDiskManager.mountShare(address: address, username: username, password: password)
            await MainActor.run {
                self.statusMessage = msg
                self.isMountingShare = false
                self.refreshVolumesOnly()
            }
        }
    }

    func uploadFilesToDisk(urls: [URL], toDirectory destDir: String, onDone: @escaping @MainActor () -> Void) {
        guard !isMovingApp else { return }
        isMovingApp = true
        Task.detached(priority: .userInitiated) {
            let msg = await NetworkDiskManager.uploadFiles(urls: urls, toDirectory: destDir) { progress in
                Task { @MainActor in
                    self.moveProgress = progress
                }
            }
            await MainActor.run {
                self.moveProgress = nil
                self.statusMessage = msg
                self.isMovingApp = false
                self.refreshVolumesOnly()
                onDone()
            }
        }
    }
}
