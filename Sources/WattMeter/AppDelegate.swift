import AppKit
import Combine
import SwiftUI
import WattMeterCore
import WattMeterUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PowerStore()
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
        button.toolTip = "WattMeter — 实时功率"
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
        button.toolTip = "WattMeter · 整机 \(PowerFormat.wattsWithUnit(reading.totalW)) · "
            + "电源 \(PowerFormat.wattsWithUnit(reading.adapterToLoadW)) · "
            + "电池 \(PowerFormat.wattsWithUnit(reading.batteryToLoadW))"
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

        let openItem = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 WattMeter", action: #selector(quit), keyEquivalent: "q")
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
            onOpenWindow: { [weak self] in self?.openMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        let controller = NSHostingController(rootView: root)
        controller.preferredContentSize = NSSize(width: 400, height: 644)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 400, height: 644)
        popover.contentViewController = controller
        self.popover = popover
    }

    private func togglePopover() {
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
            let controller = NSHostingController(rootView: MainWindowView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "WattMeter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1020, height: 740))
            window.minSize = NSSize(width: 960, height: 680)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            mainWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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
