import Foundation
import ServiceManagement

/// 开机自动启动（登录项）控制器。
///
/// 使用 macOS 13+ 的 `SMAppService.mainApp`，无需 root、无需辅助进程。
/// 注册后系统可能要求用户在「系统设置 → 通用 → 登录项」里批准，
/// 此时状态为 `.requiresApproval`，我们会引导用户去授权。
public final class LoginItemController: ObservableObject {
    @Published public private(set) var enabled: Bool = false
    @Published public private(set) var requiresApproval: Bool = false
    @Published public private(set) var lastError: String?

    public init() {
        refresh()
    }

    /// 重新读取系统里的真实状态（用户可能在系统设置里手动改过）
    public func refresh() {
        let status = SMAppService.mainApp.status
        enabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    /// 当前状态的人类可读描述
    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered: return "未启用"
        case .notFound: return "系统未找到该应用"
        @unknown default: return "未知"
        }
    }

    /// 打开 / 关闭开机自启。返回是否操作成功。
    @discardableResult
    public func setEnabled(_ value: Bool) -> Bool {
        lastError = nil
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            // 首次注册通常需要用户到系统设置里批准
            if requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
    }

    public func toggle() {
        setEnabled(!enabled)
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 命令行诊断用：`--login-item status|enable|disable|open-settings`
    public func handleCommandLine() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--login-item"), index + 1 < args.count else { return }
        switch args[index + 1] {
        case "status":
            print("login-item: \(statusDescription) (enabled=\(enabled), requiresApproval=\(requiresApproval))")
        case "enable":
            print(setEnabled(true) ? "login-item: enable ok → \(statusDescription)" : "login-item: enable failed: \(lastError ?? "unknown")")
        case "disable":
            print(setEnabled(false) ? "login-item: disable ok → \(statusDescription)" : "login-item: disable failed: \(lastError ?? "unknown")")
        case "open-settings":
            openSystemSettings()
            print("login-item: opened System Settings")
        default:
            print("用法: --login-item status|enable|disable|open-settings")
        }
        exit(0)
    }
}
