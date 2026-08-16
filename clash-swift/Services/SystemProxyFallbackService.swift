import Foundation

enum SystemProxyFallbackError: LocalizedError {
    case scriptWriteFailed
    case authorizationCancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptWriteFailed: "无法写入代理设置脚本。"
        case .authorizationCancelled: "已取消管理员授权。"
        case let .commandFailed(message): "设置系统代理失败：\(message)"
        }
    }
}

/// 免签名系统代理后备：用管理员权限调用 networksetup 设置/清除主网络服务的 HTTP/HTTPS/SOCKS 代理。
/// 无需特权 helper，每次开关弹一次管理员密码。
struct SystemProxyFallbackService {
    private let workingDirectory: WorkingDirectoryManager

    init(workingDirectory: WorkingDirectoryManager) {
        self.workingDirectory = workingDirectory
    }

    /// enabled 时设置并开启代理；否则关闭。host/port 用于 web/secure/socks 三类。
    func apply(enabled: Bool, host: String, port: Int) throws {
        let script = self.buildShellScript(enabled: enabled, host: host, port: port)
        let scriptURL = self.workingDirectory.stateDirectoryURL
            .appendingPathComponent("setproxy.sh", isDirectory: false)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw SystemProxyFallbackError.scriptWriteFailed
        }
        try self.runAsAdmin(shellPath: scriptURL.path)
    }

    private func buildShellScript(enabled: Bool, host: String, port: Int) -> String {
        let stateCmds: String
        if enabled {
            stateCmds = """
            networksetup -setwebproxy "$svc" \(host) \(port)
            networksetup -setsecurewebproxy "$svc" \(host) \(port)
            networksetup -setsocksfirewallproxy "$svc" \(host) \(port)
            networksetup -setwebproxystate "$svc" on
            networksetup -setsecurewebproxystate "$svc" on
            networksetup -setsocksfirewallproxystate "$svc" on
            """
        } else {
            stateCmds = """
            networksetup -setwebproxystate "$svc" off
            networksetup -setsecurewebproxystate "$svc" off
            networksetup -setsocksfirewallproxystate "$svc" off
            """
        }
        return """
        #!/bin/bash
        set -e
        dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
        svc=$(networksetup -listnetworkserviceorder | awk -v dev="$dev" '
          /Hardware Port/ { name=$0; sub(/.*Hardware Port: /,"",name); sub(/, Device.*/,"",name) }
          $0 ~ ("Device: " dev ")") { print name; exit }')
        if [ -z "$svc" ]; then svc="Wi-Fi"; fi
        \(stateCmds)
        """
    }

    private func runAsAdmin(shellPath: String) throws {
        let appleScript = "do shell script \"/bin/bash \(shellPath)\" with administrator privileges"
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: appleScript) else {
            throw SystemProxyFallbackError.commandFailed("脚本构造失败")
        }
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            let code = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {
                throw SystemProxyFallbackError.authorizationCancelled
            }
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw SystemProxyFallbackError.commandFailed(message)
        }
    }
}
