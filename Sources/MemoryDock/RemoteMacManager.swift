import Foundation
import Network

struct RemoteAppDTO: Codable, Identifiable, Sendable {
    let pid: Int32
    let name: String
    let rssBytes: UInt64
    let isProtected: Bool
    var id: Int32 { pid }
}

struct RemoteServiceDTO: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let rssBytes: UInt64
    let isRunning: Bool
}

struct RemoteVolumeDTO: Codable, Identifiable, Sendable {
    let mountPath: String
    let name: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let isExternal: Bool
    let isNetwork: Bool
    var id: String { mountPath }
}

struct RemoteMacSnapshot: Codable, Sendable {
    let hostName: String
    let totalBytes: UInt64
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let apps: [RemoteAppDTO]
    let services: [RemoteServiceDTO]
    let volumes: [RemoteVolumeDTO]
}

struct DiscoveredRemoteMac: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: Int
}

@MainActor
final class RemoteHostServer: ObservableObject {
    @Published var isSharing = false
    @Published var port: UInt16 = 0
    @Published var pairingPIN: String = RemoteHostServer.generatePIN()
    @Published var statusText: String = "Off"

    private var listener: NWListener?
    private weak var viewModel: AppViewModel?

    init(viewModel: AppViewModel? = nil) {
        self.viewModel = viewModel
    }

    func attach(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func regeneratePIN() {
        pairingPIN = Self.generatePIN()
    }

    func toggleSharing(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params)
            let hostName = Host.current().localizedName ?? "Mac"
            listener.service = NWListener.Service(name: hostName, type: "_memorydock._tcp")

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        self.isSharing = true
                        self.statusText = "Listening on port \(self.port)"
                    case .failed(let err):
                        self.isSharing = false
                        self.statusText = "Failed: \(err.localizedDescription)"
                    case .cancelled:
                        self.isSharing = false
                        self.statusText = "Off"
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.handleConnection(conn)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            isSharing = false
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isSharing = false
        port = 0
        statusText = "Off"
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    conn.cancel()
                    return
                }
                let response = self.processHTTPRequest(raw)
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    private func processHTTPRequest(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerLines = (parts.first ?? "").components(separatedBy: "\r\n")
        let body = parts.count > 1 ? parts[1] : ""
        guard let requestLine = headerLines.first else {
            return httpResponse(status: "400 Bad Request", json: "{\"error\":\"Bad request\"}")
        }
        let reqTokens = requestLine.split(separator: " ")
        guard reqTokens.count >= 2 else {
            return httpResponse(status: "400 Bad Request", json: "{\"error\":\"Bad request\"}")
        }
        let method = String(reqTokens[0])
        let path = String(reqTokens[1])

        // Verify Pairing PIN
        let pinHeader = headerLines.first { $0.lowercased().hasPrefix("x-memorydock-pin:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard pinHeader == pairingPIN else {
            return httpResponse(status: "401 Unauthorized", json: "{\"error\":\"Invalid PIN\"}")
        }

        guard let vm = viewModel else {
            return httpResponse(status: "503 Service Unavailable", json: "{\"error\":\"Unavailable\"}")
        }

        if method == "GET" && path == "/status" {
            let snap = RemoteMacSnapshot(
                hostName: Host.current().localizedName ?? "Mac",
                totalBytes: vm.snapshot.totalBytes,
                usedBytes: vm.snapshot.usedBytes,
                compressedBytes: vm.snapshot.compressedBytes,
                freeBytes: vm.snapshot.freeBytes + vm.snapshot.inactiveBytes,
                apps: vm.apps.map {
                    RemoteAppDTO(pid: $0.pid, name: $0.name, rssBytes: $0.rssBytes, isProtected: $0.isProtected)
                },
                services: vm.services.map {
                    RemoteServiceDTO(id: $0.id, name: $0.name, category: $0.category, rssBytes: $0.rssBytes, isRunning: $0.isRunning)
                },
                volumes: vm.volumes.map {
                    RemoteVolumeDTO(mountPath: $0.mountPath, name: $0.name, totalBytes: $0.totalBytes, availableBytes: $0.availableBytes, isExternal: $0.isExternal, isNetwork: $0.isNetwork)
                }
            )
            if let jsonData = try? JSONEncoder().encode(snap),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                return httpResponse(status: "200 OK", json: jsonStr)
            }
        } else if method == "POST" && path == "/low-ram" {
            vm.runLowRamMode()
            return httpResponse(status: "200 OK", json: "{\"ok\":true}")
        } else if method == "POST" && path == "/quit-app" {
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = obj["pid"] as? Int32 {
                let force = (obj["force"] as? Bool) ?? false
                if let app = vm.apps.first(where: { $0.pid == pid }) {
                    vm.quitApp(app, force: force)
                    return httpResponse(status: "200 OK", json: "{\"ok\":true}")
                }
            }
        } else if method == "POST" && path == "/toggle-service" {
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = obj["id"] as? String,
               let svc = vm.services.first(where: { $0.id == id }) {
                vm.toggleService(svc)
                return httpResponse(status: "200 OK", json: "{\"ok\":true}")
            }
        } else if method == "POST" && path == "/eject-volume" {
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mountPath = obj["mountPath"] as? String,
               let vol = vm.volumes.first(where: { $0.mountPath == mountPath }) {
                vm.ejectVolume(vol)
                return httpResponse(status: "200 OK", json: "{\"ok\":true}")
            }
        }

        return httpResponse(status: "404 Not Found", json: "{\"error\":\"Not found\"}")
    }

    private func httpResponse(status: String, json: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
    }

    private static func generatePIN() -> String {
        String(format: "%06d", Int.random(in: 100000...999999))
    }

    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let interface = ptr.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}

@MainActor
final class RemoteMacClient: ObservableObject {
    @Published var discoveredMacs: [DiscoveredRemoteMac] = []
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectedEndpoint: String = ""
    @Published var remoteSnapshot: RemoteMacSnapshot?
    @Published var errorMessage: String?

    private var browser: NWBrowser?
    private var activeHost: String = ""
    private var activePort: Int = 0
    private var activePIN: String = ""
    private var pollTimer: Timer?

    func startDiscovery() {
        stopDiscovery()
        discoveredMacs = []
        isScanning = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_memorydock._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        self.resolveEndpoint(name: name, type: type, domain: domain)
                    }
                }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser

        Task {
            try? await Task.sleep(for: .seconds(6))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    private func resolveEndpoint(name: String, type: String, domain: String) {
        let conn = NWConnection(to: .service(name: name, type: type, domain: domain, interface: nil), using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state,
               let inner = conn.currentPath?.remoteEndpoint,
               case let .hostPort(host, port) = inner {
                let hostStr = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                let portInt = Int(port.rawValue)
                conn.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let item = DiscoveredRemoteMac(id: "\(name)-\(hostStr)-\(portInt)", name: name, host: hostStr, port: portInt)
                    if !self.discoveredMacs.contains(where: { $0.id == item.id }) {
                        self.discoveredMacs.append(item)
                    }
                }
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func connect(host: String, port: Int, pin: String) {
        activeHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        activePort = port
        activePIN = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil

        Task {
            await fetchStatus()
            if remoteSnapshot != nil {
                isConnected = true
                connectedEndpoint = "\(activeHost):\(activePort)"
                startPolling()
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        isConnected = false
        remoteSnapshot = nil
        connectedEndpoint = ""
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchStatus()
            }
        }
    }

    func fetchStatus() async {
        guard !activeHost.isEmpty, activePort > 0,
              let url = URL(string: "http://\(activeHost):\(activePort)/status") else {
            errorMessage = "Invalid host or port."
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(activePIN, forHTTPHeaderField: "X-MemoryDock-PIN")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                errorMessage = "Invalid Pairing PIN."
                disconnect()
                return
            }
            let decoded = try JSONDecoder().decode(RemoteMacSnapshot.self, from: data)
            remoteSnapshot = decoded
            errorMessage = nil
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isConnected = false
        }
    }

    func sendAction(path: String, body: [String: Any] = [:]) {
        guard let url = URL(string: "http://\(activeHost):\(activePort)\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue(activePIN, forHTTPHeaderField: "X-MemoryDock-PIN")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            _ = try? await URLSession.shared.data(for: req)
            try? await Task.sleep(for: .milliseconds(600))
            await fetchStatus()
        }
    }
}
