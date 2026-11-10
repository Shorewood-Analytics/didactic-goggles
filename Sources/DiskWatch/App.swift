import AppKit
import DiskDiscovery
import ServiceManagement
import SwiftUI

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
        if CommandLine.arguments.contains("--capture-previews") {
            capturePreviews()
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
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let monitor = DiskMonitor()
    private var statusItem: NSStatusItem?
    private var loginError: String?
    private let windowModel = DiskWindowModel()
    private let usageReader = DiskUsageReader()
    private let ejector = DiskEjector()
    private var diskWindow: NSWindow?
    private var usageTask: Task<Void, Never>?
    private var usageTimer: Timer?
    private var pendingRefresh = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDisks()
        return true
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Disk Watch")
        item.button?.imagePosition = .imageLeading
        statusItem = item
        monitor.onChange = { [weak self] in
            guard let self else { return }
            self.windowModel.disks = self.monitor.disks
            self.windowModel.message = self.monitor.lastError
            self.render()
            self.resizeWindow()
            self.updateUsage()
        }
        windowModel.refresh = { [weak self] in self?.refreshDetails() }
        windowModel.ejectAll = { [weak self] in self?.ejectAll() }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDetails() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        startMonitoring()
        showDisks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        usageTimer?.invalidate()
        usageTask?.cancel()
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
        action("Show Disks…", #selector(showDisks), in: menu)
        menu.addItem(.separator())
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

    @objc private func didWake() { refreshDetails() }

    @objc private func showDisks() {
        if diskWindow == nil {
            let view = NSHostingView(rootView: CompactDiskWindow(model: windowModel))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Disk Watch"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = view
            window.center()
            diskWindow = window
        }
        resizeWindow()
        diskWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizeWindow() {
        let rows = windowModel.disks.isEmpty ? 66 : min(windowModel.disks.count * 48, 240)
        diskWindow?.setContentSize(NSSize(width: 340, height: rows + 46))
    }

    private func refreshDetails() {
        startMonitoring()
        updateUsage()
    }

    private func updateUsage() {
        let ids = Set(monitor.disks.map(\.id))
        windowModel.usage = windowModel.usage.filter { ids.contains($0.key) }
        guard usageTask == nil else { pendingRefresh = true; return }
        let snapshot = monitor.disks
        guard !snapshot.isEmpty else { return }
        windowModel.refreshing = true
        usageTask = Task { [weak self, usageReader] in
            let result = await usageReader.read(snapshot)
            guard let self, !Task.isCancelled else { return }
            // Never apply a result to a newly attached disk that reused a BSD name.
            let liveIDs = Set(self.monitor.disks.map(\.id))
            for (id, usage) in result where liveIDs.contains(id) { self.windowModel.usage[id] = usage }
            self.windowModel.refreshing = false
            self.usageTask = nil
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.updateUsage()
            }
        }
    }

    private func ejectAll() {
        guard !windowModel.ejecting else { return }
        let targets = monitor.disks
        guard !targets.isEmpty else { return }
        windowModel.ejecting = true
        windowModel.failures = [:]
        Task {
            let results = await ejector.ejectAll(targets) { index, count in
                windowModel.message = "Ejecting \(index) of \(count)"
            }
            let failures = results.filter { !$0.succeeded }
            windowModel.failures = Dictionary(uniqueKeysWithValues: failures.map { ($0.disk.id, $0.error!) })
            monitor.refresh()
            windowModel.ejecting = false
            windowModel.message = failures.isEmpty ? "All disks ejected" : "\(failures.count) could not eject"
        }
    }

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
