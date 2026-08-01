import AppKit
import CoreGraphics

// Scroll-to-zoom event conversion is adapted from Scroll to Zoom by alphaArgon.
// Copyright (c) 2025 alphaArgon. Licensed under the MIT License.
// https://github.com/alphaArgon/ScrollToZoom

@_silgen_name("AZSPostZoomGesture")
private func AZSPostZoomGesture(_ tapProxy: UnsafeMutableRawPointer?,
                                _ referenceEvent: UnsafeMutableRawPointer,
                                _ phase: Int64,
                                _ centerX: Double,
                                _ centerY: Double,
                                _ value: Double,
                                _ timestamp: UInt64)

@_silgen_name("AZSPostZoomCommand")
private func AZSPostZoomCommand(_ tapProxy: UnsafeMutableRawPointer?,
                                _ referenceEvent: UnsafeMutableRawPointer,
                                _ zoomIn: Bool)

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

/// ScrollToZoom's state-machine behavior for a trigger-initiated zoom:
/// discrete wheel input begins a gesture with zero magnification, accumulated
/// changes are emitted one display-frame later, continuous end waits briefly
/// for momentum, and the gesture ends only after the source timeout expires.
final class AZSScrollToZoomEngine {
    static let shared = AZSScrollToZoomEngine()

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "site.vncard.azstools.scroll-to-zoom",
                                            qos: .userInteractive)

    private var enabled = false
    private var modifier: AZSScrollZoomModifier = .option
    private var sensitivity = 1.0
    private var reversed = false
    private var usesCommandKeys = false

    private var zooming = false
    private var generation: UInt64 = 0
    private var delayedZoom = 0.0
    private var firstChangeWorkItem: DispatchWorkItem?
    private var endWorkItem: DispatchWorkItem?
    private var zoomCenter = CGPoint.zero
    private var zoomFlags: CGEventFlags = []
    private var referenceEvent: CGEvent?
    private var lastWheelTime: CFTimeInterval = 0
    private var momentumStartTimestamp: CGEventTimestamp = .max

    // Same speedometer constants as ScrollToZoom.
    private var speedometerIndex = 0
    private var speedometerLastTime: CFTimeInterval = 0
    private var speedometerIntervals = Array(repeating: 0.35, count: 8)

    private let discreteEventDelay: CFTimeInterval = 0.01667
    private let momentumWait: CFTimeInterval = 0.05
    private let maximumDiscreteTimeout: CFTimeInterval = 0.35
    private let momentumAttenuation = 0.8
    private let minimumMomentumValue = 0.001
    private let magnificationScalar = 0.0025

    private let directionInverted = CGEventField(rawValue: 137)!

    private init() {}

    func configure(enabled: Bool,
                   modifier: AZSScrollZoomModifier,
                   sensitivity: Double,
                   reversed: Bool,
                   usesCommandKeys: Bool) {
        lock.lock()
        let shouldFinish = self.enabled && !enabled && zooming
        self.enabled = enabled
        self.modifier = modifier
        self.sensitivity = max(0.25, min(3.0, sensitivity))
        self.reversed = reversed
        self.usesCommandKeys = usesCommandKeys
        lock.unlock()
        if shouldFinish { finishGesture(tapProxy: nil, expectedGeneration: nil) }
    }

    func process(_ event: CGEvent,
                 tapProxy: UnsafeMutableRawPointer? = nil) -> Bool {
        lock.lock()
        let isEnabled = enabled
        let trigger = modifier
        let zoomSensitivity = sensitivity
        let shouldReverse = reversed
        let commandMode = usesCommandKeys
        let activeZoom = zooming
        lock.unlock()

        guard isEnabled, CGPreflightPostEventAccess() else { return false }

        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let isContinuous = scrollPhase != 0 || momentumPhase != 0
        let triggerHeld = event.flags.contains(trigger.eventFlag)
        let continuesActiveGesture = activeZoom && isContinuous

        guard triggerHeld || continuesActiveGesture else { return false }

        // ScrollToZoom waits 50 ms after a continuous end/cancel so a following
        // momentum-began event can continue the same zoom gesture.
        if scrollPhase == 4 || scrollPhase == 8 {
            guard activeZoom else { return false }
            scheduleEnd(after: momentumWait)
            return true
        }
        if momentumPhase == 3 {
            guard activeZoom else { return false }
            finishGesture(tapProxy: tapProxy, expectedGeneration: nil)
            return true
        }

        var delta = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if delta == 0 {
            delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        }
        guard delta != 0 else {
            // A continuous MayBegin event is consumed by the source state
            // machine while the real Changed event starts magnification.
            return isContinuous
        }

        if event.getIntegerValueField(directionInverted) != 0 { delta = -delta }
        if shouldReverse { delta = -delta }

        if commandMode && !isContinuous {
            postCommandZoom(zoomIn: delta > 0, reference: event, tapProxy: tapProxy)
            return true
        }

        var value = delta * magnificationScalar * zoomSensitivity
        if momentumPhase == 1 || momentumPhase == 2 {
            lock.lock()
            if momentumPhase == 1 && momentumStartTimestamp == .max {
                momentumStartTimestamp = event.timestamp
            }
            let momentumStart = momentumStartTimestamp
            lock.unlock()
            value = attenuateMomentum(value,
                                      eventTimestamp: event.timestamp,
                                      momentumStart: momentumStart)
            if value == 0 {
                finishGesture(tapProxy: tapProxy, expectedGeneration: nil)
                return true
            }
        }

        let location = event.location
        let now = ProcessInfo.processInfo.systemUptime

        let endDelay = isContinuous ? momentumWait : nextDiscreteEndDelay(now: now)

        lock.lock()
        let beginsSession = !zooming
        if beginsSession {
            generation &+= 1
            zoomCenter = location
            zoomFlags = event.flags
            referenceEvent = event.copy()
            if momentumPhase != 1 { momentumStartTimestamp = .max }
        } else {
            // Source retains the first gesture center but refreshes the event
            // template used to create the next gesture event.
            referenceEvent = event.copy()
            zoomFlags = event.flags
        }
        let currentGeneration = generation
        zooming = true
        lastWheelTime = now
        endWorkItem?.cancel()

        let endItem = DispatchWorkItem { [weak self] in
            self?.finishGesture(tapProxy: nil, expectedGeneration: currentGeneration)
        }
        endWorkItem = endItem

        let reference = referenceEvent
        let flags = zoomFlags
        let center = zoomCenter
        lock.unlock()

        if beginsSession && !isContinuous {
            lock.lock()
            delayedZoom += value
            lock.unlock()
            let firstItem = DispatchWorkItem { [weak self] in
                self?.flushDelayedZoom(expectedGeneration: currentGeneration)
            }
            lock.lock()
            firstChangeWorkItem?.cancel()
            firstChangeWorkItem = firstItem
            lock.unlock()
            if let reference {
                postGesture(phase: 1, value: 0, center: center,
                            flags: flags, timestamp: event.timestamp,
                            reference: reference, tapProxy: tapProxy)
            }
            workerQueue.asyncAfter(deadline: .now() + discreteEventDelay,
                                   execute: firstItem)
        } else if !isContinuous && isFirstChangePending {
            lock.lock()
            delayedZoom += value
            lock.unlock()
        } else if let reference {
            postGesture(phase: beginsSession ? 1 : 2,
                        value: value,
                        center: center,
                        flags: flags,
                        timestamp: event.timestamp,
                        reference: reference,
                        tapProxy: tapProxy)
        }

        workerQueue.asyncAfter(deadline: .now() + endDelay, execute: endItem)
        return true
    }

    private var isFirstChangePending: Bool {
        lock.lock()
        let pending = firstChangeWorkItem != nil
        lock.unlock()
        return pending
    }

    private func nextDiscreteEndDelay(now: CFTimeInterval) -> CFTimeInterval {
        lock.lock()
        if speedometerLastTime > 0 {
            let index = speedometerIndex
            speedometerIntervals[index] = max(0, now - speedometerLastTime)
            speedometerIndex = (index + 1) % speedometerIntervals.count
        }
        speedometerLastTime = now
        let maximumInterval = speedometerIntervals.max() ?? maximumDiscreteTimeout
        lock.unlock()
        return min(maximumDiscreteTimeout,
                   max(discreteEventDelay, maximumInterval * 1.5))
    }

    private func attenuateMomentum(_ value: Double,
                                   eventTimestamp: CGEventTimestamp,
                                   momentumStart: CGEventTimestamp) -> Double {
        guard momentumStart != .max,
              eventTimestamp >= momentumStart else { return value }
        let k = 1.0 - momentumAttenuation
        let seconds = Double(eventTimestamp - momentumStart) / 1_000_000_000.0
        let attenuated = value * (k == 0 ? 0 : pow(k, seconds / k))
        return abs(attenuated) < minimumMomentumValue ? 0 : attenuated
    }

    private func flushDelayedZoom(expectedGeneration: UInt64) {
        lock.lock()
        guard zooming, generation == expectedGeneration,
              delayedZoom != 0,
              let reference = referenceEvent?.copy() else {
            firstChangeWorkItem = nil
            lock.unlock()
            return
        }
        let value = delayedZoom
        delayedZoom = 0
        firstChangeWorkItem = nil
        let center = zoomCenter
        let flags = zoomFlags
        lock.unlock()
        postGesture(phase: 2, value: value, center: center, flags: flags,
                    timestamp: 0, reference: reference, tapProxy: nil)
    }

    private func scheduleEnd(after delay: CFTimeInterval) {
        lock.lock()
        guard zooming else {
            lock.unlock()
            return
        }
        let expectedGeneration = generation
        endWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finishGesture(tapProxy: nil, expectedGeneration: expectedGeneration)
        }
        endWorkItem = item
        lock.unlock()
        workerQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finishGesture(tapProxy: UnsafeMutableRawPointer?,
                               expectedGeneration: UInt64?) {
        lock.lock()
        guard zooming,
              expectedGeneration == nil || expectedGeneration == generation else {
            lock.unlock()
            return
        }
        zooming = false
        generation &+= 1
        firstChangeWorkItem?.cancel()
        firstChangeWorkItem = nil
        delayedZoom = 0
        endWorkItem?.cancel()
        endWorkItem = nil
        lastWheelTime = 0
        speedometerLastTime = 0
        speedometerIndex = 0
        speedometerIntervals = Array(repeating: maximumDiscreteTimeout, count: 8)
        momentumStartTimestamp = .max
        let center = zoomCenter
        let flags = zoomFlags
        let reference = referenceEvent?.copy()
        referenceEvent = nil
        lock.unlock()

        if let reference {
            postGesture(phase: 4, value: 0, center: center, flags: flags,
                        timestamp: 0, reference: reference, tapProxy: tapProxy)
        }
    }

    private func postGesture(phase: Int64,
                             value: Double,
                             center: CGPoint,
                             flags: CGEventFlags,
                             timestamp: CGEventTimestamp,
                             reference: CGEvent,
                             tapProxy: UnsafeMutableRawPointer?) {
        // The C bridge is the direct equivalent of ScrollToZoom's
        // createZoomEvent + CGEventTapPostEvent. It creates the gesture from
        // the original event source and uses the proxy only synchronously.
        AZSPostZoomGesture(tapProxy,
                           Unmanaged.passUnretained(reference).toOpaque(),
                           phase,
                           center.x,
                           center.y,
                           value,
                           timestamp)
        _ = flags // flags are read from the reference by the source-equivalent bridge.
    }

    private func postCommandZoom(zoomIn: Bool,
                                 reference: CGEvent,
                                 tapProxy: UnsafeMutableRawPointer?) {
        AZSPostZoomCommand(tapProxy,
                           Unmanaged.passUnretained(reference).toOpaque(),
                           zoomIn)
    }
}
