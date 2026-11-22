import Foundation

enum ServiceManager {
    static func fetchServices(processes: [ProcessInfoRow]) -> [ServiceItem] {
        var items: [ServiceItem] = []

        // 1. MySQL (/usr/local/mysql)
        let mysqlProc = processes.first { $0.command.contains("/mysqld") }
        let hasMySQLServerScript = FileManager.default.isExecutableFile(atPath: "/usr/local/mysql/support-files/mysql.server")
        if mysqlProc != nil || hasMySQLServerScript {
            let isRoot = mysqlProc?.user == "root" || mysqlProc?.user == "_mysql" || hasMySQLServerScript
            items.append(
                ServiceItem(
                    id: "service-mysql",
                    name: "MySQL Server (mysqld)",
                    category: "Database",
                    pid: mysqlProc?.pid,
                    rssBytes: mysqlProc?.rssBytes ?? 0,
                    isRunning: mysqlProc != nil,
                    requiresAdmin: isRoot,
                    stopCommand: hasMySQLServerScript
                        ? "/usr/local/mysql/support-files/mysql.server stop"
                        : "killall mysqld",
                    startCommand: hasMySQLServerScript
                        ? "/usr/local/mysql/support-files/mysql.server start"
                        : "mysqld"
                )
            )
        }

        // 2. OpenClaw Gateway
        let openclawProc = processes.first { $0.command.contains("openclaw-gateway") }
        let openclawPlist = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/ai.openclaw.gateway.plist")
        if openclawProc != nil || openclawPlist {
            items.append(
                ServiceItem(
                    id: "service-openclaw",
                    name: "OpenClaw Gateway",
                    category: "Background Agent",
                    pid: openclawProc?.pid,
                    rssBytes: openclawProc?.rssBytes ?? 0,
                    isRunning: openclawProc != nil,
                    requiresAdmin: false,
                    stopCommand: openclawPlist
                        ? "launchctl unload ~/Library/LaunchAgents/ai.openclaw.gateway.plist || pkill -f openclaw-gateway"
                        : "pkill -f openclaw-gateway",
                    startCommand: openclawPlist
                        ? "launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist"
                        : "openclaw-gateway"
                )
            )
        }

        // 3. Homebrew services (postgres, redis, mongodb, etc.)
        if let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            let brewOut = SystemMonitor.runShell("\(brewPath) services list 2>/dev/null | tail -n +2")
            for line in brewOut.split(separator: "\n") {
                let cols = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard cols.count >= 2 else { continue }
                let svcName = String(cols[0])
                let status = String(cols[1]).lowercased()
                if svcName == "mysql" && items.contains(where: { $0.id == "service-mysql" }) {
                    continue
                }
                let isRunning = status == "started"
                let proc = processes.first { $0.command.lowercased().contains(svcName.lowercased()) }
                items.append(
                    ServiceItem(
                        id: "brew-\(svcName)",
                        name: "\(svcName) (Homebrew)",
                        category: isDatabaseName(svcName) ? "Database" : "Background Service",
                        pid: proc?.pid,
                        rssBytes: proc?.rssBytes ?? 0,
                        isRunning: isRunning,
                        requiresAdmin: false,
                        stopCommand: "\(brewPath) services stop \(svcName)",
                        startCommand: "\(brewPath) services start \(svcName)"
                    )
                )
            }
        }

        // 4. Other common background dev daemons if currently running (GradleDaemon, Ollama, Docker, Postgres, Redis)
        let extraPatterns: [(id: String, match: String, label: String, category: String)] = [
            ("proc-gradle", "GradleDaemon", "Gradle Daemon", "Build Background"),
            ("proc-ollama", "ollama", "Ollama LLM Server", "Background AI"),
            ("proc-postgres", "postgres", "PostgreSQL", "Database"),
            ("proc-redis", "redis-server", "Redis Server", "Database"),
            ("proc-mongod", "mongod", "MongoDB", "Database")
        ]
        for pat in extraPatterns {
            let matching = processes.filter { $0.command.contains(pat.match) }
            guard !matching.isEmpty else { continue }
            if items.contains(where: { $0.name.lowercased().contains(pat.match.lowercased()) }) { continue }
            let totalRSS = matching.reduce(UInt64(0)) { $0 + $1.rssBytes }
            let pids = matching.map { String($0.pid) }.joined(separator: " ")
            items.append(
                ServiceItem(
                    id: pat.id,
                    name: pat.label,
                    category: pat.category,
                    pid: matching.first?.pid,
                    rssBytes: totalRSS,
                    isRunning: true,
                    requiresAdmin: false,
                    stopCommand: "kill \(pids)",
                    startCommand: ""
                )
            )
        }

        return items.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            return $0.rssBytes > $1.rssBytes
        }
    }

    static func toggleService(_ service: ServiceItem) {
        let cmd = service.isRunning ? service.stopCommand : service.startCommand
        guard !cmd.isEmpty else { return }

        if service.requiresAdmin {
            let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", appleScript]
            try? task.run()
            task.waitUntilExit()
        } else {
            SystemMonitor.runShell(cmd)
        }
    }

    private static func isDatabaseName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("sql") || lower.contains("redis") || lower.contains("mongo") || lower.contains("mariadb")
    }
}
