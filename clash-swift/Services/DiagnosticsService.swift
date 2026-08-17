import Foundation

/// 系统上一个 clash/mihomo 内核进程。
struct CoreProcessInfo: Identifiable, Equatable {
    let pid: Int32
    let command: String
    let ports: [Int]
    var id: Int32 { self.pid }
}

/// 单类代理（http/https/socks）的系统设置读数。
struct ProxyEntry: Equatable {
    let enabled: Bool
    let server: String
    let port: Int
}

/// 系统代理状态读数。
struct SystemProxyReadout: Equatable {
    let service: String
    let http: ProxyEntry?
    let https: ProxyEntry?
    let socks: ProxyEntry?

    var anyEnabled: Bool {
        [self.http, self.https, self.socks].contains { $0?.enabled == true }
    }
}

/// 诊断：扫描内核进程（防冲突）、读系统代理指向。全部走只读 shell 命令，无需管理员。
struct DiagnosticsService: Sendable {
    // MARK: 内核进程扫描

    func scanCores() -> [CoreProcessInfo] {
        let psOut = Self.run("/bin/ps", ["-axo", "pid=,args="])
        let portsByPID = Self.listenPortsByPID()
        var result: [CoreProcessInfo] = []
        for rawLine in psOut.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            guard let pid = Int32(line[..<space]) else { continue }
            let args = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let lower = args.lowercased()
            // 命中 mihomo/clash 内核，排除本 App 自身与我们的 GUI 进程
            let isCore = (lower.contains("mihomo") || lower.contains("clash"))
                && !lower.contains("clash-swift")
                && !lower.contains("clash swift")
                && !lower.contains("clashx")
                && !lower.contains(".app/contents/macos") // 排除各种 clash GUI app 本体（只关心内核可执行）
            guard isCore else { continue }
            result.append(CoreProcessInfo(pid: pid, command: args, ports: (portsByPID[pid] ?? []).sorted()))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// lsof 列出监听端口 → [pid: ports]。root 拥有的进程无 sudo 可能不可见（端口留空）。
    private static func listenPortsByPID() -> [Int32: Set<Int>] {
        let out = Self.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
        var map: [Int32: Set<Int>] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, let pid = Int32(cols[1]) else { continue }
            // NAME 列形如 "127.0.0.1:7890 (LISTEN)"——末列可能是 "(LISTEN)"，
            // 取最后一个含 host:port 且端口为整数的列。
            for col in cols.reversed() {
                let token = String(col)
                guard let colon = token.lastIndex(of: ":"),
                      let port = Int(token[token.index(after: colon)...])
                else { continue }
                map[pid, default: []].insert(port)
                break
            }
        }
        return map
    }

    // MARK: 系统代理读数

    func readSystemProxyState() -> SystemProxyReadout {
        let service = Self.primaryService()
        return SystemProxyReadout(
            service: service,
            http: Self.parseProxy(Self.run("/usr/sbin/networksetup", ["-getwebproxy", service])),
            https: Self.parseProxy(Self.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])),
            socks: Self.parseProxy(Self.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])))
    }

    private static func primaryService() -> String {
        let route = Self.run("/sbin/route", ["-n", "get", "default"])
        var dev = ""
        for line in route.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                dev = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard !dev.isEmpty else { return "Wi-Fi" }
        let order = Self.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        var currentName = ""
        for line in order.split(separator: "\n") {
            let s = String(line)
            if let range = s.range(of: "Hardware Port: ") {
                var name = String(s[range.upperBound...])
                if let comma = name.range(of: ", Device:") { name = String(name[..<comma.lowerBound]) }
                currentName = name.trimmingCharacters(in: .whitespaces)
            }
            if s.contains("Device: \(dev))") { return currentName }
        }
        return "Wi-Fi"
    }

    /// 解析 networksetup -getwebproxy 输出。
    private static func parseProxy(_ output: String) -> ProxyEntry? {
        var enabled = false, server = "", port = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = parts[1].lowercased() == "yes"
            case "Server": server = parts[1]
            case "Port": port = Int(parts[1]) ?? 0
            default: break
            }
        }
        if server.isEmpty, !enabled { return nil }
        return ProxyEntry(enabled: enabled, server: server, port: port)
    }

    // MARK: 结束进程（管理员）

    /// 以管理员权限结束进程（用于 root 拥有的内核/特权服务）。弹一次授权。
    func killElevated(pid: Int32) -> Bool {
        let source = "do shell script \"/bin/kill -TERM \(pid)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: shell

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
