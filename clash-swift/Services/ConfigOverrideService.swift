import Foundation
import Yams

/// 覆盖层服务：持久化 ConfigOverride，并将其深度合并进源配置生成 effective.yaml。
///
/// 设计对齐 clash-verge-rev 的 enhance 思路：
/// - 标量字段(port/allow-lan/ipv6/bind-address)直接覆盖顶层键；
/// - listeners 覆盖为自定义入站数组；
/// - processRules 以 prepend-rules 方式插到 rules 表最前(保证优先命中)，并确保 find-process-mode=always。
/// 生成后由内核 reload/restart 应用，保证重启后仍生效(区别于临时的 PATCH /configs)。
struct ConfigOverrideService {
    private let workingDirectory: WorkingDirectoryManager

    init(workingDirectory: WorkingDirectoryManager) {
        self.workingDirectory = workingDirectory
    }

    // MARK: 持久化

    private var overrideFileURL: URL {
        self.workingDirectory.stateDirectoryURL
            .appendingPathComponent("override.json", isDirectory: false)
    }

    func loadOverride() -> ConfigOverride {
        guard let data = try? Data(contentsOf: self.overrideFileURL),
              let override = try? JSONDecoder().decode(ConfigOverride.self, from: data)
        else { return ConfigOverride() }
        return override
    }

    func saveOverride(_ override: ConfigOverride) throws {
        let data = try JSONEncoder().encode(override)
        try data.write(to: self.overrideFileURL, options: .atomic)
    }

    // MARK: 生成 effective 配置

    var effectiveConfigURL: URL {
        self.workingDirectory.configDirectoryURL
            .appendingPathComponent(".effective.yaml", isDirectory: false)
    }

    /// 读取源配置 → 应用覆盖层 → 写出 effective.yaml，返回其 URL。
    @discardableResult
    func buildEffectiveConfig(from sourceURL: URL, override: ConfigOverride) throws -> URL {
        let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
        var root = (try Yams.load(yaml: sourceText) as? [String: Any]) ?? [:]

        // 标量入站
        if let v = override.mixedPort { root["mixed-port"] = v }
        if let v = override.httpPort { root["port"] = v }
        if let v = override.socksPort { root["socks-port"] = v }
        if let v = override.allowLan { root["allow-lan"] = v }
        if let v = override.ipv6 { root["ipv6"] = v }
        if let v = override.bindAddress, !v.isEmpty { root["bind-address"] = v }

        // TUN（保留源配置 tun 其余键，仅覆盖 enable，并补齐启用所需默认）
        if let tunOn = override.tunEnabled {
            var tun = (root["tun"] as? [String: Any]) ?? [:]
            tun["enable"] = tunOn
            if tunOn {
                if tun["stack"] == nil { tun["stack"] = "mixed" }
                if tun["auto-route"] == nil { tun["auto-route"] = true }
                if tun["auto-detect-interface"] == nil { tun["auto-detect-interface"] = true }
                if tun["dns-hijack"] == nil { tun["dns-hijack"] = ["any:53"] }
            }
            root["tun"] = tun
        }

        // 自定义 listeners
        if !override.listeners.isEmpty {
            root["listeners"] = override.listeners.map { listener -> [String: Any] in
                [
                    "name": listener.name,
                    "type": listener.type,
                    "port": listener.port,
                    "listen": listener.listen,
                ]
            }
        }

        // 按 App 分流：prepend 到 rules 前，并确保进程解析开启
        if !override.processRules.isEmpty {
            root["find-process-mode"] = "always"
            var rules = (root["rules"] as? [Any]) ?? []
            let prepend: [Any] = override.processRules.map { $0.ruleLine }
            rules.insert(contentsOf: prepend, at: 0)
            root["rules"] = rules
        }

        let dumped = try Yams.dump(object: root)
        let target = self.effectiveConfigURL
        try dumped.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
