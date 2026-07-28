//
//  MkeyApp.swift
//  mkey
//
//  Menu-bar Vietnamese input method for macOS 26, built on the OpenKey
//  engine with a SwiftUI interface.
//

import AppKit
import SwiftUI

@main
struct MkeyApp: App {
    @NSApplicationDelegateAdaptor(MkeyAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }

        Window("AZS Tools — Bộ gõ Tiếng Việt & Tiện ích macOS", id: "settings") {
            SettingsRootView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 560)

        Window("Chào mừng đến với AZS Tools", id: "welcome") {
            WelcomePage()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 450)
    }
}

/// Lives permanently in the menu bar, so it is the one SwiftUI view that can
/// reliably receive the "open settings" request from the AppKit delegate.
struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: StatusIcon.image(vietnamese: state.isVietnamese, gray: state.grayIcon))
            .onReceive(NotificationCenter.default.publisher(for: .mkOpenSettingsWindow)) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mkOpenWelcomeWindow)) { _ in
                openWindow(id: "welcome")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var utilities = AZSUtilityController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !state.engineReady {
            Button("Hoàn tất quyền bộ gõ…") {
                openWelcomeWindow()
            }
            Divider()
            Button("Thoát AZS Tools") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } else {
            Toggle("Tiếng Việt", isOn: $state.isVietnamese)
                .dynamicShortcut(state.switchKeyStatus)

            Divider()

            Picker("Kiểu gõ", selection: $state.inputType) {
                ForEach(AppState.inputTypeNames.indices, id: \.self) { i in
                    Text(AppState.inputTypeNames[i]).tag(i)
                }
            }

            Picker("Bảng mã", selection: $state.codeTable) {
                ForEach(AppState.codeTableNames.indices, id: \.self) { i in
                    Text(AppState.codeTableNames[i]).tag(i)
                }
            }

            Divider()

            Button("Chuyển mã nhanh") {
                MKBridge.engineRequestsQuickConvert()
            }
            .dynamicShortcut(state.convertHotKey)

            Button("Công cụ chuyển mã…") { open(.convert) }
            Button("Gõ tắt…") { open(.macro) }

            if clipboard.enabled {
                Button("Lịch sử Clipboard") {
                    ClipboardManager.shared.togglePicker()
                }
                .dynamicShortcut(clipboard.hotKey)
            }

            Divider()

            MenuFanControl()

            if !utilities.mouseDevices.isEmpty {
                Menu {
                    ForEach(utilities.mouseDevices) { mouse in
                        if let battery = mouse.batteryPercent {
                            Label("\(mouse.displayName) — \(battery)% pin", systemImage: "battery.100percent")
                        } else {
                            Label("\(mouse.displayName) — không có thông tin pin", systemImage: "computermouse")
                        }
                    }
                    Divider()
                    Button("Quét lại") { utilities.refreshMouseDevices() }
                } label: {
                    if utilities.mouseDevices.count == 1, let mouse = utilities.mouseDevices.first {
                        Label(mouse.batteryPercent.map { "Chuột · \($0)% pin" } ?? "Chuột · \(mouse.displayName)",
                              systemImage: "computermouse")
                    } else {
                        Label("Chuột · \(utilities.mouseDevices.count) thiết bị", systemImage: "computermouse")
                    }
                }
            }

            Divider()

            Button("Bảng điều khiển…") { open(.typing) }
            Button("Tiện ích AZS Tools…") { open(.utilities) }
            Button("Giới thiệu AZS Tools") { open(.about) }

            Divider()

            Button("Thoát AZS Tools") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openWelcomeWindow() {
        openWindow(id: "welcome")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(_ page: SettingsPage) {
        state.selectedPage = page
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Compact fan speed control shown directly in the menu-bar menu.
/// The full Fan Control page remains available from Utilities for advanced
/// multi-fan management; this view is optimized for quick one-fan adjustments.
private struct MenuFanControl: View {
    @ObservedObject private var controller = AZSFanController.shared

    var body: some View {
        if controller.fans.isEmpty {
            Label("Điều chỉnh quạt — đang đọc…", systemImage: "fan")
                .foregroundStyle(.secondary)
                .onAppear { controller.start() }
        } else if let fan = controller.fans.first {
            let lower = max(0, fan.minimumRPM)
            let upper = max(lower + 100, fan.maximumRPM)
            Menu {
                Text("Hiện tại: \(Int(fan.actualRPM.rounded())) RPM")
                Text("Mục tiêu: \(Int(fan.targetRPM.rounded())) RPM")
                Divider()
                Button("− Giảm 250 RPM") {
                    controller.setTarget(for: fan.id, rpm: fan.targetRPM - 250)
                }.disabled(!controller.canControl)
                Button("＋ Tăng 250 RPM") {
                    controller.setTarget(for: fan.id, rpm: fan.targetRPM + 250)
                }.disabled(!controller.canControl)
                Divider()
                Menu("Chọn mức quạt") {
                    ForEach(menuRPMPresets(lower: lower, upper: upper), id: \.rpm) { preset in
                        Button("\(preset.name) · \(preset.rpm) RPM") {
                            controller.setTarget(for: fan.id, rpm: Double(preset.rpm))
                        }.disabled(!controller.canControl)
                    }
                }
                Divider()
                Button("Về tự động (khuyên dùng)") { controller.setAuto(for: fan.id) }
                    .disabled(!controller.canControl || !fan.manual)
                if !controller.canControl {
                    Divider()
                    Button("Bật điều khiển quạt…") { controller.authorizeControl() }
                }
            } label: {
                Label("Điều chỉnh quạt · \(Int(fan.actualRPM.rounded())) RPM", systemImage: "fan")
            }
            .onAppear { controller.start() }
        }
    }

    private func menuRPMPresets(lower: Double, upper: Double) -> [(name: String, rpm: Int)] {
        let span = upper - lower
        return [
            ("Êm", Int(lower.rounded())),
            ("Thấp", Int((lower + span * 0.35).rounded())),
            ("Cân bằng", Int((lower + span * 0.55).rounded())),
            ("Mát", Int((lower + span * 0.75).rounded())),
            ("Tối đa", Int(upper.rounded()))
        ]
    }
}

@MainActor
final class MkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var permissionTimer: Timer?
    private var eventTapHealthTimer: Timer?
    private var didRequestInputMonitoring = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppState.registerDefaultSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        NSApp.setActivationPolicy(state.showIconOnDock ? .regular : .accessory)

        registerWorkspaceNotifications()
        observeQuickConvert()
        observeUpdateAvailable()
        // Keep fan telemetry warm so the menu can show the RPM control as soon
        // as it opens, rather than waiting for the first menu appearance.
        AZSFanController.shared.start()
        // Mouse inventory and the M650 log fallback do not depend on the
        // Vietnamese event tap. Start them even while permissions are pending.
        AZSUtilityController.shared.start()

        // clipboard history runs independently from the engine
        ClipboardManager.shared.startIfEnabled()

        // check GitHub for a newer release (once/day, if enabled)
        UpdateChecker.shared.autoCheckIfDue()

        // banner "Mở Cài đặt hệ thống" button asks us to (re-)register for AX
        NotificationCenter.default.addObserver(forName: .mkRequestAccessibility,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.askForAccessibility()
            }
        }
        NotificationCenter.default.addObserver(forName: .mkRecheckAccessibility,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkAccessibilityNow() }
        }

        // Keep the Dock icon in sync with the "show in Dock" setting. Our
        // windows briefly promote the app to .regular so they can grab focus
        // on macOS 26 (an accessory app's window renders gray otherwise); once
        // a window is key we drop back to .accessory so no Dock icon lingers.
        NotificationCenter.default.addObserver(self, selector: #selector(mkWindowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mkWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)

        beginEventTapHealthChecks()

        refreshPermissionState()
        if !state.accessibilityGranted {
            askForAccessibility()
        } else if !state.inputMonitoringGranted {
            askForInputMonitoring()
        } else {
            startEngine()
        }

        if state.showUIOnStartup || !state.engineReady {
            // delay until the MenuBarExtra label is installed and can route the request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettingsWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettingsWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        eventTapHealthTimer?.invalidate()
        _ = MKBridge.stopEventTap()
        AZSPrivilegedSMC.shutdown()
    }

    // MARK: Dock icon / activation policy

    private func isMkUIWindow(_ window: NSWindow?) -> Bool {
        guard let id = window?.identifier?.rawValue else { return false }
        return id.hasPrefix("settings") || id.hasPrefix("welcome")
    }

    @objc private func mkWindowBecameKey(_ note: Notification) {
        guard isMkUIWindow(note.object as? NSWindow) else { return }
        // Focus is secured; honour the user's choice to hide the Dock icon.
        if !AppState.shared.showIconOnDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func mkWindowWillClose(_ note: Notification) {
        guard isMkUIWindow(note.object as? NSWindow) else { return }
        DispatchQueue.main.async {
            if !AppState.shared.showIconOnDock {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: Engine

    private func startEngine() {
        refreshPermissionState()
        guard AppState.shared.accessibilityGranted,
              AppState.shared.inputMonitoringGranted else {
            AppState.shared.eventTapRunning = false
            beginPermissionPolling()
            return
        }
        guard MKBridge.startEventTap() else {
            // Permission may look enabled while TCC still has the ad-hoc code
            // requirement for an older build. Do not mislabel that as an
            // Accessibility failure; keep the three diagnostics independent.
            AppState.shared.eventTapRunning = false
            return
        }
        // A floating search/hotkey editor can suspend composition temporarily.
        // Starting or rebuilding the global tap must always begin in the normal
        // typing state, even if a window was interrupted during an app update.
        MKBridge.setEngineSuspended(false)
        AppState.shared.eventTapRunning = true
    }

    /// Event taps can become invalid after sleep, Fast User Switching, or a
    /// privacy-permission change without terminating the app. `_tapRunning`
    /// used to stay true forever in that case, so the menu looked enabled while
    /// no Vietnamese keystrokes were received. Poll the actual Mach-port state
    /// and rebuild the tap when necessary.
    private func beginEventTapHealthChecks() {
        guard eventTapHealthTimer == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                let state = AppState.shared
                self.refreshPermissionState()
                guard state.accessibilityGranted, state.inputMonitoringGranted else {
                    state.eventTapRunning = false
                    return
                }
                if !MKBridge.isEventTapRunning() {
                    NSLog("AZS input: unhealthy event tap detected; rebuilding")
                    _ = MKBridge.stopEventTap()
                    if MKBridge.startEventTap() {
                        MKBridge.setEngineSuspended(false)
                        state.eventTapRunning = true
                    } else {
                        state.eventTapRunning = false
                    }
                } else {
                    state.eventTapRunning = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTapHealthTimer = timer
    }

    private func askForAccessibility() {
        // show the system prompt, then poll until granted
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        beginPermissionPolling()
    }

    private func askForInputMonitoring() {
        if !didRequestInputMonitoring {
            didRequestInputMonitoring = true
            _ = CGRequestListenEventAccess()
        }
        beginPermissionPolling()
    }

    private func beginPermissionPolling() {
        guard permissionTimer == nil else { return }
        // .common mode so the poll keeps firing while a modal sheet / menu
        // tracking session is active.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionState()
                let state = AppState.shared
                if state.accessibilityGranted && !state.inputMonitoringGranted {
                    self.askForInputMonitoring()
                }
                if state.accessibilityGranted && state.inputMonitoringGranted {
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.startEngine()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func refreshPermissionState() {
        let state = AppState.shared
        state.accessibilityGranted = AXIsProcessTrusted()
        state.inputMonitoringGranted = CGPreflightListenEventAccess()
        state.eventTapRunning = MKBridge.isEventTapRunning()
    }

    private func checkAccessibilityNow() {
        refreshPermissionState()
        let state = AppState.shared
        guard state.accessibilityGranted else {
            beginPermissionPolling()
            return
        }
        if !state.inputMonitoringGranted {
            askForInputMonitoring()
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            startEngine()
        }
    }

    // MARK: Notifications

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(receiveWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(receiveSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(activeAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func observeQuickConvert() {
        NotificationCenter.default.addObserver(forName: .MKQuickConvertDidRun,
                                               object: nil, queue: .main) { note in
            let success = (note.object as? NSNumber)?.boolValue ?? false
            Task { @MainActor in
                guard MKBridge.convertAlertWhenCompleted || !success else { return }
                let alert = NSAlert()
                alert.messageText = success ? "Chuyển mã thành công!" : "Không có dữ liệu trong clipboard!"
                alert.informativeText = success ? "Kết quả đã được lưu trong clipboard." : "Hãy sao chép một đoạn văn bản để chuyển đổi."
                alert.addButton(withTitle: "OK")
                alert.window.level = .statusBar
                alert.runModal()
            }
        }
    }

    private func observeUpdateAvailable() {
        NotificationCenter.default.addObserver(forName: .mkUpdateAvailable,
                                               object: nil, queue: .main) { note in
            guard let info = note.object as? ReleaseInfo else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Đã có AZS Tools \(info.version)"
                let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                alert.informativeText = notes.isEmpty
                    ? "Một phiên bản mới đã sẵn sàng để tải về."
                    : String(notes.prefix(400))
                alert.addButton(withTitle: "Xem bản mới")
                alert.addButton(withTitle: "Để sau")
                alert.window.level = .statusBar
                if alert.runModal() == .alertFirstButtonReturn {
                    UpdateChecker.shared.openReleasePage(info)
                }
            }
        }
    }

    @objc private func receiveWake(_ note: Notification) {
        refreshPermissionState()
        if AppState.shared.accessibilityGranted && AppState.shared.inputMonitoringGranted {
            startEngine()
        } else {
            beginPermissionPolling()
        }
        AZSUtilityController.shared.start()
    }

    @objc private func receiveSleep(_ note: Notification) {
        _ = MKBridge.stopEventTap()
        AppState.shared.eventTapRunning = false
    }

    @objc private func spaceChanged(_ note: Notification) {
        MKBridge.requestNewSession()
    }

    @objc private func activeAppChanged(_ note: Notification) {
        if vUseSmartSwitchKey != 0 && MKBridge.isEventTapRunning() {
            MKBridge.activeAppChanged()
        }
    }

    // MARK: Window

    private func openSettingsWindow() {
        let state = AppState.shared
        if state.engineReady {
            if let welcomeWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" }) {
                welcomeWindow.close()
            }
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                NotificationCenter.default.post(name: .mkOpenSettingsWindow, object: nil)
            }
        } else {
            if let settingsWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                settingsWindow.close()
            }
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                NotificationCenter.default.post(name: .mkOpenWelcomeWindow, object: nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let mkOpenSettingsWindow = Notification.Name("MKOpenSettingsWindow")
    static let mkOpenWelcomeWindow = Notification.Name("MKOpenWelcomeWindow")
    static let mkRequestAccessibility = Notification.Name("MKRequestAccessibility")
    static let mkRecheckAccessibility = Notification.Name("MKRecheckAccessibility")
}

extension View {
    @ViewBuilder
    func dynamicShortcut(_ status: Int32) -> some View {
        if let shortcut = ShortcutParser.parse(status) {
            self.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}

private struct ShortcutParser {
    static func parse(_ status: Int32) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        let value = UInt32(bitPattern: status)
        let char = UInt8((value >> 24) & 0xFF)
        guard char != 0xFE && char != 0 else { return nil }
        
        let key: KeyEquivalent
        if char == 49 || char == 32 {
            key = .space
        } else {
            let letter = String(UnicodeScalar(char)).lowercased()
            if let c = letter.first {
                key = KeyEquivalent(c)
            } else {
                key = KeyEquivalent(" ")
            }
        }
        
        var modifiers: EventModifiers = []
        if value & 0x100 != 0 { _ = modifiers.insert(.control) }
        if value & 0x200 != 0 { _ = modifiers.insert(.option) }
        if value & 0x400 != 0 { _ = modifiers.insert(.command) }
        if value & 0x800 != 0 { _ = modifiers.insert(.shift) }
        
        return (key, modifiers)
    }
}
