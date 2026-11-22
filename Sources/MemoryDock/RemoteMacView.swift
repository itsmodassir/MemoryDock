import SwiftUI

struct RemoteMacView: View {
    @ObservedObject var server: RemoteHostServer
    @ObservedObject var client: RemoteMacClient

    @State private var hostInput = ""
    @State private var portInput = ""
    @State private var pinInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("This Mac (Allow Remote Control on Same Wi-Fi)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Share This Mac on Wi-Fi", isOn: Binding(
                                get: { server.isSharing },
                                set: { server.toggleSharing($0) }
                            ))
                            Spacer()
                            Text(server.statusText)
                                .font(.caption)
                                .foregroundStyle(server.isSharing ? .green : .secondary)
                        }

                        if server.isSharing {
                            HStack(spacing: 16) {
                                if let ip = RemoteHostServer.localIPAddress() {
                                    Text("Address: **\(ip):\(server.port)**")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                Text("Pairing PIN: **\(server.pairingPIN)**")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("New PIN") {
                                    server.regeneratePIN()
                                }
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Connect to Another Mac on Same Wi-Fi") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Mac IP (e.g. 192.168.1.25)", text: $hostInput)
                                .textFieldStyle(.roundedBorder)
                            TextField("Port", text: $portInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            TextField("6-digit PIN", text: $pinInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)

                            if client.isConnected {
                                Button("Disconnect", role: .destructive) {
                                    client.disconnect()
                                }
                            } else {
                                Button("Connect") {
                                    client.connect(host: hostInput, port: Int(portInput) ?? 0, pin: pinInput)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(hostInput.isEmpty || Int(portInput) == nil || pinInput.isEmpty)
                            }
                        }

                        HStack {
                            Button {
                                if client.isScanning {
                                    client.stopDiscovery()
                                } else {
                                    client.startDiscovery()
                                }
                            } label: {
                                Label(client.isScanning ? "Scanning Wi-Fi..." : "Scan Wi-Fi Macs", systemImage: "laptopcomputer.and.iphone")
                            }
                            if client.isScanning {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                            if let err = client.errorMessage {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        if !client.discoveredMacs.isEmpty {
                            Divider()
                            ForEach(client.discoveredMacs) { mac in
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                        .foregroundStyle(.blue)
                                    Text(mac.name).fontWeight(.medium)
                                    Text("\(mac.host):\(mac.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Select") {
                                        hostInput = mac.host
                                        portInput = String(mac.port)
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
                }

                if let snap = client.remoteSnapshot {
                    GroupBox("Remote Mac: \(snap.hostName) (\(client.connectedEndpoint))") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("RAM: \(formatBytes(snap.usedBytes)) / \(formatBytes(snap.totalBytes))")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    client.sendAction(path: "/low-ram")
                                } label: {
                                    Label("Free RAM Now (Remote)", systemImage: "bolt.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }

                            ProgressView(value: snap.totalBytes > 0 ? Double(snap.usedBytes) / Double(snap.totalBytes) : 0)
                                .tint(.blue)

                            Divider()

                            Text("Remote Running Apps (\(snap.apps.count))")
                                .font(.subheadline.bold())
                            ForEach(snap.apps.prefix(10)) { app in
                                HStack {
                                    Text(app.name)
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
                                        client.sendAction(path: "/quit-app", body: ["pid": app.pid, "force": false])
                                    }
                                    .disabled(app.isProtected)
                                }
                            }

                            if !snap.services.isEmpty {
                                Divider()
                                Text("Remote Databases & Background")
                                    .font(.subheadline.bold())
                                ForEach(snap.services) { svc in
                                    HStack {
                                        Circle()
                                            .fill(svc.isRunning ? Color.green : Color.gray.opacity(0.4))
                                            .frame(width: 8, height: 8)
                                        Text(svc.name)
                                        Spacer()
                                        Button(svc.isRunning ? "Turn Off" : "Turn On") {
                                            client.sendAction(path: "/toggle-service", body: ["id": svc.id])
                                        }
                                    }
                                }
                            }

                            if !snap.volumes.isEmpty {
                                Divider()
                                Text("Remote Drives")
                                    .font(.subheadline.bold())
                                ForEach(snap.volumes) { vol in
                                    HStack {
                                        Image(systemName: vol.isNetwork ? "wifi" : (vol.isExternal ? "externaldrive.fill" : "internaldrive.fill"))
                                        Text(vol.name)
                                        Spacer()
                                        Text("\(formatBytes(vol.availableBytes)) free")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if vol.isExternal {
                                            Button("Eject") {
                                                client.sendAction(path: "/eject-volume", body: ["mountPath": vol.mountPath])
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding()
        }
    }
}
