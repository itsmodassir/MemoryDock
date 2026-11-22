import SwiftUI

struct DashboardView: View {
    @ObservedObject var vm: AppViewModel
    @State private var selection: SidebarSection? = .overview
    @State private var searchText = ""
    @State private var selectedFileCategory: FileCategory? = nil
    @State private var previewFile: OrganizedFileItem? = nil
    @State private var fileToDelete: OrganizedFileItem? = nil
    @State private var smbAddress = ""
    @State private var smbUsername = ""
    @State private var smbPassword = ""
    @State private var browsingVolume: VolumeItem? = nil
    @State private var showDuplicatesOnly = false
    @State private var showLargeFilesOnly = false

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                memoryHeaderBar
                Divider()
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let msg = vm.statusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        vm.refresh(includeBrowserTabs: selection == .tabs)
                        if selection == .disk || selection == .installedApps {
                            vm.refreshDisk()
                        } else if selection == .files {
                            vm.scanFiles()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isRefreshing || vm.isDiskRefreshing || vm.isScanningFiles)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter apps, tabs, or services")
        .frame(minWidth: 780, minHeight: 520)
    }

    private var memoryHeaderBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory: \(formatBytes(vm.snapshot.usedBytes)) / \(formatBytes(vm.snapshot.totalBytes))")
                    .font(.headline)
                Spacer()
                Text("Active \(formatBytes(vm.snapshot.activeBytes)) · Wired \(formatBytes(vm.snapshot.wiredBytes)) · Compressed \(formatBytes(vm.snapshot.compressedBytes)) · Free/Reclaimable \(formatBytes(vm.snapshot.freeBytes + vm.snapshot.inactiveBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: vm.snapshot.usedFraction)
                .tint(vm.snapshot.usedFraction > 0.8 ? .red : (vm.snapshot.usedFraction > 0.65 ? .orange : .green))
        }
        .padding()
        .background(.background)
    }

    @ViewBuilder
    private var contentView: some View {
        switch selection ?? .overview {
        case .overview:
            overviewTab
        case .apps:
            appsTab
        case .tabs:
            tabsTab
                .onAppear {
                    if vm.tabs.isEmpty {
                        vm.refresh(includeBrowserTabs: true)
                    }
                }
        case .services:
            servicesTab
        case .disk:
            diskTab
                .onAppear {
                    vm.refreshVolumesOnly()
                    if vm.diskApps.isEmpty {
                        vm.refreshDisk()
                    }
                }
        case .installedApps:
            ApplicationsView(vm: vm, searchText: searchText)
        case .files:
            fileOrganizerTab
                .onAppear {
                    vm.refreshVolumesOnly()
                    if vm.organizedFiles.isEmpty {
                        vm.scanFiles()
                    }
                }
        case .cloud:
            CloudStorageView(vm: vm)
        case .remote:
            RemoteMacView(server: vm.remoteServer, client: vm.remoteClient)
        }
    }

    private var overviewTab: some View {
        let internalVol = vm.volumes.first { !$0.isExternal }
        let extCount = vm.volumes.filter(\.isExternal).count
        let cloudTotal = vm.cloudMounts.count + vm.s3Configs.count

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                    Button { selection = .apps } label: {
                        summaryCard(
                            title: "Running Apps",
                            value: "\(vm.apps.count)",
                            subtitle: "Unpinned: \(vm.apps.filter { !$0.isProtected }.count)",
                            color: .blue
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .tabs } label: {
                        summaryCard(
                            title: "Browser Tabs",
                            value: "\(vm.tabs.count)",
                            subtitle: "Inactive: \(vm.tabs.filter { !$0.isActive }.count)",
                            color: .purple
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .services } label: {
                        summaryCard(
                            title: "Databases & BG",
                            value: "\(vm.services.filter(\.isRunning).count) running",
                            subtitle: "\(vm.services.count) detected",
                            color: .orange
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .disk } label: {
                        summaryCard(
                            title: "Disk & Wi-Fi Drives",
                            value: internalVol.map { "\(formatBytes($0.availableBytes)) free" } ?? "--",
                            subtitle: "\(extCount) external / Wi-Fi disk\(extCount == 1 ? "" : "s")",
                            color: .teal
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .files } label: {
                        summaryCard(
                            title: "File Organizer",
                            value: vm.organizedFiles.isEmpty ? "Scan Files" : "\(vm.organizedFiles.count) files",
                            subtitle: vm.organizedFiles.isEmpty ? "Docs, Images, Video, Audio" : "Duplicates: \(vm.duplicateFileIDs.count)",
                            color: .green
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .cloud } label: {
                        summaryCard(
                            title: "Cloud Storage",
                            value: "\(cloudTotal) connected",
                            subtitle: "\(vm.cloudMounts.count) Drive · \(vm.s3Configs.count) S3/R2",
                            color: .indigo
                        )
                    }
                    .buttonStyle(.plain)

                    Button { selection = .remote } label: {
                        summaryCard(
                            title: "Remote Macs",
                            value: vm.remoteClient.isConnected ? "Connected" : (vm.remoteServer.isSharing ? "Sharing" : "Ready"),
                            subtitle: vm.remoteServer.isSharing ? "PIN: \(vm.remoteServer.pairingPIN)" : "Same Wi-Fi Control",
                            color: .pink
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .top, spacing: 14) {
                    GroupBox("One-Click Low RAM Mode") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Quit all unpinned apps", isOn: $vm.presetCloseUnpinnedApps)
                            Toggle("Close all inactive browser tabs", isOn: $vm.presetCloseInactiveTabs)
                            Toggle("Stop running databases & background services", isOn: $vm.presetStopBackgroundServices)

                            HStack {
                                Button {
                                    vm.runLowRamMode()
                                } label: {
                                    Label("Free RAM Now", systemImage: "bolt.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Text("Pinned apps stay open.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Quick Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                selection = .disk
                            } label: {
                                Label("Move Apps & Folders to External / Wi-Fi Disk", systemImage: "externaldrive.badge.plus")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                selection = .files
                            } label: {
                                Label("Organize Files, Preview Images & Find Duplicates", systemImage: "folder.badge.gearshape")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                selection = .cloud
                            } label: {
                                Label("Connect S3, Cloudflare R2, iCloud, Google Drive & OneDrive", systemImage: "icloud.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                selection = .remote
                            } label: {
                                Label("Control Another Mac on Same Wi-Fi", systemImage: "laptopcomputer.and.iphone")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                selection = .services
                            } label: {
                                Label("Turn Off Unused Databases & Background Jobs", systemImage: "cylinder.split.1x2")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !vm.volumes.isEmpty {
                    GroupBox("Mounted Drives") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            ForEach(vm.volumes) { vol in
                                HStack(spacing: 8) {
                                    Image(systemName: vol.isNetwork ? "wifi" : (vol.isExternal ? "externaldrive.fill" : "internaldrive.fill"))
                                        .foregroundStyle(vol.isNetwork ? .purple : (vol.isWritable ? .blue : .secondary))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(vol.name)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                        Text("\(formatBytes(vol.availableBytes)) free of \(formatBytes(vol.totalBytes))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(4)
                    }
                }

                GroupBox("Top Memory Consumers") {
                    VStack(spacing: 8) {
                        ForEach(vm.apps.prefix(5)) { app in
                            HStack {
                                Text(app.name)
                                    .fontWeight(.medium)
                                if app.isProtected {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                                Spacer()
                                Text(formatBytes(app.rssBytes))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button("Quit") {
                                    vm.quitApp(app)
                                }
                                .disabled(app.isProtected)
                            }
                            Divider()
                        }
                    }
                    .padding(6)
                }
            }
            .padding()
        }
    }

    private var appsTab: some View {
        let filtered = vm.apps.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return List(filtered) { app in
            HStack(spacing: 12) {
                Button {
                    vm.toggleProtection(for: app)
                } label: {
                    Image(systemName: app.isProtected ? "pin.fill" : "pin")
                        .foregroundStyle(app.isProtected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help(app.isProtected ? "Protected from Low RAM Mode" : "Pin to protect from Low RAM Mode")

                VStack(alignment: .leading) {
                    Text(app.name).fontWeight(.medium)
                    if let bundle = app.bundleIdentifier {
                        Text(bundle).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(formatBytes(app.rssBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button("Quit") {
                    vm.quitApp(app, force: false)
                }
                Button("Force") {
                    vm.quitApp(app, force: true)
                }
                .foregroundStyle(.red)
            }
            .padding(.vertical, 2)
        }
    }

    private var tabsTab: some View {
        let filtered = vm.tabs.filter {
            searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.url.localizedCaseInsensitiveContains(searchText)
                || $0.browserName.localizedCaseInsensitiveContains(searchText)
        }
        return VStack(spacing: 0) {
            HStack {
                Text("\(filtered.count) open tabs across running browsers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close All Inactive Tabs") {
                    vm.closeAllInactiveTabs()
                }
                .disabled(vm.tabs.filter { !$0.isActive }.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Browser Tabs Found",
                    systemImage: "globe",
                    description: Text("Open Google Chrome, Brave, or Safari, and grant Automation permission if macOS prompts.")
                )
            } else {
                List(filtered) { tab in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tab.browserName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                if tab.isActive {
                                    Text("Active")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Text(tab.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            }
                            Text(tab.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Close") {
                            vm.closeTab(tab)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var servicesTab: some View {
        let filtered = vm.services.filter {
            searchText.isEmpty
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
        }
        return Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Databases or Background Services Detected",
                    systemImage: "cylinder.split.1x2",
                    description: Text("MySQL, Homebrew services, Gradle, Ollama, and OpenClaw Gateway appear here when available.")
                )
            } else {
                List(filtered) { svc in
                    HStack {
                        Circle()
                            .fill(svc.isRunning ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 9, height: 9)

                        VStack(alignment: .leading) {
                            Text(svc.name).fontWeight(.medium)
                            Text(svc.category + (svc.requiresAdmin ? " · Admin required" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if svc.isRunning && svc.rssBytes > 0 {
                            Text(formatBytes(svc.rssBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        Button(svc.isRunning ? "Turn Off" : "Turn On") {
                            vm.toggleService(svc)
                        }
                        .tint(svc.isRunning ? .red : .green)
                        .disabled(!svc.isRunning && svc.startCommand.isEmpty)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var diskTab: some View {
        let writableExternalVolumes = vm.volumes.filter { $0.isExternal && $0.isWritable }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moveProgressBanner

                GroupBox("Drives & Volumes") {
                    VStack(spacing: 10) {
                        if vm.volumes.isEmpty {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Scanning volumes...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        } else {
                            ForEach(vm.volumes) { vol in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: vol.isNetwork ? "wifi" : (vol.isExternal ? "externaldrive.fill" : "internaldrive.fill"))
                                            .foregroundStyle(vol.isNetwork ? .purple : (vol.isWritable ? .blue : .secondary))
                                        Text(vol.name)
                                            .fontWeight(.medium)
                                        if vol.isNetwork {
                                            Text("Wi-Fi")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.18), in: Capsule())
                                                .foregroundStyle(.purple)
                                        }
                                        Text(vol.fileSystem)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                        if !vol.isWritable {
                                            Text("Read-Only")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        Spacer()
                                        Text("\(formatBytes(vol.availableBytes)) free of \(formatBytes(vol.totalBytes))")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        Button("Browse") {
                                            browsingVolume = vol
                                        }
                                        Button("Finder") {
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vol.mountPath)
                                        }
                                        if vol.isExternal {
                                            Button("Eject") {
                                                vm.ejectVolume(vol)
                                            }
                                        }
                                    }
                                    ProgressView(value: vol.usedFraction)
                                        .tint(vol.usedFraction > 0.85 ? .red : .blue)
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Wi-Fi / Network Disks (SMB / AFP)") {
                    NetworkDiskSectionView(
                        vm: vm,
                        discovery: vm.networkDiscovery,
                        smbAddress: $smbAddress,
                        smbUsername: $smbUsername,
                        smbPassword: $smbPassword
                    )
                }

                GroupBox("Default Downloads Drive (Internet & Any App)") {
                    DefaultDownloadsDriveView(
                        router: vm.downloadsRouter,
                        writableVolumes: writableExternalVolumes
                    )
                }

                DiskToolsView(vm: vm)

                GroupBox("Desktop, Downloads & Documents") {
                    VStack(spacing: 8) {
                        ForEach(vm.userFolders) { folder in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(folder.name).fontWeight(.medium)
                                        Text("\(folder.itemCount) items")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(folder.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatBytes(folder.sizeBytes))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                                }
                                if !writableExternalVolumes.isEmpty && folder.itemCount > 0 {
                                    Menu("Move to Disk") {
                                        ForEach(writableExternalVolumes) { vol in
                                            Button("\(vol.name) (\(formatBytes(vol.availableBytes)) free)") {
                                                vm.moveUserFolder(folder, targetVolumePath: vol.mountPath)
                                            }
                                        }
                                    }
                                    .disabled(vm.isMovingApp)
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(6)
                }

                GroupBox("Quick Space Savers") {
                    VStack(spacing: 8) {
                        ForEach(vm.cleanupFolders) { folder in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(folder.name).fontWeight(.medium)
                                    Text(folder.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatBytes(folder.sizeBytes))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                                }
                                if folder.canEmptyTrash {
                                    Button("Empty Trash") {
                                        vm.emptyTrash()
                                    }
                                    .tint(.red)
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(6)
                }
            }
            .padding()
        }
        .sheet(item: $browsingVolume) { vol in
            VolumeBrowserSheet(vm: vm, volume: vol)
        }
    }

    @ViewBuilder
    private var moveProgressBanner: some View {
        if let prog = vm.moveProgress {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Moving \(prog.appName) → \(prog.targetVolumeName)")
                            .fontWeight(.semibold)
                        Text("(\(prog.phase))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(prog.fraction * 100))%")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    ProgressView(value: prog.fraction)
                        .tint(.blue)

                    HStack {
                        Text("\(formatBytes(prog.copiedBytes)) / \(formatBytes(prog.totalBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f MB/s", prog.speedBytesPerSec / 1_048_576.0))
                            .font(.caption.bold())
                            .monospacedDigit()
                            .foregroundStyle(.blue)
                    }
                }
                .padding(6)
            }
        }
    }

    private var fileOrganizerTab: some View {
        let writableExternalVolumes = vm.volumes.filter { $0.isExternal && $0.isWritable }
        let filtered = vm.organizedFiles.filter { file in
            let matchesCat = selectedFileCategory == nil || file.category == selectedFileCategory
            let matchesDupes = !showDuplicatesOnly || vm.duplicateFileIDs.contains(file.id)
            let matchesLarge = !showLargeFilesOnly || file.sizeBytes >= 52_428_800
            let matchesSearch = searchText.isEmpty
                || file.name.localizedCaseInsensitiveContains(searchText)
                || file.sourceFolder.localizedCaseInsensitiveContains(searchText)
            return matchesCat && matchesDupes && matchesLarge && matchesSearch
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moveProgressBanner

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(FileCategory.allCases) { cat in
                        let catFiles = vm.organizedFiles.filter { $0.category == cat }
                        let totalSize = catFiles.reduce(UInt64(0)) { $0 + $1.sizeBytes }
                        let isSelected = selectedFileCategory == cat

                        Button {
                            selectedFileCategory = isSelected ? nil : cat
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: cat.icon)
                                        .foregroundStyle(cat.color)
                                    Text(cat.rawValue)
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                Text(formatBytes(totalSize))
                                    .font(.title3.bold())
                                    .monospacedDigit()
                                Text("\(catFiles.count) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? cat.color.opacity(0.16) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? cat.color : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                GroupBox {
                    VStack(spacing: 8) {
                        HStack {
                            Text(selectedFileCategory?.rawValue ?? "All Files (Desktop, Downloads & Documents)")
                                .font(.headline)
                            Text("(\(filtered.count) shown)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Duplicates (\(vm.duplicateFileIDs.count))", isOn: $showDuplicatesOnly)
                                .toggleStyle(.button)
                            Toggle("> 50 MB", isOn: $showLargeFilesOnly)
                                .toggleStyle(.button)
                            if selectedFileCategory != nil || showDuplicatesOnly || showLargeFilesOnly {
                                Button("Reset") {
                                    selectedFileCategory = nil
                                    showDuplicatesOnly = false
                                    showLargeFilesOnly = false
                                }
                            }
                            if !writableExternalVolumes.isEmpty && !filtered.isEmpty {
                                let label = selectedFileCategory?.rawValue ?? "All Selected"
                                Menu("Move \(label) to Disk") {
                                    ForEach(writableExternalVolumes) { vol in
                                        Button("\(vol.name) (\(formatBytes(vol.availableBytes)) free)") {
                                            vm.moveOrganizedFiles(filtered, label: label, targetVolumePath: vol.mountPath)
                                        }
                                    }
                                }
                                .disabled(vm.isMovingApp)
                            }
                        }
                        .padding(.bottom, 4)

                        Divider()

                        if vm.isScanningFiles && filtered.isEmpty {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Scanning Desktop, Downloads & Documents...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        } else if filtered.isEmpty {
                            Text("No files found in this category.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            LazyVStack(spacing: 4) {
                                ForEach(filtered.prefix(200)) { file in
                                    HStack(spacing: 10) {
                                        Button {
                                            if file.category == .images {
                                                previewFile = file
                                            } else {
                                                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                                            }
                                        } label: {
                                            FileThumbnailView(file: file)
                                        }
                                        .buttonStyle(.plain)
                                        .help(file.category == .images ? "Click to preview image" : "Open file")

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(file.name)
                                                    .fontWeight(.medium)
                                                    .lineLimit(1)
                                                if vm.duplicateFileIDs.contains(file.id) {
                                                    Text("Duplicate")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1)
                                                        .background(Color.orange.opacity(0.2), in: Capsule())
                                                        .foregroundStyle(.orange)
                                                }
                                            }
                                            Text("\(file.sourceFolder) · \(file.path)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(formatBytes(file.sizeBytes))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        if file.category == .images {
                                            Button("Preview") {
                                                previewFile = file
                                            }
                                        }
                                        Button("Reveal") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                        }
                                        if !writableExternalVolumes.isEmpty {
                                            Menu("Move") {
                                                ForEach(writableExternalVolumes) { vol in
                                                    Button("\(vol.name)") {
                                                        vm.moveOrganizedFiles([file], label: file.name, targetVolumePath: vol.mountPath)
                                                    }
                                                }
                                            }
                                            .disabled(vm.isMovingApp)
                                        }
                                        Button(role: .destructive) {
                                            fileToDelete = file
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .help("Permanently delete file")
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .padding()
        }
        .sheet(item: $previewFile) { file in
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.headline)
                        Text("\(formatBytes(file.sizeBytes)) · \(file.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                    Button("Delete", role: .destructive) {
                        previewFile = nil
                        fileToDelete = file
                    }
                    Button("Close") {
                        previewFile = nil
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Divider()

                if let nsImg = NSImage(contentsOfFile: file.path) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 680, maxHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Unable to load image preview.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(minWidth: 520, minHeight: 420)
        }
        .alert(
            "Delete Permanently?",
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { file in
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
            Button("Delete Permanently", role: .destructive) {
                vm.deleteFilePermanently(file)
                fileToDelete = nil
            }
        } message: { file in
            Text("\"\(file.name)\" (\(formatBytes(file.sizeBytes))) will be permanently deleted from your disk and cannot be undone.\n\nPath: \(file.path)")
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
