import AppKit
import Combine
import SwiftUI
import WattMeterCore
import WattMeterUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PowerStore()
    private let loginItem = LoginItemController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 单实例：避免重复启动时出现多个菜单栏图标
        let bundleID = Bundle.main.bundleIdentifier ?? "com.wattmeter.app"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.terminate()
        }

        setupStatusItem()
        setupPopover()
        store.start()

        store.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] reading in
                self?.updateStatusItem(reading)
            }
            .store(in: &cancellables)

        if CommandLine.arguments.contains("--show-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openMainWindow()
            }
        }

        if CommandLine.arguments.contains("--diag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.printDiagnostics()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.title = "—W"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = L("WattMeter — 实时功率")
    }

    private func updateStatusItem(_ reading: PowerReading?) {
        guard let button = statusItem.button else { return }
        guard let reading else {
            button.title = "—W"
            statusItem.length = NSStatusItem.variableLength
            return
        }
        let title = PowerFormat.watts(reading.totalW) + "W"
        button.title = title
        // 按文字宽度自适应，避免菜单栏里出现过多空白
        let width = (title as NSString).size(withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: 11)]).width
        statusItem.length = ceil(width) + 6
        var tip = "WattMeter · " + L("整机") + " " + PowerFormat.wattsWithUnit(reading.totalW)
        tip += " · " + L("电源") + " " + PowerFormat.wattsWithUnit(reading.adapterToLoadW)
        tip += " · " + L("电池") + " " + PowerFormat.wattsWithUnit(reading.batteryToLoadW)
        if let rails = reading.inputRailsText {
            tip += " · " + L("输入") + " " + rails
        }
        if let cpu = reading.cpuTempC {
            tip += " · CPU \(String(format: "%.0f°C", cpu))"
        }
        if let fan = reading.fanRPM {
            tip += " · " + L("风扇") + " \(String(format: "%.0f RPM", fan))"
        }
        button.toolTip = tip
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        loginItem.refresh()

        let openItem = NSMenuItem(title: L("打开主窗口"), action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let loginText = loginItem.requiresApproval
            ? L("开机自动启动（等待系统批准…）")
            : L("开机自动启动")
        let loginMenuItem = NSMenuItem(title: loginText, action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        loginMenuItem.state = loginItem.enabled ? .on : .off
        menu.addItem(loginMenuItem)

        // 语言切换
        let languageItem = NSMenuItem(title: L("关于语言"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.nativeName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = (Localization.shared.language == language) ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("退出 WattMeter"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    // MARK: - 弹出面板

    private func setupPopover() {
        let root = DashboardView(
            store: store,
            loginItem: loginItem,
            onOpenWindow: { [weak self] in self?.openMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        let controller = NSHostingController(rootView: root)
        controller.preferredContentSize = NSSize(width: 400, height: 680)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 400, height: 680)
        popover.contentViewController = controller
        self.popover = popover
    }

    private func togglePopover() {
        loginItem.refresh()
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.start()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 主窗口

    @objc private func openMainWindow() {
        if popover.isShown { popover.performClose(nil) }

        if mainWindow == nil {
            let controller = NSHostingController(rootView: MainWindowView(store: store, scrollable: true))
            let window = NSWindow(contentViewController: controller)
            window.title = "WattMeter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // 内容实测高度约 820pt；按真实内容开窗，避免底部被裁掉。
            // 用户手动缩小时由 MainWindowView 的 ScrollView 兜底。
            window.setContentSize(NSSize(width: 1020, height: 832))
            window.minSize = NSSize(width: 960, height: 600)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            mainWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)

        if CommandLine.arguments.contains("--show-window"), let window = mainWindow {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let report = "frame=\(window.frame) content=\(window.contentLayoutRect) screenVisible=\(screen)"
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
            try? report.write(toFile: "/tmp/wattmeter-window.txt", atomically: true, encoding: .utf8)
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        Localization.shared.setLanguage(language)
    }

    @objc private func toggleLoginItem() {
        // 等待系统批准时，直接带用户去「登录项」设置
        if loginItem.requiresApproval {
            loginItem.openSystemSettings()
            return
        }
        if !loginItem.setEnabled(!loginItem.enabled) {
            let alert = NSAlert()
            alert.messageText = L("无法修改开机自动启动")
            alert.informativeText = loginItem.lastError ?? L("未知错误。可以把 WattMeter.app 放到「应用程序」文件夹后再试。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 诊断（--diag）

    private func printDiagnostics() {
        guard let button = statusItem.button else {
            print("diag: statusItem.button == nil（状态项创建失败）")
            exit(2)
        }
        let window = button.window
        print("diag: statusItem button.title=\"\(button.title)\" frame=\(button.frame)")
        print("diag: statusItem button.window=\(window != nil ? "存在" : "nil") frame=\(String(describing: window?.frame)) visible=\(window?.isVisible ?? false)")
        print("diag: statusBar thickness=\(NSStatusBar.system.thickness)")
        if let latest = store.latest {
            print("diag: reading total=\(String(format: "%.1f", latest.totalW))W source=\(latest.source.label) samples=\(store.history.count)")
        } else {
            print("diag: 还没有读数")
        }
        exit(0)
    }
}
