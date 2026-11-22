import AppKit
import SwiftUI

struct CloudStorageView: View {
    @ObservedObject var vm: AppViewModel

    @State private var provider: S3ProviderType = .r2
    @State private var nameInput = ""
    @State private var endpointInput = ""
    @State private var bucketInput = ""
    @State private var regionInput = "auto"
    @State private var accessKeyInput = ""
    @State private var secretKeyInput = ""

    @State private var browsingLocalCloud: VolumeItem? = nil
    @State private var browsingS3Config: S3ConnectionConfig? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("iCloud Drive, Google Drive & OneDrive") {
                    VStack(alignment: .leading, spacing: 8) {
                        if vm.cloudMounts.isEmpty {
                            Text("No local cloud drives detected. Install Google Drive / OneDrive or sign into iCloud Drive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.cloudMounts) { mount in
                                HStack {
                                    Image(systemName: "icloud.fill")
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(mount.name).fontWeight(.medium)
                                            Text(mount.provider)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.blue)
                                        }
                                        Text(mount.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Browse (Read/Write)") {
                                        browsingLocalCloud = mount.asVolumeItem()
                                    }
                                    Button("Finder") {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mount.path)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Connect Amazon S3 / Cloudflare R2 (Read & Write)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Provider", selection: $provider) {
                                ForEach(S3ProviderType.allCases, id: \.self) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                            .onChange(of: provider) { _, newVal in
                                regionInput = newVal == .r2 ? "auto" : "us-east-1"
                            }
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            TextField("Label (e.g. My R2)", text: $nameInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            TextField(
                                provider == .r2
                                    ? "https://<account_id>.r2.cloudflarestorage.com"
                                    : "https://s3.us-east-1.amazonaws.com",
                                text: $endpointInput
                            )
                            .textFieldStyle(.roundedBorder)
                            TextField("Bucket", text: $bucketInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            TextField("Region", text: $regionInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }

                        HStack(spacing: 8) {
                            TextField("Access Key ID", text: $accessKeyInput)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Secret Access Key", text: $secretKeyInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Save & Connect") {
                                let cfg = S3ConnectionConfig(
                                    id: UUID().uuidString,
                                    name: nameInput.isEmpty ? bucketInput : nameInput,
                                    provider: provider,
                                    endpoint: endpointInput,
                                    bucket: bucketInput,
                                    region: regionInput,
                                    accessKeyId: accessKeyInput,
                                    secretAccessKey: secretKeyInput
                                )
                                vm.addS3Config(cfg)
                                browsingS3Config = cfg
                                nameInput = ""
                                secretKeyInput = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(endpointInput.isEmpty || bucketInput.isEmpty || accessKeyInput.isEmpty || secretKeyInput.isEmpty)
                        }

                        if !vm.s3Configs.isEmpty {
                            Divider()
                            ForEach(vm.s3Configs) { cfg in
                                HStack {
                                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(cfg.name).fontWeight(.medium)
                                            Text(cfg.provider.rawValue)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.18), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                        Text("\(cfg.bucket) · \(cfg.endpoint)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Browse Bucket") {
                                        browsingS3Config = cfg
                                    }
                                    Button(role: .destructive) {
                                        vm.removeS3Config(cfg)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .padding()
        }
        .onAppear {
            vm.refreshCloudMounts()
        }
        .sheet(item: $browsingLocalCloud) { vol in
            VolumeBrowserSheet(vm: vm, volume: vol)
        }
        .sheet(item: $browsingS3Config) { cfg in
            S3BucketBrowserSheet(config: cfg)
        }
    }
}

struct S3BucketBrowserSheet: View {
    let config: S3ConnectionConfig
    @Environment(\.dismiss) private var dismiss

    @State private var currentPrefix = ""
    @State private var objects: [S3ObjectItem] = []
    @State private var isLoading = false
    @State private var statusText: String?
    @State private var objectToDelete: S3ObjectItem?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(config.name) (\(config.bucket))")
                        .font(.headline)
                    Text("Prefix: /\(currentPrefix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if !currentPrefix.isEmpty {
                    Button("Up") {
                        var trimmed = currentPrefix
                        if trimmed.hasSuffix("/") { trimmed.removeLast() }
                        if let idx = trimmed.lastIndex(of: "/") {
                            currentPrefix = String(trimmed[...idx])
                        } else {
                            currentPrefix = ""
                        }
                        load()
                    }
                }

                Button("Refresh") {
                    load()
                }
                .disabled(isLoading)

                Button("Upload Files") {
                    uploadFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if isLoading && objects.isEmpty {
                ProgressView("Loading bucket objects...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if objects.isEmpty {
                ContentUnavailableView(
                    "Empty Prefix",
                    systemImage: "tray",
                    description: Text("Upload files to write to this bucket.")
                )
            } else {
                List(objects) { obj in
                    HStack {
                        Image(systemName: obj.isFolder ? "folder.fill" : "doc.fill")
                            .foregroundStyle(obj.isFolder ? .blue : .secondary)
                        Text(obj.name).lineLimit(1)
                        Spacer()
                        if !obj.isFolder {
                            Text(formatBytes(obj.sizeBytes))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if obj.isFolder {
                            Button("Open") {
                                currentPrefix = obj.key
                                load()
                            }
                        } else {
                            Button("Download") {
                                downloadObject(obj)
                            }
                            Button(role: .destructive) {
                                objectToDelete = obj
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 460)
        .onAppear {
            load()
        }
        .alert(
            "Delete from Bucket?",
            isPresented: Binding(
                get: { objectToDelete != nil },
                set: { if !$0 { objectToDelete = nil } }
            ),
            presenting: objectToDelete
        ) { obj in
            Button("Cancel", role: .cancel) { objectToDelete = nil }
            Button("Delete Permanently", role: .destructive) {
                deleteObj(obj)
                objectToDelete = nil
            }
        } message: { obj in
            Text("Permanently delete \"\(obj.key)\" from \(config.bucket)?")
        }
    }

    private func load() {
        isLoading = true
        statusText = nil
        let prefix = currentPrefix
        Task {
            do {
                let list = try await S3Client.listObjects(config: config, prefix: prefix)
                objects = list
            } catch {
                statusText = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        isLoading = true
        let prefix = currentPrefix
        let urls = panel.urls
        Task {
            var uploaded = 0
            for url in urls {
                do {
                    try await S3Client.uploadFile(config: config, localURL: url, remoteKey: "\(prefix)\(url.lastPathComponent)")
                    uploaded += 1
                } catch {
                    statusText = "Upload error: \(error.localizedDescription)"
                }
            }
            statusText = "Uploaded \(uploaded) file(s)"
            load()
        }
    }

    private func downloadObject(_ obj: S3ObjectItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = obj.name
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isLoading = true
        Task {
            do {
                try await S3Client.downloadObject(config: config, key: obj.key, to: destURL)
                statusText = "Downloaded \(obj.name)"
            } catch {
                statusText = "Download error: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func deleteObj(_ obj: S3ObjectItem) {
        isLoading = true
        Task {
            do {
                try await S3Client.deleteObject(config: config, key: obj.key)
                statusText = "Deleted \(obj.name)"
                load()
            } catch {
                statusText = "Delete error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
