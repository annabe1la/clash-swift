import Foundation

/// 订阅下载（捕获 subscription-userinfo 头）+ 元数据持久化（state/subscriptions.json，按文件名索引）。
struct SubscriptionService {
    private let workingDirectory: WorkingDirectoryManager

    init(workingDirectory: WorkingDirectoryManager) {
        self.workingDirectory = workingDirectory
    }

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

    /// 下载订阅内容并解析流量头。
    func download(from url: URL) async throws -> (data: Data, userInfo: SubscriptionUserInfo?) {
        var request = URLRequest(url: url)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.statusCode(http.statusCode,
                                      HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        let headerValue = (http.value(forHTTPHeaderField: "subscription-userinfo")
            ?? http.value(forHTTPHeaderField: "Subscription-Userinfo"))
        let info = headerValue.flatMap(SubscriptionUserInfo.parse)
        return (data, info)
    }
}
