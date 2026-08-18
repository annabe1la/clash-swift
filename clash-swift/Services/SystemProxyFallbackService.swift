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
        let NS = "/usr/sbin/networksetup"
        let stateCmds: String
        if enabled {
            stateCmds = """
            \(NS) -setwebproxy "$svc" \(host) \(port)
            \(NS) -setsecurewebproxy "$svc" \(host) \(port)
            \(NS) -setsocksfirewallproxy "$svc" \(host) \(port)
            \(NS) -setwebproxystate "$svc" on
            \(NS) -setsecurewebproxystate "$svc" on
            \(NS) -setsocksfirewallproxystate "$svc" on
            """
        } else {
            stateCmds = """
            \(NS) -setwebproxystate "$svc" off
            \(NS) -setsecurewebproxystate "$svc" off
            \(NS) -setsocksfirewallproxystate "$svc" off
            """
        }
        // 绝对路径、不用 set -e（单条失败不整体中断）；对检测到的主服务操作，
        // 若检测不到则对所有已启用服务都设一遍（best-effort）。
        return """
        #!/bin/bash
        dev=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
        svc=$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v dev="$dev" '/Hardware Port/ { name=$0; sub(/.*Hardware Port: /,"",name); sub(/, Device.*/,"",name) } $0 ~ ("Device: " dev ")") { print name; exit }')
        if [ -n "$svc" ]; then
        \(stateCmds)
        else
          /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r svc; do
        \(stateCmds)
          done
        fi
        exit 0
        """
    }

    private func runAsAdmin(shellPath: String) throws {
        // 用 osascript 子进程执行（可在后台线程可靠弹授权框，NSAppleScript 有主线程限制）。
        // shell 路径含空格(Application Support)，必须单引号包裹。
        let inner = "/bin/bash '\(shellPath)'"
        let appleScript = "do shell script \"\(inner)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw SystemProxyFallbackError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if msg.contains("-128") || msg.lowercased().contains("cancel") {
                throw SystemProxyFallbackError.authorizationCancelled
            }
            throw SystemProxyFallbackError.commandFailed(msg.isEmpty ? "exit \(process.terminationStatus)" : msg)
        }
    }
}
