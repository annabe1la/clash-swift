import Foundation

/// 订阅下载结果（正文已规整为合法 clash YAML）。
struct SubscriptionDownloadResult {
    let data: Data
    let userInfo: SubscriptionUserInfo?
    let suggestedName: String?        // 来自 Content-Disposition，机场名
    let updateIntervalHours: Int?     // 来自 profile-update-interval
}

/// 订阅下载与解析，参考 clash-verge-rev 做健壮化：
/// - 默认 UA `clash-verge/v{版本}`，并按多 UA 依次重试（机场常按 UA 返回不同格式）
/// - URL 内嵌 user:pass 转 Basic Auth
/// - 解析 *subscription-userinfo（后缀匹配，兼容对象存储前缀）、Content-Disposition 文件名、profile-update-interval
/// - 校验：去 BOM → 必须含 proxies/proxy-providers；否则尝试 base64 解码兜底；仍不行给出分类错误
/// - 元数据持久化 state/subscriptions.json（按文件名索引）
struct SubscriptionService {
    private let workingDirectory: WorkingDirectoryManager

    init(workingDirectory: WorkingDirectoryManager) {
        self.workingDirectory = workingDirectory
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// 依次尝试的 UA（覆盖不同机场的 UA 白名单）。
    private static var userAgents: [String] {
        ["clash-verge/v\(appVersion)", "clash.meta", "mihomo", "clash"]
    }

    // MARK: 持久化

    private var storeURL: URL {
        self.workingDirectory.stateDirectoryURL
            .appendingPathComponent("subscriptions.json", isDirectory: false)
    }

    func load() -> [String: SubscriptionMeta] {
        guard let data = try? Data(contentsOf: self.storeURL),
              let map = try? JSONDecoder().decode([String: SubscriptionMeta].self, from: data)
        else { return [:] }
        return map
    }

    func save(_ map: [String: SubscriptionMeta]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: self.storeURL, options: .atomic)
        }
    }

    // MARK: 下载

    func download(from url: URL) async throws -> SubscriptionDownloadResult {
        var lastPreview = ""
        for (index, ua) in Self.userAgents.enumerated() {
            let (raw, http) = try await self.fetch(url: url, userAgent: ua)
            if let normalized = Self.normalizeToClash(raw) {
                return SubscriptionDownloadResult(
                    data: normalized,
                    userInfo: Self.parseUserInfo(from: http),
                    suggestedName: Self.parseFilename(from: http),
                    updateIntervalHours: Self.parseUpdateInterval(from: http))
            }
            lastPreview = String(data: raw.prefix(400), encoding: .utf8) ?? "<二进制数据>"
            _ = index
        }
        throw Self.contentError(preview: lastPreview)
    }

    /// 单次请求（含 Basic Auth、重定向由 URLSession 默认跟随）。
    private func fetch(url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
        var cleanURL = url
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        // URL 内嵌 user:pass → Authorization: Basic
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let user = comps.user
        {
            let pass = comps.password ?? ""
            if let token = "\(user):\(pass)".data(using: .utf8)?.base64EncodedString() {
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
            var stripped = comps
            stripped.user = nil
            stripped.password = nil
            if let u = stripped.url { cleanURL = u; request.url = u }
        }
        _ = cleanURL

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionError.network(L("无响应", "no response"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw SubscriptionError.status(http.statusCode)
        }
        return (data, http)
    }

    // MARK: 内容规整 / 校验

    /// 去 BOM → 判断是否 clash；否则 base64 兜底解码；都不行返回 nil。
    static func normalizeToClash(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeClash(cleaned) { return Data(cleaned.utf8) }

        // base64 兜底（部分机场返回 base64 编码的 clash 配置）
        let compact = cleaned.filter { !$0.isWhitespace }
        if let decoded = Data(base64Encoded: compact),
           let dtext = String(data: decoded, encoding: .utf8),
           Self.looksLikeClash(dtext)
        {
            return Data(dtext.utf8)
        }
        return nil
    }

    static func looksLikeClash(_ text: String) -> Bool {
        text.contains("proxies:") || text.contains("proxy-providers:")
    }

    /// 分类内容错误，给出可读提示。
    private static func contentError(preview: String) -> SubscriptionError {
        let lower = preview.lowercased()
        if lower.contains("<html") || lower.hasPrefix("<") {
            return .content(L("服务器返回的是网页而非 Clash 配置（可能链接错误或需要登录）。",
                              "Server returned a web page, not a Clash config."))
        }
        for scheme in ["ss://", "ssr://", "vmess://", "vless://", "trojan://"] where lower.contains(scheme) {
            return .content(L("这是节点订阅（SS/V2Ray），不是 Clash 配置。请使用机场的 Clash 订阅链接。",
                              "This is a node subscription (SS/V2Ray), not a Clash config. Use the Clash subscription URL."))
        }
        return .content(L("下载的内容不是合法的 Clash 配置（缺少 proxies / proxy-providers）。",
                          "Downloaded content is not a valid Clash config (missing proxies / proxy-providers)."))
    }

    // MARK: 响应头解析

    private static func parseUserInfo(from http: HTTPURLResponse) -> SubscriptionUserInfo? {
        for (key, value) in http.allHeaderFields {
            guard let k = (key as? String)?.lowercased(),
                  k.hasSuffix("subscription-userinfo"),
                  let v = value as? String
            else { continue }
            if let info = SubscriptionUserInfo.parse(v) { return info }
        }
        return nil
    }

    private static func parseUpdateInterval(from http: HTTPURLResponse) -> Int? {
        guard let v = http.value(forHTTPHeaderField: "profile-update-interval"),
              let hours = Int(v.trimmingCharacters(in: .whitespaces)), hours > 0
        else { return nil }
        return hours
    }

    /// Content-Disposition → 文件名（filename* 优先，其次 filename）。
    private static func parseFilename(from http: HTTPURLResponse) -> String? {
        guard let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        // filename*=utf-8''xxx
        if let range = disposition.range(of: "filename*=", options: .caseInsensitive) {
            var value = String(disposition[range.upperBound...])
            if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if let quote = value.range(of: "''") { value = String(value[quote.upperBound...]) }
            if let decoded = value.removingPercentEncoding, !decoded.isEmpty {
                return Self.sanitize(decoded)
            }
        }
        // filename="xxx"
        if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
            var value = String(disposition[range.upperBound...])
            if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
            value = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let decoded = value.removingPercentEncoding ?? value
            if !decoded.isEmpty { return Self.sanitize(decoded) }
        }
        return nil
    }

    /// 清洗文件名并确保 .yaml 后缀。
    static func sanitize(_ name: String) -> String {
        var base = name
        for ext in [".yaml", ".yml"] where base.lowercased().hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
        }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
            .union(CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")) // 允许中文
        let filtered = String(base.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let final = filtered.isEmpty ? "subscription" : filtered
        return "\(final).yaml"
    }
}

enum SubscriptionError: LocalizedError {
    case network(String)
    case status(Int)
    case content(String)

    var errorDescription: String? {
        switch self {
        case let .network(msg): "\(L("网络错误", "Network error"))：\(msg)"
        case let .status(code): "\(L("下载失败，HTTP", "Download failed, HTTP")) \(code)"
        case let .content(msg): msg
        }
    }
}
