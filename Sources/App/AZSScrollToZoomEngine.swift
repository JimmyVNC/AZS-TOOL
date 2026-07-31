import AppKit
import CoreGraphics

// Scroll-to-zoom event conversion is adapted from Scroll to Zoom by alphaArgon.
// Copyright (c) 2025 alphaArgon. Licensed under the MIT License.
// https://github.com/alphaArgon/ScrollToZoom

enum AZSScrollZoomModifier: String, CaseIterable, Identifiable {
    case option, control, command, shift

    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        }
    }
    var eventFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        case .shift: return .maskShift
        }
    }
}

final class AZSScrollToZoomEngine {
    static let shared = AZSScrollToZoomEngine()

    private let lock = NSLock()
    private var enabled = false
    private var modifier: AZSScrollZoomModifier = .option
    private var sensitivity = 1.0
    private var reversed = false
    private var usesCommandKeys = false
    private var zooming = false
    private var endWorkItem: DispatchWorkItem?
    private var zoomCenter = CGPoint.zero
    private var zoomFlags: CGEventFlags = []

    private let gestureType = CGEventType(rawValue: 29)!
    private let gestureHIDType = CGEventField(rawValue: 110)!
    private let gestureZoomValue = CGEventField(rawValue: 113)!
    private let gesturePhase = CGEventField(rawValue: 132)!
    private let directionInverted = CGEventField(rawValue: 137)!

    private init() {}

    func configure(enabled: Bool,
                   modifier: AZSScrollZoomModifier,
                   sensitivity: Double,
                   reversed: Bool,
                   usesCommandKeys: Bool) {
        lock.lock()
        self.enabled = enabled
        self.modifier = modifier
        self.sensitivity = max(0.25, min(3.0, sensitivity))
        self.reversed = reversed
        self.usesCommandKeys = usesCommandKeys
        if !enabled {
            endWorkItem?.cancel()
            endWorkItem = nil
            zooming = false
        }
        lock.unlock()
    }

    func process(_ event: CGEvent) -> Bool {
        lock.lock()
        let isEnabled = enabled
        let trigger = modifier
        let speed = sensitivity
        let shouldReverse = reversed
        let commandMode = usesCommandKeys
        lock.unlock()

        guard isEnabled, event.flags.contains(trigger.eventFlag) else { return false }

        var delta = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if delta == 0 {
            delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        }
        if event.getIntegerValueField(directionInverted) != 0 { delta = -delta }
        if shouldReverse { delta = -delta }
        guard delta != 0 else { return true }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ||
            event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
        if commandMode && !isContinuous {
            postCommandZoom(zoomIn: delta > 0, reference: event)
            return true
        }

        let value = max(-0.35, min(0.35, delta * 0.0025 * speed))
        let location = event.location
        var flags = event.flags
        flags.remove(trigger.eventFlag)

        lock.lock()
        let beginsSession = !zooming
        zooming = true
        zoomCenter = location
        zoomFlags = flags
        endWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.finishGesture() }
        endWorkItem = workItem
        lock.unlock()

        postGesture(phase: beginsSession ? 1 : 2,
                    value: value,
                    location: location,
                    flags: flags,
                    timestamp: event.timestamp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
        return true
    }

    private func finishGesture() {
        lock.lock()
        guard zooming else { lock.unlock(); return }
        zooming = false
        endWorkItem = nil
        let location = zoomCenter
        let flags = zoomFlags
        lock.unlock()
        postGesture(phase: 4, value: 0, location: location, flags: flags, timestamp: 0)
    }

    private func postGesture(phase: Int64,
                             value: Double,
                             location: CGPoint,
                             flags: CGEventFlags,
                             timestamp: CGEventTimestamp) {
        guard let gesture = CGEvent(source: nil) else { return }
        gesture.type = gestureType
        gesture.flags = flags
        gesture.location = location
        if timestamp != 0 { gesture.timestamp = timestamp }
        gesture.setIntegerValueField(gestureHIDType, value: 8)
        gesture.setIntegerValueField(gesturePhase, value: phase)
        gesture.setDoubleValueField(gestureZoomValue, value: value)
        gesture.post(tap: .cgSessionEventTap)
    }

    private func postCommandZoom(zoomIn: Bool, reference: CGEvent) {
        let keyCode = CGKeyCode(zoomIn ? 24 : 27)
        let flags: CGEventFlags = zoomIn ? [.maskCommand, .maskShift] : .maskCommand
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        for keyEvent in [down, up] {
            keyEvent.flags = flags
            keyEvent.location = reference.location
            keyEvent.setIntegerValueField(.eventSourceUserData,
                                          value: AZSUtilityController.syntheticUtilityEventMarker)
            keyEvent.post(tap: .cgSessionEventTap)
        }
    }
}
