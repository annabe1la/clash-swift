import Foundation

/// 机场订阅流量信息（来自下载响应头 subscription-userinfo）。
struct SubscriptionUserInfo: Codable, Equatable {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Int64?     // unix 秒

    var used: Int64 { (self.upload ?? 0) + (self.download ?? 0) }

    /// 解析形如 "upload=1; download=2; total=3; expire=1700000000"
    static func parse(_ header: String) -> SubscriptionUserInfo? {
        var info = SubscriptionUserInfo()
        var any = false
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2, let value = Int64(kv[1]) else { continue }
            any = true
            switch kv[0].lowercased() {
            case "upload": info.upload = value
            case "download": info.download = value
            case "total": info.total = value
            case "expire": info.expire = value
            default: break
            }
        }
        return any ? info : nil
    }
}

/// 每个订阅配置的元数据：来源 URL、流量信息、更新时间。
struct SubscriptionMeta: Codable, Equatable {
    var url: String
    var userInfo: SubscriptionUserInfo?
    var updatedAt: Date?
}
