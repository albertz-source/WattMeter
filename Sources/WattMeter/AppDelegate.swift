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
    private var aboutWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    // 菜单栏数字的健壮性状态
    private var lastTitle: String?
    private var lastUpdateAt = Date.distantPast
    private var statusWatchdog: Timer?
    private var statusMissingTicks = 0
    private var recreateAttempts = 0
    private var logEveryUpdate = false
    private var powerAssertion: NSObjectProtocol?
    private let statusLogURL = URL(fileURLWithPath: "/tmp/wattmeter-menubar.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 菜单栏常驻 App 没有窗口，系统默认会对它做 App Nap，Timer 被挂起后
        // 菜单栏数字就停住不动了。采样是核心功能，这里声明为活跃活动
        // （允许系统空闲休眠，不影响省电）。
        powerAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "WattMeter live power sampling")

        // 单实例：避免重复启动时出现多个菜单栏图标
        // （--diag 只是打印诊断后退出，不能顺手把正在运行的菜单栏 App 杀掉）
        if !CommandLine.arguments.contains("--diag") {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.wattmeter.app"
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.terminate()
            }
        }

        setupStatusItem()
        startStatusWatchdog()
        setupPopover()
        store.start()

        logEveryUpdate = CommandLine.arguments.contains("--menubar-log")
        if logEveryUpdate {
            try? FileManager.default.removeItem(at: statusLogURL)
            appendStatusLog("== menu bar log started ==")
        }

        // 自测开关：模拟系统把状态项摘掉，验证看门狗能把它恢复（开发用）
        if CommandLine.arguments.contains("--test-menubar-recovery") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.appendStatusLog("TEST: removing status item (simulated OS removal)")
                if let old = self.statusItem {
                    NSStatusBar.system.removeStatusItem(old)
                }
                self.statusItem = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self else { return }
                let title = self.statusItem?.button?.title ?? "nil"
                let window = self.statusItem?.button?.window != nil
                self.appendStatusLog("TEST: after recovery title=\(title) window=\(window) attempts=\(self.recreateAttempts)")
                print("recovery test: title=\(title) window=\(window) attempts=\(self.recreateAttempts)")
                exit(0)
            }
        }

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

    func applicationWillTerminate(_ notification: Notification) {
        if let powerAssertion {
            ProcessInfo.processInfo.endActivity(powerAssertion)
        }
        statusWatchdog?.invalidate()
        statusWatchdog = nil
    }

    // MARK: - 菜单栏

    /// 菜单栏字号：等宽数字，避免每秒刷新时数字左右抖动
    private static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private var menuBarMetric: MenuBarMetric {
        get {
            let raw = UserDefaults.standard.string(forKey: MenuBarMetric.defaultsKey)
            return raw.flatMap(MenuBarMetric.init(rawValue:)) ?? .adapterInput
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: MenuBarMetric.defaultsKey)
        }
    }

    private func setupStatusItem() {
        // 用 variableLength 交给 AppKit 自己量宽度。
        // 之前按字体手算 statusItem.length，一旦系统把按钮字形重置
        // （切显示器 / 换外观 / 菜单栏重排）或字号变化，数字就会被裁掉，
        // 表现就是「菜单栏不显示数字，但进程还在」。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "—W"
        button.font = Self.statusFont
        button.imagePosition = .noImage
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = L("WattMeter — 实时功率")
        button.setAccessibilityLabel("WattMeter")
    }

    /// 菜单栏显示的文字：默认是电源输入功率，可在右键菜单里切换口径
    private func statusTitle(for reading: PowerReading?) -> String {
        guard let reading else { return lastTitle ?? "—W" }
        let text = menuBarMetric.text(for: reading)
        if !text.isEmpty { return text }
        // 这个口径没有数值（例如台式机上的电池功率、刚插拔电源的瞬间）
        // → 回退到整机功耗，别让菜单栏空掉
        let fallback = MenuBarMetric.systemPower.text(for: reading)
        if !fallback.isEmpty { return fallback }
        return lastTitle ?? "—W"
    }

    private func updateStatusItem(_ reading: PowerReading?) {
        guard let item = statusItem, let button = item.button else {
            // 按钮没了（状态项被系统移除）→ 由看门狗重建
            statusMissingTicks += 1
            return
        }

        let title = statusTitle(for: reading)
        // 每次都校正字体：系统在切换显示器 / 外观 / 菜单栏重排后可能把按钮字形
        // 恢复成默认值，只写 title 会让宽度与字体不匹配。字体一致时不重复赋值，
        // 避免无谓的重绘。
        if button.font != Self.statusFont {
            button.font = Self.statusFont
        }
        if button.title != title {
            button.title = title
        }
        item.length = NSStatusItem.variableLength
        lastTitle = title
        lastUpdateAt = Date()

        guard let reading else {
            button.toolTip = L("WattMeter — 实时功率")
            if logEveryUpdate { logStatusLine(title: title, reading: nil) }
            return
        }

        let metric = menuBarMetric
        let shown = metric.value(for: reading).map { PowerFormat.wattsWithUnit($0) } ?? "—"
        var tip = "WattMeter · " + L(metric.title) + " " + shown
        tip += "\n" + L("整机") + " " + PowerFormat.wattsWithUnit(reading.totalW)
        tip += " · " + L("电源") + " " + PowerFormat.wattsWithUnit(reading.adapterToLoadW)
        tip += " · " + L("电池") + " " + PowerFormat.wattsWithUnit(reading.batteryToLoadW)
        if let health = reading.batteryHealthPercent {
            tip += " · " + L("健康度") + " " + String(format: "%.0f%%", health)
        }
        if let cycles = reading.batteryCycleCount {
            tip += " · " + localizedCycles(cycles)
        }
        if let input = reading.adapterInputW {
            tip += "\n" + L("适配器输入") + " " + PowerFormat.wattsWithUnit(input)
            if let walls = reading.wallPowerW {
                tip += " · " + L("墙插估算") + " " + PowerFormat.wattsWithUnit(walls)
            }
        }
        if let rails = reading.inputRailsText {
            tip += " · " + L("输入") + " " + rails
        }
        if let cpu = reading.cpuTempC {
            tip += " · CPU \(String(format: "%.0f°C", cpu))"
        }
        if let fan = reading.fanRPM {
            tip += " · " + L("风扇") + " \(String(format: "%.0f RPM", fan))"
        }
        if reading.hasDiskActivity {
            tip += "\n" + L("磁盘") + " " + L("读") + " " + reading.diskReadText
            tip += " · " + L("写") + " " + reading.diskWriteText
            tip += " · " + L("可用") + " " + reading.diskFreeText
        }
        tip += "\n" + L("右键可切换菜单栏数值")
        button.toolTip = tip

        if logEveryUpdate { logStatusLine(title: title, reading: reading) }
    }

    // MARK: - 菜单栏看门狗

    /// 有些情况下系统会把状态项从菜单栏里摘掉（菜单栏空间不足、切换显示器、
    /// 全屏 App 退出等），进程却还在跑。定期检查按钮是否还挂在窗口上，
    /// 连续两次丢失就重建状态项。
    private func startStatusWatchdog() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkStatusItem()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusWatchdog = timer
    }

    private func checkStatusItem() {
        guard let button = statusItem?.button, button.window != nil else {
            statusMissingTicks += 1
            appendStatusLog("status item missing (button.window == nil), tick \(statusMissingTicks)")
            if statusMissingTicks >= 2 {
                recreateStatusItem()
            }
            return
        }
        statusMissingTicks = 0
        // 超过 20 秒没刷新过，说明采样器被系统挂起了，提示一下
        if Date().timeIntervalSince(lastUpdateAt) > 20 {
            appendStatusLog("no update for \(Int(Date().timeIntervalSince(lastUpdateAt)))s")
        }
    }

    private func recreateStatusItem() {
        // 用户可能自己用 ⌘ 把图标拖掉了：连续重建几次还消失就不再打扰
        if recreateAttempts >= 3 {
            appendStatusLog("status item keeps disappearing, giving up")
            statusWatchdog?.invalidate()
            statusWatchdog = nil
            return
        }
        recreateAttempts += 1
        appendStatusLog("recreating status item (attempt \(recreateAttempts))")
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
        }
        statusItem = nil
        statusMissingTicks = 0
        setupStatusItem()
        updateStatusItem(store.latest)
    }

    // MARK: - 菜单栏日志（诊断用）

    private func appendStatusLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: statusLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? text.write(to: statusLogURL, atomically: true, encoding: .utf8)
        }
    }

    private func logStatusLine(title: String, reading: PowerReading?) {
        var line = "title=\"\(title)\" metric=\(menuBarMetric.rawValue)"
        line += " len=\(Int(statusItem?.length ?? 0))"
        line += " visible=\(statusItem?.isVisible == true)"
        line += " window=\(statusItem?.button?.window != nil)"
        line += " font=\(statusItem?.button?.font?.pointSize ?? -1)"
        if let reading {
            line += " system=\(PowerFormat.watts(reading.totalW))"
            line += " input=\(PowerFormat.watts(reading.adapterInputW))"
            line += " battery=\(PowerFormat.watts(reading.batteryPowerW))"
        } else {
            line += " reading=nil"
        }
        let current = (statusItem?.button?.title ?? "")
        if current != title {
            line += " MISMATCH(button=\"\(current)\")"
        }
        appendStatusLog(line)
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
        let aboutItem = NSMenuItem(title: L("关于 WattMeter"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let loginMenuItem = NSMenuItem(title: loginText, action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        loginMenuItem.state = loginItem.enabled ? .on : .off
        menu.addItem(loginMenuItem)

        menu.addItem(.separator())

        // 菜单栏数值口径
        let metricItem = NSMenuItem(title: L("菜单栏显示"), action: nil, keyEquivalent: "")
        let metricMenu = NSMenu()
        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: L(metric.title), action: #selector(selectMenuBarMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = (metric == menuBarMetric) ? .on : .off
            metricMenu.addItem(item)
        }
        metricItem.submenu = metricMenu
        menu.addItem(metricItem)

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
            onShowAbout: { [weak self] in self?.showAbout() },
            onQuit: { NSApp.terminate(nil) }
        )
        let controller = NSHostingController(rootView: root)
        // 面板实测高度 749pt（含电池健康行与磁盘条），留 1pt 余量避免底部被裁
        controller.preferredContentSize = NSSize(width: 400, height: 750)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 400, height: 750)
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
            let controller = NSHostingController(rootView: MainWindowView(
                store: store, scrollable: true,
                onShowAbout: { [weak self] in self?.showAbout() }))
            let window = NSWindow(contentViewController: controller)
            window.title = "WattMeter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // 内容实测高度约 866pt（侧栏多了一行电池健康）；按真实内容开窗，
            // 避免底部被裁掉。
            // 用户手动缩小时由 MainWindowView 的 ScrollView 兜底。
            window.setContentSize(NSSize(width: 1020, height: 880))
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
        updateStatusItem(store.latest)
    }

    @objc private func selectMenuBarMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = MenuBarMetric(rawValue: raw) else { return }
        menuBarMetric = metric
        appendStatusLog("menu bar metric -> \(metric.rawValue)")
        updateStatusItem(store.latest)
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

    @objc private func showAbout() {
        if popover.isShown { popover.performClose(nil) }
        if aboutWindow == nil {
            let view = AboutView { [weak self] in self?.aboutWindow?.close() }
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = L("关于 WattMeter")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
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
        print("diag: menu bar metric=\(menuBarMetric.rawValue) title=\"\(button.title)\" lastTitle=\(lastTitle ?? "nil")")
        print("diag: statusItem length=\(statusItem.length) visible=\(statusItem.isVisible) buttonFont=\(button.font?.pointSize ?? -1)pt")
        print("diag: statusItem button.window=\(window != nil ? "存在" : "nil") visible=\(window?.isVisible ?? false) frame=\(button.frame)")
        print("diag: statusBar thickness=\(NSStatusBar.system.thickness) screens=\(NSScreen.screens.count)")
        print("diag: last update \(String(format: "%.1f", Date().timeIntervalSince(lastUpdateAt)))s ago, watchdog=\(statusWatchdog != nil ? "on" : "off")")
        if let latest = store.latest {
            print("diag: reading total=\(String(format: "%.1f", latest.totalW))W input=\(PowerFormat.watts(latest.adapterInputW))W source=\(latest.source.label) samples=\(store.history.count)")
            print("diag: menu bar text for every metric: " + MenuBarMetric.allCases.map { "\($0.rawValue)=\($0.text(for: latest))" }.joined(separator: " "))
        } else {
            print("diag: 还没有读数")
        }
        exit(0)
    }
}
