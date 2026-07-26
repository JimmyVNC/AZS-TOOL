//
//  AZSUtilityController.swift
//  AZS Tools
//
//  Global mouse utilities and the native macOS volume HUD. This module is
//  independent from the Vietnamese engine event tap, so both can run together.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

enum AZSMouseAction: String, CaseIterable, Identifiable {
    case none, back, forward
    case copy, paste, cut, undo, redo, selectAll
    case missionControl, appWindows, desktop, spotlight, lockScreen, screenshot
    case volumeUp, volumeDown, mute
    case openApplication

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Không gán"
        case .back: return "Quay lại"
        case .forward: return "Đi tới"
        case .copy: return "Sao chép (⌘C)"
        case .paste: return "Dán (⌘V)"
        case .cut: return "Cắt (⌘X)"
        case .undo: return "Hoàn tác (⌘Z)"
        case .redo: return "Làm lại (⇧⌘Z)"
        case .selectAll: return "Chọn tất cả (⌘A)"
        case .volumeUp: return "Tăng âm lượng"
        case .volumeDown: return "Giảm âm lượng"
        case .mute: return "Tắt/bật âm thanh"
        case .missionControl: return "Mission Control"
        case .appWindows: return "Cửa sổ ứng dụng"
        case .desktop: return "Hiện Desktop"
        case .spotlight: return "Mở Spotlight"
        case .lockScreen: return "Khóa màn hình"
        case .screenshot: return "Chụp vùng màn hình"
        case .openApplication: return "Mở ứng dụng…"
        }
    }
}

final class AZSUtilityController: ObservableObject {
    static let shared = AZSUtilityController()

    @Published var reverseScrolling: Bool { didSet { saveAndRestart() } }
    /// CGEvent button numbers start at 2 for the physical middle button. A
    /// dictionary lets users assign any of the common Button 3–10 slots.
    @Published var buttonActions: [Int: AZSMouseAction] { didSet { saveAndRestart() } }
    @Published var buttonApplications: [Int: String] { didSet { saveAndRestart() } }
    @Published var brightnessUpHotKey: Int32 { didSet { saveBrightnessHotKeys() } }
    @Published var brightnessDownHotKey: Int32 { didSet { saveBrightnessHotKeys() } }
    @Published private(set) var lastDetectedButton: Int?

    private let defaults = UserDefaults.standard
    private var lock = NSLock()
    private var reverseSnapshot = false
    private var actionsSnapshot: [Int: AZSMouseAction] = [:]
    private var applicationsSnapshot: [Int: String] = [:]
    private var lastExternalVolume: Float = 0.5
    private let brightnessUpMonitor = GlobalHotKey()
    private let brightnessDownMonitor = GlobalHotKey()

    private init() {
        reverseScrolling = defaults.bool(forKey: "AZSReverseScrolling")
        var actions: [Int: AZSMouseAction] = [2: .none, 3: .back, 4: .forward]
        if let saved = defaults.dictionary(forKey: "AZSMouseButtonActions") as? [String: String] {
            for (key, rawValue) in saved {
                if let button = Int(key), let action = AZSMouseAction(rawValue: rawValue) {
                    actions[button] = action
                }
            }
        } else {
            // Migrate the original three fixed slots without losing a user's
            // existing configuration.
            actions[2] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSMiddleAction") ?? "none") ?? .none
            actions[3] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSBackAction") ?? "back") ?? .back
            actions[4] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSForwardAction") ?? "forward") ?? .forward
        }
        buttonActions = actions
        var applications: [Int: String] = [:]
        if let saved = defaults.dictionary(forKey: "AZSMouseButtonApplications") as? [String: String] {
            for (key, path) in saved where Int(key) != nil { applications[Int(key)!] = path }
        }
        buttonApplications = applications
        let emptyHotKey = Int32(bitPattern: 0xFE0000FE)
        let savedBrightnessUp = Int32(truncatingIfNeeded: defaults.integer(forKey: "AZSBrightnessUpHotKey"))
        let savedBrightnessDown = Int32(truncatingIfNeeded: defaults.integer(forKey: "AZSBrightnessDownHotKey"))
        brightnessUpHotKey = savedBrightnessUp == 0 ? emptyHotKey : savedBrightnessUp
        brightnessDownHotKey = savedBrightnessDown == 0 ? emptyHotKey : savedBrightnessDown
        lastDetectedButton = nil
        refreshSnapshot()
        brightnessUpMonitor.onPressed = { [weak self] in self?.changeBrightness(by: 0.0625) }
        brightnessDownMonitor.onPressed = { [weak self] in self?.changeBrightness(by: -0.0625) }
        registerBrightnessHotKeys()
    }

    func start() {
        // Utility events are routed through MKBridge's Accessibility tap.
        // Keeping this method makes startup/wake lifecycle calls idempotent.
        refreshSnapshot()
    }

    private func saveAndRestart() {
        defaults.set(reverseScrolling, forKey: "AZSReverseScrolling")
        let saved = buttonActions.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value.rawValue
        }
        defaults.set(saved, forKey: "AZSMouseButtonActions")
        let savedApplications = buttonApplications.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value
        }
        defaults.set(savedApplications, forKey: "AZSMouseButtonApplications")
        refreshSnapshot()
    }

    private func saveBrightnessHotKeys() {
        defaults.set(Int(brightnessUpHotKey), forKey: "AZSBrightnessUpHotKey")
        defaults.set(Int(brightnessDownHotKey), forKey: "AZSBrightnessDownHotKey")
        registerBrightnessHotKeys()
    }

    private func registerBrightnessHotKeys() {
        brightnessUpMonitor.register(status: brightnessUpHotKey)
        brightnessDownMonitor.register(status: brightnessDownHotKey)
    }

    private func refreshSnapshot() {
        lock.lock()
        reverseSnapshot = reverseScrolling
        actionsSnapshot = buttonActions
        applicationsSnapshot = buttonApplications
        lock.unlock()
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {

        lock.lock()
        let reverse = reverseSnapshot
        let actions = actionsSnapshot
        let applications = applicationsSnapshot
        lock.unlock()

        if type == .scrollWheel && reverse {
            reverseScrollEvent(event)
        }

        if type == .otherMouseDown {
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            // Publish the physical button even when it is currently unmapped;
            // this makes discovering unusual mouse buttons straightforward.
            DispatchQueue.main.async { [weak self] in self?.lastDetectedButton = button }
            if let action = actions[button], action != .none {
                let applicationPath = applications[button]
                DispatchQueue.main.async { [weak self] in self?.perform(action, applicationPath: applicationPath) }
                return true
            }
        }

        if type == azsSystemDefinedType {
            return handleMediaKey(event)
        }
        // A few third-party keyboards expose the media row as ordinary
        // keyDown/keyUp events instead of NX system-defined events. Support
        // those key codes as a fallback while leaving normal typing untouched.
        if type == .keyDown || type == .keyUp {
            return handleKeyboardMediaKey(type, event)
        }
        return false
    }

    /// Scroll Reverser writes DeltaAxis first, then FixedPtDeltaAxis, and
    /// PointDeltaAxis last. CoreGraphics recalculates smooth-scroll fields when
    /// DeltaAxis changes, so the ordering is essential for mice and trackpads.
    private func reverseScrollEvent(_ event: CGEvent) {
        let integerAxes: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis3),
        ]
        let fixedAxes: [CGEventField] = [
            .scrollWheelEventFixedPtDeltaAxis1,
            .scrollWheelEventFixedPtDeltaAxis2,
            .scrollWheelEventFixedPtDeltaAxis3,
        ]

        let deltas = integerAxes.map { event.getIntegerValueField($0.0) }
        let points = integerAxes.map { event.getIntegerValueField($0.1) }
        let fixed = fixedAxes.map { event.getDoubleValueField($0) }

        for (index, fields) in integerAxes.enumerated() {
            event.setIntegerValueField(fields.0, value: -deltas[index])
        }
        for (index, field) in fixedAxes.enumerated() {
            event.setDoubleValueField(field, value: -fixed[index])
        }
        for (index, fields) in integerAxes.enumerated() {
            event.setIntegerValueField(fields.1, value: -points[index])
        }
    }

    private func perform(_ action: AZSMouseAction, applicationPath: String? = nil) {
        switch action {
        case .none: break
        case .back: postKey(code: 33, flags: .maskCommand)
        case .forward: postKey(code: 30, flags: .maskCommand)
        case .copy: postKey(code: 8, flags: .maskCommand)
        case .paste: postKey(code: 9, flags: .maskCommand)
        case .cut: postKey(code: 7, flags: .maskCommand)
        case .undo: postKey(code: 6, flags: .maskCommand)
        case .redo: postKey(code: 6, flags: [.maskCommand, .maskShift])
        case .selectAll: postKey(code: 0, flags: .maskCommand)
        case .missionControl: postKey(code: 126, flags: .maskControl)
        case .appWindows: postKey(code: 125, flags: .maskControl)
        case .desktop: postKey(code: 103, flags: [])
        case .spotlight: postKey(code: 49, flags: .maskCommand)
        case .lockScreen: postKey(code: 12, flags: [.maskCommand, .maskControl])
        case .screenshot: postKey(code: 21, flags: [.maskCommand, .maskShift])
        case .volumeUp: changeVolume(by: 0.0625)
        case .volumeDown: changeVolume(by: -0.0625)
        case .mute: toggleVolumeMute()
        case .openApplication:
            guard let applicationPath, FileManager.default.fileExists(atPath: applicationPath) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: applicationPath))
        }
    }

    private func changeVolume(by amount: Float) {
        let displays = AZSDisplayController.shared
        if let id = displays.keyboardTargetID {
            let next = max(0, min(1, displays.volume(for: id) + amount))
            displays.setVolume(next, for: id)
            AZSVolumeHUD.shared.show(value: next, muted: next == 0, displayID: id)
        } else {
            AZSAudio.setVolume(AZSAudio.volume() + amount)
            AZSVolumeHUD.shared.show(value: AZSAudio.volume())
        }
    }

    private func toggleVolumeMute() {
        let displays = AZSDisplayController.shared
        if let id = displays.keyboardTargetID {
            let current = displays.volume(for: id)
            let next = current > 0 ? 0 : max(0.0625, lastExternalVolume)
            if current > 0 { lastExternalVolume = current }
            displays.setVolume(next, for: id)
            AZSVolumeHUD.shared.show(value: next, muted: next == 0, displayID: id)
        } else {
            AZSAudio.setMuted(!AZSAudio.isMuted())
            AZSVolumeHUD.shared.show(value: AZSAudio.volume(), muted: AZSAudio.isMuted())
        }
    }

    private func changeBrightness(by amount: Float) {
        let displays = AZSDisplayController.shared
        if let (displayID, value) = displays.stepKeyboardBrightness(by: amount) {
            AZSVolumeHUD.shared.showBrightness(value: value, displayID: displayID)
        }
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    /// Returns true when the media-key event belongs to an external display and
    /// must not continue to macOS's normal CoreAudio volume handler.
    private func handleMediaKey(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        // The data1 payload is stable across macOS versions; do not reject a
        // valid media key only because its system-defined subtype changed.
        let data = ns.data1
        let key = (data >> 16) & 0xFFFF
        let state = (data >> 8) & 0xFF
        // NX_KEYTYPE_SOUND_UP/DOWN/MUTE = 0/1/7,
        // NX_KEYTYPE_BRIGHTNESS_UP/DOWN = 2/3.
        guard key == 0 || key == 1 || key == 2 || key == 3 || key == 7 else { return false }

        let displays = AZSDisplayController.shared
        let displayID = (key == 2 || key == 3)
            ? displays.keyboardBrightnessTargetID
            : displays.keyboardTargetID
        guard let displayID else {
            // No external DDC target: allow macOS to update CoreAudio, then show
            // the same percentage HUD for the built-in/default audio output.
            if (key == 0 || key == 1 || key == 7) && state == 0xA {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    AZSVolumeHUD.shared.show(value: AZSAudio.volume(), muted: AZSAudio.isMuted())
                }
            }
            return false
        }

        // Consume both key-down and key-up. Only key-down performs an action;
        // repeated key-down events naturally provide press-and-hold behavior.
        // NX_KEYDOWN is 0xA and NX_KEYUP is 0xB. Newer systems may add a
        // repeat bit, so compare the low nibble instead of the whole byte.
        guard (state & 0x0F) == 0xA else { return true }
        applyMediaKey(key, displayID: displayID, displays: displays)
        return true
    }

    private func handleKeyboardMediaKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Apple media-row virtual key codes; external keyboards commonly use
        // these directly when the function row is configured as media keys.
        let key: Int
        switch keyCode {
        case 72: key = 0   // volume up
        case 73: key = 1   // volume down
        case 74: key = 7   // mute
        case 113: key = 2  // brightness up
        case 107: key = 3  // brightness down
        case 144: key = 2  // standard brightness-up media key
        case 145: key = 3  // standard brightness-down media key
        default: return false
        }
        let displays = AZSDisplayController.shared
        let displayID = (key == 2 || key == 3)
            ? displays.keyboardBrightnessTargetID
            : displays.keyboardTargetID
        guard let displayID else { return false }
        if type == .keyDown {
            applyMediaKey(key, displayID: displayID, displays: displays)
        }
        return true
    }

    private func applyMediaKey(_ key: Int, displayID: CGDirectDisplayID, displays: AZSDisplayController) {
        switch key {
        case 0:
            if let (_, value) = displays.stepKeyboardVolume(by: 0.0625) {
                lastExternalVolume = max(value, 0.0625)
                AZSVolumeHUD.shared.show(value: value, muted: false, displayID: displayID)
            }
        case 1:
            if let (_, value) = displays.stepKeyboardVolume(by: -0.0625) {
                if value > 0 { lastExternalVolume = value }
                AZSVolumeHUD.shared.show(value: value, muted: value == 0, displayID: displayID)
            }
        case 7:
            let current = displays.volume(for: displayID)
            if current > 0 {
                lastExternalVolume = current
                displays.setVolume(0, for: displayID)
                AZSVolumeHUD.shared.show(value: 0, muted: true, displayID: displayID)
            } else {
                let restored = max(0.0625, lastExternalVolume)
                displays.setVolume(restored, for: displayID)
                AZSVolumeHUD.shared.show(value: restored, muted: false, displayID: displayID)
            }
        case 2:
            changeBrightness(by: 0.0625)
        case 3:
            changeBrightness(by: -0.0625)
        default: break
        }
    }
}

/// C entry point used by the primary OpenKey Accessibility tap. Using an
/// opaque pointer keeps the Swift/Objective-C++ boundary stable and avoids a
/// second event tap that may be denied by macOS.
@_cdecl("AZSHandleUtilityEvent")
func AZSHandleUtilityEvent(_ typeRaw: UInt32, _ eventPointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let eventPointer, let type = CGEventType(rawValue: typeRaw) else { return 0 }
    let event = Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()
    return AZSUtilityController.shared.handle(type, event) ? 1 : 0
}

private let azsSystemDefinedType = CGEventType(rawValue: 14)!

enum AZSAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func device() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }
    static func volume() -> Float32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        let id = device()
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        if status == noErr { return max(0, min(1, value)) }

        // Some USB/Bluetooth devices do not expose the virtual-main property.
        // Read the physical left/right channels instead and average them.
        var values: [Float32] = []
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var channel: Float32 = 0
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &channel) == noErr { values.append(channel) }
        }
        return values.isEmpty ? 0 : max(0, min(1, values.reduce(0, +) / Float32(values.count)))
    }
    static func setVolume(_ value: Float32) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = max(0, min(1, value)); let size = UInt32(MemoryLayout<Float32>.size); let id = device()
        if AudioObjectSetPropertyData(id, &address, 0, nil, size, &v) == noErr { return }
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            _ = AudioObjectSetPropertyData(id, &address, 0, nil, size, &v)
        }
    }
    static func isMuted() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device(), &address, 0, nil, &size, &value); return value != 0
    }
    static func setMuted(_ muted: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0; let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device(), &address, 0, nil, size, &value)
    }
}

final class AZSVolumeHUD {
    static let shared = AZSVolumeHUD()
    private var panel: NSPanel?
    private var view: AZSVolumeHUDView?
    private var dismissWorkItem: DispatchWorkItem?

    func show(value: Float, muted: Bool = false, displayID: CGDirectDisplayID? = nil) {
        show(value: value, muted: muted, displayID: displayID, brightness: false)
    }

    func showBrightness(value: Float, displayID: CGDirectDisplayID? = nil) {
        show(value: value, muted: false, displayID: displayID, brightness: true)
    }

    private func show(value: Float, muted: Bool, displayID: CGDirectDisplayID?, brightness: Bool) {
        DispatchQueue.main.async {
            if self.panel == nil {
                let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 112),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
                p.isOpaque = false
                p.backgroundColor = .clear
                p.level = .statusBar
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                p.hasShadow = true
                p.ignoresMouseEvents = true
                let v = AZSVolumeHUDView(frame: p.contentView?.bounds ?? .zero)
                v.autoresizingMask = [.width, .height]
                p.contentView = v
                self.panel = p
                self.view = v
            }
            self.view?.set(value: value, muted: muted, brightness: brightness)
            let screen = displayID.flatMap { id in
                NSScreen.screens.first(where: { $0.azsHUDDisplayID == id })
            } ?? NSScreen.main
            if let screen {
                let frame = screen.visibleFrame
                self.panel?.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.minY + 96))
            }
            self.panel?.orderFrontRegardless()
            self.dismissWorkItem?.cancel()
            let dismiss = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            self.dismissWorkItem = dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: dismiss)
        }
    }
}

/// Draws the entire HUD in one view. This avoids a transparent/visual-effect
/// subview ordering issue on macOS 26 that previously produced a blank white
/// rectangle instead of the slider contents.
private final class AZSVolumeHUDView: NSView {
    private var value: CGFloat = 0.5
    private var muted = false
    private var brightness = false

    override var isOpaque: Bool { false }

    func set(value: Float, muted: Bool, brightness: Bool) {
        self.value = CGFloat(max(0, min(1, value)))
        self.muted = muted
        self.brightness = brightness
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
        let backgroundPath = NSBezierPath(roundedRect: background, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.06, alpha: 0.62).setFill()
        backgroundPath.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        let icon = brightness ? "☀" : (muted ? "🔇" : "🔊")
        let iconAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
        ]
        (icon as NSString).draw(at: NSPoint(x: 24, y: 65), withAttributes: iconAttributes)

        let percent = Int((value * 100).rounded())
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = brightness ? "Độ sáng \(percent)%" : "Âm lượng \(percent)%"
        (label as NSString).draw(at: NSPoint(x: 68, y: 67), withAttributes: labelAttributes)

        let track = NSRect(x: 24, y: 31, width: bounds.width - 48, height: 9)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4.5, yRadius: 4.5).fill()
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * value, height: track.height)
        if fill.width > 0 {
            (brightness ? NSColor.systemYellow : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 4.5, yRadius: 4.5).fill()
        }
        let knobX = min(track.maxX - 8, max(track.minX + 8, track.minX + track.width * value))
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 8, y: 27, width: 16, height: 16)).fill()
    }
}

private extension NSScreen {
    var azsHUDDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
