import CoreGraphics
import CoreVideo
import Darwin
import Foundation

/// Display-synchronised smoothing for discrete mouse wheels.
///
/// Motion-curve reference: Mos by Caldis, https://github.com/Caldis/Mos.
/// Event construction/routing reference: Mac Mouse Fix by Noah Nuebling,
/// https://github.com/noah-nuebling/mac-mouse-fix.
/// The curve follows Mos's target/lerp plus curve-peak filtering model, with
/// two important safety changes for AZS Tools:
/// - physical wheel events are consumed only after a healthy poster and a
///   valid event-posting permission have been confirmed;
/// - replacement frames are clean continuous-scroll events posted at the
///   session event tap, so WindowServer routes them to the window currently
///   under the pointer instead of pinning them to a cached process ID.
/// Trackpad, Magic Mouse and already-continuous input always remain native.
final class AZSSmoothScrollEngine {
    static let shared = AZSSmoothScrollEngine()

    /// "AZSSMOOT". Synthetic events are ignored defensively if they ever pass
    /// through the session event tap again.
    static let syntheticEventMarker: Int64 = 0x415A53534D4F4F54
    // Mac Mouse Fix writes the event type through Quartz field 55 when
    // constructing its clean scroll events. Keep a public-API fallback in case
    // a future SDK stops exposing that raw field.
    private static let eventTypeField = CGEventField(rawValue: 55)

    /// One axis of the Mos-style motion model. `current` follows `target` and
    /// `filteredFrame` removes the sharp velocity peak produced by a wheel
    /// notch. `displayed` integrates that filtered velocity, so the complete
    /// gesture still lands on the exact requested pixel distance.
    private struct AxisState {
        var target = 0.0
        var current = 0.0
        var filteredFrame = 0.0
        var displayed = 0.0
        var emitted = 0.0
        var inputDirection = 0.0

        func reverses(with delta: Double) -> Bool {
            delta != 0 && inputDirection != 0 && inputDirection * delta < 0
        }

        mutating func append(_ delta: Double, maximumBacklog: Double) {
            guard delta != 0 else { return }
            let boundedDelta = max(-maximumBacklog, min(maximumBacklog, delta))
            target = max(current - maximumBacklog,
                         min(current + maximumBacklog, target + boundedDelta))
            inputDirection = boundedDelta
        }

        mutating func advance(motionTransition: Double,
                              filterTransition: Double,
                              deadZone: Double) -> Int32 {
            let rawFrame = (target - current) * motionTransition
            current += rawFrame

            // Mos's curve-peak filter is a low-pass over each interpolated
            // frame. Integrating the filtered frames preserves distance while
            // removing the harsh first-frame jump of a mechanical wheel.
            filteredFrame += (rawFrame - filteredFrame) * filterTransition
            displayed += filteredFrame

            let settled = abs(target - current) <= deadZone &&
                abs(filteredFrame) <= deadZone &&
                abs(target - displayed) <= 0.75
            if settled {
                current = target
                filteredFrame = 0
                displayed = target
            }

            let desiredPixelPosition = (settled ? target : displayed).rounded()
            let pixelDelta = desiredPixelPosition - emitted
            emitted = desiredPixelPosition
            return Self.clampedInt32(pixelDelta)
        }

        func isSettled(deadZone: Double) -> Bool {
            abs(target - current) <= deadZone &&
                abs(filteredFrame) <= deadZone &&
                abs(target - displayed) <= 0.75
        }

        mutating func reset() {
            target = 0
            current = 0
            filteredFrame = 0
            displayed = 0
            emitted = 0
            inputDirection = 0
        }

        private static func clampedInt32(_ value: Double) -> Int32 {
            let bounded = max(Double(Int32.min), min(Double(Int32.max), value))
            return Int32(bounded)
        }
    }

    /// Mac Mouse Fix keeps line deltas cumulative while emitting precise pixel
    /// deltas. Biasing the first value away from zero makes the first visible
    /// frame responsive without multiplying every 1-3 px frame into one line.
    private struct BiasedLineQuantizer {
        private var roundingError = 0.0
        private var direction = 0.0

        mutating func quantize(pixelDelta: Int32) -> Int64 {
            guard pixelDelta != 0 else { return 0 }
            let input = Double(pixelDelta) / 10.0
            if direction == 0 || direction * input < 0 {
                roundingError = 0
                direction = input < 0 ? -1 : 1
            }

            let precise = input + roundingError
            let rounded = direction > 0 ? ceil(precise) : floor(precise)
            roundingError = precise - rounded
            return Int64(rounded)
        }

        mutating func reset() {
            roundingError = 0
            direction = 0
        }
    }

    private struct FramePacket {
        let generation: UInt64
        let vertical: Int32
        let horizontal: Int32
        let verticalLine: Int64
        let horizontalLine: Int64
        let flags: CGEventFlags
        let capturedAt: CFTimeInterval
    }

    private let lock = NSLock()
    private let postQueue = DispatchQueue(label: "site.vncard.azstools.smooth-scroll.post",
                                          qos: .userInteractive)
    private var displayLink: CVDisplayLink?
    private var enabled = false
    private var smoothness = 0.72
    private var speed = 1.0
    private var vertical = AxisState()
    private var horizontal = AxisState()
    private var verticalLine = BiasedLineQuantizer()
    private var horizontalLine = BiasedLineQuantizer()
    private var motionActive = false
    private var latestFlags: CGEventFlags = []
    private var generation: UInt64 = 0
    private var lastInputTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var lastDisplayLinkCallbackTime: CFTimeInterval = 0
    private var recoveryScheduled = false

    private let gestureSeparation: CFTimeInterval = 0.45
    private let displayLinkStaleThreshold: CFTimeInterval = 1.0
    private let postedFrameTTL: CFTimeInterval = 0.25
    private let baseStep = 33.6
    private let maximumInputMultiplier = 4.0
    // Half a pixel is below visible precision but avoids dragging a single
    // notch through a long sub-pixel tail. The exact final pixel is flushed.
    private let deadZone = 0.50

    private init() {}

    func configure(enabled: Bool, smoothness: Double, speed: Double) {
        let boundedSmoothness = max(0.25, min(1.0, smoothness))
        let boundedSpeed = max(0.50, min(2.00, speed))

        lock.lock()
        let settingsChanged = self.enabled != enabled ||
            self.smoothness != boundedSmoothness || self.speed != boundedSpeed
        self.enabled = enabled
        self.smoothness = boundedSmoothness
        self.speed = boundedSpeed
        if settingsChanged {
            clearMotionLocked(invalidateQueuedFrames: true)
        }
        if !enabled { recoveryScheduled = false }
        lock.unlock()

        if enabled {
            ensureDisplayLinkRunning()
        } else {
            stopDisplayLink()
        }
    }

    /// Captures one physical wheel event. `true` means the event tap must
    /// consume the original event because this engine now owns the complete
    /// gesture. `false` is a fail-open native pass-through.
    func process(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return false
        }

        guard Self.isDiscreteMouseWheel(event) else {
            // Native momentum must take over immediately without an old mouse
            // tail continuing underneath it.
            resetMotion()
            return false
        }

        let rawVertical = Self.axisValue(event,
                                         point: .scrollWheelEventPointDeltaAxis1,
                                         fixed: .scrollWheelEventFixedPtDeltaAxis1,
                                         line: .scrollWheelEventDeltaAxis1)
        let rawHorizontal = Self.axisValue(event,
                                           point: .scrollWheelEventPointDeltaAxis2,
                                           fixed: .scrollWheelEventFixedPtDeltaAxis2,
                                           line: .scrollWheelEventDeltaAxis2)
        guard rawVertical != 0 || rawHorizontal != 0,
              CGPreflightPostEventAccess() else {
            resetMotion()
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        let uptime = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard enabled,
              let link = displayLink,
              CVDisplayLinkIsRunning(link),
              uptime - lastDisplayLinkCallbackTime <= displayLinkStaleThreshold else {
            lock.unlock()
            scheduleDisplayLinkRecovery()
            return false
        }

        if lastInputTime == 0 || now - lastInputTime >= gestureSeparation {
            clearMotionLocked(invalidateQueuedFrames: true)
        }

        let configuredSpeed = speed
        let maximumInput = baseStep * maximumInputMultiplier
        let y = Self.normalizedWheelValue(rawVertical,
                                          minimumStep: baseStep,
                                          maximumStep: maximumInput) * configuredSpeed
        let x = Self.normalizedWheelValue(rawHorizontal,
                                          minimumStep: baseStep,
                                          maximumStep: maximumInput) * configuredSpeed

        // Reversing direction brakes the complete old tail. It also advances
        // the posting generation so queued frames from the old direction can
        // never arrive after the new gesture.
        if vertical.reverses(with: y) || horizontal.reverses(with: x) {
            clearMotionLocked(invalidateQueuedFrames: true)
        }

        let maximumBacklog = baseStep * configuredSpeed * 24
        vertical.append(y, maximumBacklog: maximumBacklog)
        horizontal.append(x, maximumBacklog: maximumBacklog)
        motionActive = true
        latestFlags = event.flags
        lastInputTime = now
        lock.unlock()
        return true
    }

    func resetMotion() {
        lock.lock()
        clearMotionLocked(invalidateQueuedFrames: true)
        lock.unlock()
    }

    func prepareForSleep() {
        resetMotion()
        stopDisplayLink()
    }

    func resumeAfterWake() {
        lock.lock()
        let shouldResume = enabled
        lock.unlock()
        if shouldResume { recreateDisplayLink() }
    }

    private func ensureDisplayLinkRunning() {
        var staleLink: CVDisplayLink?
        lock.lock()
        guard enabled else {
            recoveryScheduled = false
            lock.unlock()
            return
        }
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            recoveryScheduled = false
            lock.unlock()
            return
        }
        staleLink = displayLink
        displayLink = nil
        lock.unlock()
        if let staleLink { CVDisplayLinkStop(staleLink) }

        var candidate: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&candidate) == kCVReturnSuccess,
              let candidate else {
            lock.lock()
            recoveryScheduled = false
            lock.unlock()
            NSLog("AZS smooth scroll: could not create CVDisplayLink; using native scrolling")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(candidate,
                                             azsSmoothScrollDisplayLinkCallback,
                                             context) == kCVReturnSuccess,
              CVDisplayLinkStart(candidate) == kCVReturnSuccess else {
            CVDisplayLinkStop(candidate)
            lock.lock()
            recoveryScheduled = false
            lock.unlock()
            NSLog("AZS smooth scroll: could not start CVDisplayLink; using native scrolling")
            return
        }

        lock.lock()
        if enabled && displayLink == nil {
            displayLink = candidate
            lastFrameTime = 0
            lastDisplayLinkCallbackTime = ProcessInfo.processInfo.systemUptime
            recoveryScheduled = false
            lock.unlock()
        } else {
            recoveryScheduled = false
            lock.unlock()
            CVDisplayLinkStop(candidate)
        }
    }

    private func recreateDisplayLink() {
        stopDisplayLink()
        ensureDisplayLinkRunning()
    }

    private func scheduleDisplayLinkRecovery() {
        lock.lock()
        guard enabled, !recoveryScheduled else {
            lock.unlock()
            return
        }
        recoveryScheduled = true
        clearMotionLocked(invalidateQueuedFrames: true)
        lock.unlock()

        // Recreating a display link can be relatively expensive. Never do it
        // inside the event-tap callback; that risks macOS disabling the tap.
        DispatchQueue.main.async { [weak self] in
            self?.recreateDisplayLink()
        }
    }

    private func stopDisplayLink() {
        lock.lock()
        let oldLink = displayLink
        displayLink = nil
        lastFrameTime = 0
        lastDisplayLinkCallbackTime = 0
        lock.unlock()
        if let oldLink, CVDisplayLinkIsRunning(oldLink) {
            CVDisplayLinkStop(oldLink)
        }
    }

    fileprivate func renderFrame(at hostTime: UInt64) -> CVReturn {
        let now: CFTimeInterval
        if hostTime != 0 {
            now = Double(hostTime) / CVGetHostClockFrequency()
        } else {
            now = ProcessInfo.processInfo.systemUptime
        }

        lock.lock()
        lastDisplayLinkCallbackTime = now
        guard enabled, motionActive else {
            lastFrameTime = now
            lock.unlock()
            return kCVReturnSuccess
        }

        let dt: Double
        if lastFrameTime == 0 {
            dt = 1.0 / 60.0
        } else {
            // Frame-rate independence keeps the same curve on 60/120/144 Hz.
            // Clamping wake/debugger gaps prevents a large catch-up jump.
            dt = max(1.0 / 240.0, min(1.0 / 30.0, now - lastFrameTime))
        }
        lastFrameTime = now

        let motionAt60Hz = transitionAt60HzLocked()
        // Mos uses 0.23. A slightly faster 0.27 follower removes its initial
        // zero frame while retaining the same rounded acceleration profile.
        let filterAt60Hz = 0.27
        let frameScale = dt * 60.0
        let motionTransition = 1.0 - pow(1.0 - motionAt60Hz, frameScale)
        let filterTransition = 1.0 - pow(1.0 - filterAt60Hz, frameScale)

        let outputY = vertical.advance(motionTransition: motionTransition,
                                       filterTransition: filterTransition,
                                       deadZone: deadZone)
        let outputX = horizontal.advance(motionTransition: motionTransition,
                                         filterTransition: filterTransition,
                                         deadZone: deadZone)
        let packet: FramePacket?
        if outputY != 0 || outputX != 0 {
            packet = FramePacket(generation: generation,
                                 vertical: outputY,
                                 horizontal: outputX,
                                 verticalLine: verticalLine.quantize(pixelDelta: outputY),
                                 horizontalLine: horizontalLine.quantize(pixelDelta: outputX),
                                 flags: latestFlags,
                                 capturedAt: ProcessInfo.processInfo.systemUptime)
        } else {
            packet = nil
        }
        let settled = vertical.isSettled(deadZone: deadZone) &&
            horizontal.isSettled(deadZone: deadZone)
        if settled {
            // Natural completion must not invalidate the final frames already
            // queued for posting.
            clearMotionLocked(invalidateQueuedFrames: false)
        }
        lock.unlock()

        if let packet { enqueue(packet) }
        return kCVReturnSuccess
    }

    private func clearMotionLocked(invalidateQueuedFrames: Bool) {
        if invalidateQueuedFrames { generation &+= 1 }
        vertical.reset()
        horizontal.reset()
        verticalLine.reset()
        horizontalLine.reset()
        motionActive = false
        latestFlags = []
        lastInputTime = 0
    }

    private func transitionAt60HzLocked() -> Double {
        // Higher smoothness means a smaller target transition and a longer,
        // softer tail. These bounds keep even 100% smoothness responsive.
        0.25 - (0.13 * smoothness)
    }

    private func enqueue(_ packet: FramePacket) {
        postQueue.async { [weak self] in
            guard let self,
                  self.isCurrentGeneration(packet.generation),
                  ProcessInfo.processInfo.systemUptime - packet.capturedAt <= self.postedFrameTTL,
                  let event = CGEvent(source: nil) else { return }

            // Mac Mouse Fix creates a clean event and posts it to the session
            // stream. WindowServer then performs normal hit-testing using the
            // current pointer location, including for non-active app windows.
            if let eventTypeField = Self.eventTypeField {
                event.setIntegerValueField(eventTypeField,
                                           value: Int64(CGEventType.scrollWheel.rawValue))
            } else {
                event.type = .scrollWheel
            }

            // Overwrite all public representations in line -> point -> fixed
            // order. Some macOS versions derive FixedPt from PointDelta, so
            // writing FixedPt last keeps every receiving framework coherent.
            Self.writePixelEvent(event,
                                 vertical: packet.vertical,
                                 horizontal: packet.horizontal,
                                 verticalLine: packet.verticalLine,
                                 horizontalLine: packet.horizontalLine)
            event.flags = packet.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.timestamp = CGEventTimestamp(mach_absolute_time())
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func writePixelEvent(_ event: CGEvent,
                                        vertical: Int32,
                                        horizontal: Int32,
                                        verticalLine: Int64,
                                        horizontalLine: Int64) {
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        writeAxis(event,
                  value: vertical,
                  lineValue: verticalLine,
                  line: .scrollWheelEventDeltaAxis1,
                  fixed: .scrollWheelEventFixedPtDeltaAxis1,
                  point: .scrollWheelEventPointDeltaAxis1)
        writeAxis(event,
                  value: horizontal,
                  lineValue: horizontalLine,
                  line: .scrollWheelEventDeltaAxis2,
                  fixed: .scrollWheelEventFixedPtDeltaAxis2,
                  point: .scrollWheelEventPointDeltaAxis2)
        writeAxis(event,
                  value: 0,
                  lineValue: 0,
                  line: .scrollWheelEventDeltaAxis3,
                  fixed: .scrollWheelEventFixedPtDeltaAxis3,
                  point: .scrollWheelEventPointDeltaAxis3)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    }

    private static func writeAxis(_ event: CGEvent,
                                  value: Int32,
                                  lineValue: Int64,
                                  line: CGEventField,
                                  fixed: CGEventField,
                                  point: CGEventField) {
        let pixels = Int64(value)
        event.setIntegerValueField(line, value: lineValue)
        event.setIntegerValueField(point, value: pixels)
        event.setDoubleValueField(fixed, value: Double(lineValue))
    }

    private func isCurrentGeneration(_ value: UInt64) -> Bool {
        lock.lock()
        let current = enabled && generation == value
        lock.unlock()
        return current
    }

    private static func isDiscreteMouseWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 &&
            event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0 &&
            event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
    }

    private static func axisValue(_ event: CGEvent,
                                  point: CGEventField,
                                  fixed: CGEventField,
                                  line: CGEventField) -> Double {
        // PointDeltaAxis is an integer pixel field in CoreGraphics. Reading it
        // through the double accessor returns zero on some mouse drivers.
        let pointValue = Double(event.getIntegerValueField(point))
        if pointValue != 0 { return pointValue }
        let fixedValue = event.getDoubleValueField(fixed)
        if fixedValue != 0 { return fixedValue }
        return Double(event.getIntegerValueField(line))
    }

    private static func normalizedWheelValue(_ value: Double,
                                             minimumStep: Double,
                                             maximumStep: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        let sign = value < 0 ? -1.0 : 1.0
        let magnitude = min(max(abs(value), minimumStep), maximumStep)
        return sign * magnitude
    }
}

private let azsSmoothScrollDisplayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, outputTime, _, _, context in
    guard let context else { return kCVReturnError }
    let engine = Unmanaged<AZSSmoothScrollEngine>.fromOpaque(context).takeUnretainedValue()
    return engine.renderFrame(at: outputTime.pointee.hostTime)
}

@_cdecl("AZSIsSyntheticSmoothScrollEvent")
func AZSIsSyntheticSmoothScrollEvent(_ eventPointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let eventPointer else { return 0 }
    let event = Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()
    return event.getIntegerValueField(.eventSourceUserData) == AZSSmoothScrollEngine.syntheticEventMarker ? 1 : 0
}

@_cdecl("AZSResetSmoothScroll")
func AZSResetSmoothScroll() {
    AZSSmoothScrollEngine.shared.resetMotion()
}
