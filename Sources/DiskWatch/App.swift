import AppKit
import DiskDiscovery
import ServiceManagement

@main
struct DiskWatchApp {
    @MainActor
    static func main() {
        // Exercise the signed sandboxed executable in CI without opening a UI.
        if CommandLine.arguments.contains("--smoke-test") {
            let monitor = DiskMonitor()
            do {
                try monitor.start()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                monitor.stop()
                print("Sandboxed IOKit monitor started and stopped.")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = DiskMonitor()
    private var statusItem: NSStatusItem?
    private var loginError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Disk Watch")
        item.button?.imagePosition = .imageLeading
        statusItem = item
        monitor.onChange = { [weak self] in self?.render() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitor.onChange = nil
        monitor.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
    }

    private func render() {
        statusItem?.button?.title = monitor.lastError == nil ? " \(monitor.disks.count)" : " !"
        statusItem?.button?.toolTip = monitor.lastError ?? "Disk Watch — monitoring in the background"
        if statusItem?.menu == nil {
            let menu = NSMenu()
            menu.delegate = self
            statusItem?.menu = menu
        }
        if let menu = statusItem?.menu { populate(menu) }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        label(monitor.isRunning ? "Watching disks in the background" : "Monitoring stopped", in: menu)
        if let error = monitor.lastError {
            label("\(error) Last results may be stale.", in: menu)
            action("Retry monitoring", #selector(startMonitoring), in: menu)
        }
        menu.addItem(.separator())
        if monitor.disks.isEmpty, monitor.lastError == nil {
            label("No external disks or SD cards", in: menu)
        }
        for disk in monitor.disks {
            label(disk.name, in: menu)
            let bytes = Int64(clamping: disk.sizeBytes)
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let connection = disk.connection == .builtInSDReader ? "Built-in SD reader" : disk.transport
            let detail = label("\(disk.bsdName) · \(size) · \(connection)", in: menu)
            detail.indentationLevel = 1
        }
        menu.addItem(.separator())
        let service = SMAppService.mainApp
        let loginItem = action("Start at login", #selector(toggleLogin), in: menu)
        loginItem.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            label("Login startup awaits approval", in: menu)
            action("Open Login Items settings…", #selector(openLoginSettings), in: menu)
        }
        if let loginError { label(loginError, in: menu) }
        menu.addItem(.separator())
        action("Quit Disk Watch", #selector(quit), in: menu).keyEquivalent = "q"
    }

    @discardableResult
    private func label(_ text: String, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func action(_ text: String, _ selector: Selector, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func startMonitoring() {
        if monitor.isRunning {
            monitor.refresh()
        } else {
            do { try monitor.start() } catch { render() }
        }
    }

    @objc private func didWake() { startMonitoring() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        render()
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
