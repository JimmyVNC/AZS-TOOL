import CoreGraphics
import CoreVideo
import AppKit
import Foundation
import os.lock

/// Mouse-wheel smoothing ported from Mos's ScrollCore/ScrollEvent,
/// ScrollFilter, ScrollPhase and ScrollPoster flow.
///
/// The implementation intentionally keeps Mos's data path:
///   physical wheel -> buffer/current interpolation -> curve filter
///   -> PointDeltaAxis event -> target application PID
///
/// Only the target PID and public gesture metadata are retained for the
/// complete gesture, as Mos does through ScrollDispatchContext. Every output
/// frame uses a fresh CGEvent so private IOHID payload cannot leak into mouse
/// movement. Frames are posted directly to the captured application PID so
/// momentum never re-enters session taps or interferes with pointer routing.
final class AZSSmoothScrollEngine {
    static let shared = AZSSmoothScrollEngine()

    /// "AZSSMOOT". Used only to prevent a posted replacement event from being
    /// picked up by the input tap a second time.
    static let syntheticEventMarker: Int64 = 0x415A53534D4F4F54

    private enum Phase {
        case idle
        case hold
        case trackingBegin
        case trackingOngoing
        case trackingEnd
        case momentumBegin
        case momentumOngoing
        case momentumEnd
        case leave
    }

    private struct PhaseTransitionPlan {
        let queue: [(Phase, Phase?)]
        let target: (Phase, Phase?)?
    }

    private struct AxisData {
        var line = Int64(0)
        var point = 0.0
        var fixed = 0.0
        var usable = 0.0
        var valid = false
    }

    private struct FrameSnapshot {
        let generation: UInt64
        let targetPID: pid_t
        let capturedAt: CFTimeInterval
        let enqueuedAt: CFTimeInterval
        let flags: CGEventFlags
        let location: CGPoint
        let vertical: Double
        let horizontal: Double
        let phase: (scroll: Double, momentum: Double)?
        let isPhaseTransition: Bool
    }

    struct DiagnosticsSnapshot {
        let postedFrames: UInt64
        let coalescedFrames: UInt64
        let droppedFrames: UInt64
        let coalescedRenderTicks: UInt64
        let currentQueueDepth: Int
        let renderWorkPending: Bool
        let displayLinkRunning: Bool
        let maxQueueDepth: Int
        let maximumPostLatency: CFTimeInterval
        let maximumRenderDuration: CFTimeInterval
        let maximumStateLockWait: CFTimeInterval
        let displayLinkStarts: UInt64
        let displayLinkStops: UInt64
        let idleCallbacks: UInt64
    }

    private let lock = AZSUnfairLock()
    private let mailboxLock = NSLock()
    private let renderSignalLock = NSLock()
    private let diagnosticsLock = NSLock()
    private let renderQueue = DispatchQueue(label: "site.vncard.azstools.mos.render",
                                             qos: .userInitiated)
    private let postQueue = DispatchQueue(label: "site.vncard.azstools.mos.post",
                                           qos: .userInitiated)
    private var renderSignalPending = false
    private var renderDrainScheduled = false
    private var pendingCoalescedRenderTicks: UInt64 = 0
    private var mailbox: [FrameSnapshot] = []
    private var mailboxDrainScheduled = false
    private let mailboxCapacity = 4
    private let maximumMotionQueueAge: CFTimeInterval = 0.050
    private let maximumPhaseQueueAge: CFTimeInterval = 0.150

    private var postedFrameCount: UInt64 = 0
    private var coalescedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var coalescedRenderTickCount: UInt64 = 0
    private var maximumQueueDepth = 0
    private var maximumPostLatency: CFTimeInterval = 0
    private var maximumRenderDuration: CFTimeInterval = 0
    private var maximumStateLockWait: CFTimeInterval = 0
    private var displayLinkStartCount: UInt64 = 0
    private var displayLinkStopCount: UInt64 = 0
    private var idleCallbackCount: UInt64 = 0

    private var displayLink: CVDisplayLink?
    private var enabled = false
    private var postEventAccess = false
    private var step = 33.6
    private var speed = 2.70
    private var durationTransition = 0.074
    private var deadZone = 1.0
    private var simulatesTrackpad = false

    // These are the same four values used by Mos's ScrollPoster.
    private var current = (y: 0.0, x: 0.0)
    private var delta = (y: 0.0, x: 0.0)
    private var buffer = (y: 0.0, x: 0.0)
    private var filter = MosCurveFilter()

    private var lastManualEventTime: CFTimeInterval = 0
    private var manualInputEnded = true
    private var momentumActive = false
    private var momentumEndScheduledTime: CFTimeInterval?
    private var trackingEndScheduledTime: CFTimeInterval?
    private var phase = Phase.idle
    private var pendingPhaseAfterDelivery: Phase?

    private var capturedFlags: CGEventFlags = []
    private var capturedLocation = CGPoint.zero
    private var targetPID: pid_t = 0
    private var capturedAt: CFTimeInterval = 0
    private var cachedFrontmostPID: pid_t = 0
    private var generation: UInt64 = 0
    private var gestureSerial: UInt64 = 0
    private var lastMeaningfulFrameTime: CFTimeInterval = 0
    private var lastDisplayLinkCallbackTime: CFTimeInterval = 0
    private var lastRenderTime: CFTimeInterval = 0

    private let manualContinuationThreshold: CFTimeInterval = 0.18
    private let manualSeparationThreshold: CFTimeInterval = 0.45
    private let trackingEndAdvance: CFTimeInterval = 0.04
    private let momentumEndDelay: CFTimeInterval = 0.13
    private let idlePosterStopDelay: CFTimeInterval = 0.25
    private let eventTTL: CFTimeInterval = 5.0
    private let canCreateSyntheticScrollEvents: Bool
    private var frontmostApplicationObserver: NSObjectProtocol?

    private init() {
        canCreateSyntheticScrollEvents = CGEvent(scrollWheelEvent2Source: nil,
                                                  units: .pixel,
                                                  wheelCount: 2,
                                                  wheel1: 0,
                                                  wheel2: 0,
                                                  wheel3: 0) != nil
        let initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        cachedFrontmostPID = initialPID == ProcessInfo.processInfo.processIdentifier ? 0 : initialPID
        frontmostApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.updateCachedFrontmostPID(application.processIdentifier)
        }
    }

    func configure(enabled: Bool,
                   step: Double,
                   speed: Double,
                   duration: Double,
                   deadZone: Double,
                   simulatesTrackpad: Bool) {
        let boundedStep = max(10.0, min(80.0, step))
        let boundedSpeed = max(0.50, min(5.00, speed))
        let boundedDuration = max(0.50, min(5.00, duration))
        let boundedDeadZone = max(0.25, min(3.00, deadZone))
        // Mos: 1 - sqrt(duration / 5.2), rounded to three decimals.
        let transition = max(0.001,
                             1.0 - sqrt(boundedDuration / 5.2))
        let roundedTransition = Double((transition * 1000.0).rounded() / 1000.0)

        lock.lock()
        let changed = self.enabled != enabled ||
            self.step != boundedStep || self.speed != boundedSpeed ||
            self.durationTransition != roundedTransition ||
            self.deadZone != boundedDeadZone ||
            self.simulatesTrackpad != simulatesTrackpad
        self.enabled = enabled
        self.step = boundedStep
        self.speed = boundedSpeed
        self.durationTransition = roundedTransition
        self.deadZone = boundedDeadZone
        self.simulatesTrackpad = simulatesTrackpad
        if changed { resetLocked(invalidateGeneration: true) }
        let shouldStopPoster = changed || !enabled
        lock.unlock()

        // Match Mos's ScrollPoster lifecycle: configuration creates no active
        // display work. The poster starts lazily on the first physical wheel
        // event and stops again when that gesture is complete. Keeping a
        // CVDisplayLink alive while idle needlessly wakes a high-priority
        // callback at the display refresh rate and can make pointer delivery
        // feel uneven when other utilities are enabled.
        if shouldStopPoster {
            stopDisplayLink()
            clearPendingWork()
        }
    }

    /// Returns true only when MOS has captured the event and has a running
    /// replacement poster. Otherwise the original wheel event is preserved.
    func process(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return false
        }

        let input = MosWheelEvent(event: event)
        guard input.hasUsableDelta else {
            return false
        }

        // This is Mos's trackpad test: phase or scrollCount identifies native
        // continuous input. Native trackpad/Magic Mouse input must pass through.
        guard !input.isTrackpad else {
            resetMotion()
            return false
        }

        // Match Mos's remote-control exception without treating every mouse
        // event with IsContinuous=1 as a trackpad event.
        if Self.isRemoteSmoothedEvent(event) {
            resetMotion()
            return false
        }

        // Never consume the physical wheel event unless macOS currently lets
        // us synthesize its replacement. CGEventPostToPid has no return value,
        // so failing open here is the only way to guarantee that enabling MOS
        // cannot make the wheel stop scrolling altogether.
        lockStateForHotPath()
        let canPost = postEventAccess
        lock.unlock()
        guard canPost, canCreateSyntheticScrollEvents else {
            resetMotion()
            return false
        }

        ensureDisplayLinkRunning()

        let now = CFAbsoluteTimeGetCurrent()
        let postingPID = targetPIDForPosting(event)
        lockStateForHotPath()
        guard enabled,
              let link = displayLink,
              CVDisplayLinkIsRunning(link),
              postingPID > 0 else {
            lock.unlock()
            return false
        }

        gestureSerial &+= 1

        let separatedByTime = lastManualEventTime == 0 ||
            now - lastManualEventTime >= manualSeparationThreshold
        let separatedPhase = phase == .idle || phase == .leave ||
            phase == .momentumEnd || phase == .trackingEnd
        let separated = manualInputEnded || separatedByTime || separatedPhase

        if input.y.valid {
            let y = input.y.usable < 0
                ? -max(abs(input.y.usable), step)
                : max(abs(input.y.usable), step)
            if y * delta.y > 0 {
                buffer.y += y * speed
            } else {
                buffer.y = y * speed
                current.y = 0
            }
            delta.y = y
        }
        if input.x.valid {
            let x = input.x.usable < 0
                ? -max(abs(input.x.usable), step)
                : max(abs(input.x.usable), step)
            if x * delta.x > 0 {
                buffer.x += x * speed
            } else {
                buffer.x = x * speed
                current.x = 0
            }
            delta.x = x
        }

        capturedFlags = event.flags
        capturedLocation = event.location
        targetPID = postingPID
        capturedAt = now
        lastMeaningfulFrameTime = now

        let plan = manualInputDetectedPlan(isSeparated: separated)
        emitPlanLocked(plan, delta: (0, 0), emitTargetImmediately: false)
        lastManualEventTime = now
        manualInputEnded = false
        momentumActive = false
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
        lock.unlock()
        return true
    }

    func resetMotion() {
        lock.lock()
        resetLocked(invalidateGeneration: true)
        lock.unlock()
        stopDisplayLink()
        clearPendingWork()
    }

    func prepareForSleep() {
        resetMotion()
        stopDisplayLink()
    }

    func resumeAfterWake() {
        let canPost = CGPreflightPostEventAccess()
        lock.lock()
        postEventAccess = canPost
        lock.unlock()
        // Sleep ends any in-progress gesture. Remain stopped until the next
        // real wheel event, as the standalone Mos poster does.
        stopDisplayLink()
    }

    /// Refresh only the TCC delivery capability during the periodic event-tap
    /// health check. This must not recreate CVDisplayLink: that check runs every
    /// three seconds, while the poster starts lazily from a real wheel event.
    /// Rebuilding here briefly stalls the main event-tap thread and presents as
    /// intermittent pointer/scroll jitter.
    func refreshPostEventAccess() {
        let canPost = CGPreflightPostEventAccess()
        lock.lock()
        let lostAccess = postEventAccess && !canPost
        postEventAccess = canPost
        if lostAccess {
            resetLocked(invalidateGeneration: true)
        }
        lock.unlock()
        if lostAccess {
            stopDisplayLink()
            clearPendingWork()
        }
    }

    /// Reset MOS after the shared Accessibility tap has been created or
    /// rebuilt. Startup config can run before TCC is ready, so a captured
    /// gesture must not survive across the tap boundary.
    func restartAfterEventTap() {
        let canPost = CGPreflightPostEventAccess()
        lock.lock()
        postEventAccess = canPost
        resetLocked(invalidateGeneration: true)
        lock.unlock()
        // Replacing the tap invalidates the old gesture, but is not itself a
        // reason to run a display link while the mouse is idle.
        stopDisplayLink()
        clearPendingWork()
    }

    private func ensureDisplayLinkRunning() {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        if let link = displayLink {
            if CVDisplayLinkIsRunning(link) {
                lock.unlock()
                return
            }
            lock.unlock()
            // Mos retains its stopped poster between wheel gestures and starts
            // that same instance again. Avoid allocating a new display link at
            // the first notch of every gesture.
            if CVDisplayLinkStart(link) == kCVReturnSuccess {
                lock.lock()
                lastDisplayLinkCallbackTime = CFAbsoluteTimeGetCurrent()
                lastRenderTime = 0
                lock.unlock()
                recordDisplayLinkStart()
                return
            }
            lock.lock()
            displayLink = nil
            lock.unlock()
            CVDisplayLinkStop(link)
        } else {
            lock.unlock()
        }

        var candidate: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&candidate) == kCVReturnSuccess,
              let candidate,
              CVDisplayLinkSetOutputCallback(candidate,
                                             azsSmoothScrollDisplayLinkCallback,
                                             Unmanaged.passUnretained(self).toOpaque()) == kCVReturnSuccess,
              CVDisplayLinkStart(candidate) == kCVReturnSuccess else {
            if let candidate { CVDisplayLinkStop(candidate) }
            NSLog("AZS MOS: CVDisplayLink could not be started; keeping native scroll")
            return
        }
        recordDisplayLinkStart()

        lock.lock()
        if enabled && displayLink == nil {
            displayLink = candidate
            lastDisplayLinkCallbackTime = CFAbsoluteTimeGetCurrent()
            lastRenderTime = 0
            lock.unlock()
        } else {
            lock.unlock()
            CVDisplayLinkStop(candidate)
            recordDisplayLinkStop()
        }
    }

    private func stopDisplayLink() {
        lock.lock()
        let oldLink = displayLink
        lastDisplayLinkCallbackTime = 0
        lastRenderTime = 0
        lock.unlock()
        if let oldLink, CVDisplayLinkIsRunning(oldLink) {
            CVDisplayLinkStop(oldLink)
            recordDisplayLinkStop()
        }
    }

    /// The real-time CVDisplayLink callback only calls this method. It never
    /// takes the MOS state lock, allocates a CGEvent, or posts into the event
    /// system. At most one render task and one pending tick can exist.
    fileprivate func signalRenderTick() -> CVReturn {
        var shouldSchedule = false
        renderSignalLock.lock()
        if renderSignalPending {
            pendingCoalescedRenderTicks &+= 1
        }
        renderSignalPending = true
        if !renderDrainScheduled {
            renderDrainScheduled = true
            shouldSchedule = true
        }
        renderSignalLock.unlock()

        if shouldSchedule {
            renderQueue.async { [weak self] in
                self?.drainRenderTicks()
            }
        }
        return kCVReturnSuccess
    }

    private func drainRenderTicks() {
        while true {
            renderSignalLock.lock()
            guard renderSignalPending else {
                renderDrainScheduled = false
                renderSignalLock.unlock()
                return
            }
            renderSignalPending = false
            let coalescedTicks = pendingCoalescedRenderTicks
            pendingCoalescedRenderTicks = 0
            renderSignalLock.unlock()

            if coalescedTicks > 0 {
                recordCoalescedRenderTicks(coalescedTicks)
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            _ = renderFrame()
            recordRenderDuration(ProcessInfo.processInfo.systemUptime - startedAt)
        }
    }

    private func clearPendingWork() {
        renderSignalLock.lock()
        renderSignalPending = false
        pendingCoalescedRenderTicks = 0
        renderSignalLock.unlock()

        mailboxLock.lock()
        if !mailbox.isEmpty {
            let dropped = UInt64(mailbox.count)
            mailbox.removeAll(keepingCapacity: true)
            mailboxLock.unlock()
            recordDroppedFrames(dropped)
        } else {
            mailboxLock.unlock()
        }
    }

    fileprivate func renderFrame() -> CVReturn {
        var stopPhase: Phase?
        var stopGestureSerial: UInt64?
        var frames: [FrameSnapshot] = []

        lockStateForHotPath()
        lastDisplayLinkCallbackTime = CFAbsoluteTimeGetCurrent()
        guard enabled, targetPID != 0 else {
            if targetPID == 0 { recordIdleCallback() }
            lock.unlock()
            return kCVReturnSuccess
        }

        // Mos's transition value is calibrated at 60 Hz. Normalize it against
        // elapsed render time so 120 Hz displays do not finish momentum twice
        // as quickly. Clamp a delayed worker to two 60 Hz frames to avoid a
        // single large catch-up jump when the system was briefly busy.
        let renderNow = ProcessInfo.processInfo.systemUptime
        let rawElapsed = lastRenderTime > 0 ? renderNow - lastRenderTime : 1.0 / 60.0
        let elapsed = max(1.0 / 240.0, min(1.0 / 30.0, rawElapsed))
        lastRenderTime = renderNow
        let transition = 1.0 - pow(1.0 - durationTransition, elapsed * 60.0)

        let frame = (
            y: (buffer.y - current.y) * transition,
            x: (buffer.x - current.x) * transition
        )
        current.y += frame.y
        current.x += frame.x

        let filtered = filter.fill(with: frame, elapsed: elapsed)
        let now = CFAbsoluteTimeGetCurrent()

        if !manualInputEnded,
           lastManualEventTime > 0,
           now - lastManualEventTime > manualContinuationThreshold {
            let endPlan = manualInputEndedPlan()
            emitPlanLocked(endPlan, delta: (0, 0), emitTargetImmediately: true, into: &frames)
            manualInputEnded = true
            if trackingEndScheduledTime == nil {
                trackingEndScheduledTime = now + trackingEndAdvance
            }
        }

        let residualY = buffer.y - current.y
        let residualX = buffer.x - current.x
        let residualMagnitude = max(abs(residualY), abs(residualX))

        if manualInputEnded && residualMagnitude > deadZone {
            if !momentumActive {
                emitPlanLocked(momentumStartPlan(), delta: (0, 0), emitTargetImmediately: false)
                momentumActive = true
            } else {
                emitPlanLocked(momentumOngoingPlan(), delta: (0, 0), emitTargetImmediately: false)
            }
            momentumEndScheduledTime = nil
            trackingEndScheduledTime = nil
        } else if momentumActive && residualMagnitude <= deadZone {
            if momentumEndScheduledTime == nil {
                momentumEndScheduledTime = now + momentumEndDelay
            }
        } else {
            momentumEndScheduledTime = nil
            if momentumActive { momentumActive = false }
        }

        let outputMagnitude = max(abs(filtered.y), abs(filtered.x))
        if outputMagnitude > deadZone {
            if let frame = makeFrameLocked(vertical: filtered.y,
                                           horizontal: filtered.x,
                                           isPhaseTransition: false) {
                frames.append(frame)
                lastMeaningfulFrameTime = now
                didDeliverFrameLocked()
            }
        }

        if let scheduled = momentumEndScheduledTime,
           momentumActive,
           now >= scheduled {
            momentumEndScheduledTime = nil
            momentumActive = false
            stopPhase = .momentumEnd
        }

        if stopPhase == nil,
           manualInputEnded,
           !momentumActive,
           residualMagnitude <= deadZone,
           let scheduled = trackingEndScheduledTime,
           now >= scheduled,
           outputMagnitude <= deadZone {
            trackingEndScheduledTime = nil
            stopPhase = .trackingEnd
        } else if stopPhase == nil {
            trackingEndScheduledTime = nil
        }

        // A defensive idle boundary prevents a malformed phase sequence from
        // leaving the real-time poster running indefinitely. It only applies
        // after input has ended and no meaningful output has been generated
        // for a quarter second, so normal Mos momentum remains unchanged.
        if stopPhase == nil,
           manualInputEnded,
           outputMagnitude <= deadZone,
           now - lastMeaningfulFrameTime >= idlePosterStopDelay {
            stopPhase = momentumActive ? .momentumEnd : .trackingEnd
            momentumActive = false
            momentumEndScheduledTime = nil
            trackingEndScheduledTime = nil
        }
        if stopPhase != nil {
            stopGestureSerial = gestureSerial
        }
        lock.unlock()

        for frame in frames { enqueue(frame) }
        if let stopPhase, let stopGestureSerial {
            finish(phase: stopPhase, expectedGestureSerial: stopGestureSerial)
        }
        return kCVReturnSuccess
    }

    private func finish(phase endPhase: Phase, expectedGestureSerial: UInt64) {
        lock.lock()
        let link = displayLink
        let shouldFinish = enabled && gestureSerial == expectedGestureSerial
        lock.unlock()
        guard shouldFinish else { return }
        // Stop outside the state lock. CVDisplayLinkStop may wait for an
        // in-flight callback, and that callback also takes this lock.
        if let link, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
            recordDisplayLinkStop()
        }

        lock.lock()
        guard enabled, gestureSerial == expectedGestureSerial else {
            lock.unlock()
            // A new physical wheel event arrived between deciding to finish
            // and stopping the poster. Preserve its buffer and restart lazily
            // on the main event-tap thread instead of erasing the new gesture.
            DispatchQueue.main.async { [weak self] in
                self?.ensureDisplayLinkRunning()
            }
            return
        }
        generation &+= 1
        let plan = momentumEndPlanOrTrackingEndPlan(for: endPhase)
        var frames: [FrameSnapshot] = []
        if simulatesTrackpad {
            emitPlanLocked(plan, delta: (0, 0), emitTargetImmediately: true, into: &frames)
        }
        resetLocked(invalidateGeneration: false)
        lock.unlock()
        for frame in frames { enqueue(frame) }
        // The next physical wheel event starts a new poster lazily.
    }

    private func resetLocked(invalidateGeneration: Bool) {
        if invalidateGeneration { generation &+= 1 }
        gestureSerial &+= 1
        current = (0, 0)
        delta = (0, 0)
        buffer = (0, 0)
        filter.reset()
        lastManualEventTime = 0
        manualInputEnded = true
        momentumActive = false
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
        phase = .idle
        pendingPhaseAfterDelivery = nil
        capturedFlags = []
        capturedLocation = .zero
        targetPID = 0
        capturedAt = 0
        lastMeaningfulFrameTime = 0
        lastRenderTime = 0
    }

    private func manualInputDetectedPlan(isSeparated: Bool) -> PhaseTransitionPlan {
        if phase == .momentumBegin || phase == .momentumOngoing {
            if isSeparated {
                return PhaseTransitionPlan(queue: [(.momentumEnd, .idle),
                                                   (.trackingBegin, .trackingOngoing)],
                                           target: nil)
            }
            return PhaseTransitionPlan(queue: [(.momentumEnd, .idle)],
                                       target: (.trackingBegin, .trackingOngoing))
        }
        if isSeparated {
            return PhaseTransitionPlan(queue: [(.trackingBegin, .trackingOngoing)],
                                       target: nil)
        }
        if phase == .trackingBegin || phase == .trackingOngoing {
            return PhaseTransitionPlan(queue: [], target: (.trackingOngoing, nil))
        }
        return PhaseTransitionPlan(queue: [], target: (.trackingBegin, .trackingOngoing))
    }

    private func manualInputEndedPlan() -> PhaseTransitionPlan {
        switch phase {
        case .trackingBegin, .trackingOngoing:
            return PhaseTransitionPlan(queue: [], target: (.trackingEnd, nil))
        default:
            return PhaseTransitionPlan(queue: [], target: nil)
        }
    }

    private func momentumStartPlan() -> PhaseTransitionPlan {
        switch phase {
        case .trackingEnd, .momentumEnd:
            return PhaseTransitionPlan(queue: [], target: (.momentumBegin, .momentumOngoing))
        case .momentumBegin:
            return PhaseTransitionPlan(queue: [], target: (.momentumOngoing, nil))
        default:
            return PhaseTransitionPlan(queue: [], target: nil)
        }
    }

    private func momentumOngoingPlan() -> PhaseTransitionPlan {
        phase == .momentumBegin
            ? PhaseTransitionPlan(queue: [], target: (.momentumOngoing, nil))
            : PhaseTransitionPlan(queue: [], target: nil)
    }

    private func momentumEndPlanOrTrackingEndPlan(for endPhase: Phase) -> PhaseTransitionPlan {
        switch endPhase {
        case .momentumEnd:
            switch phase {
            case .momentumBegin, .momentumOngoing:
                return PhaseTransitionPlan(queue: [], target: (.momentumEnd, .idle))
            default:
                return PhaseTransitionPlan(queue: [], target: nil)
            }
        case .trackingEnd:
            switch phase {
            case .trackingBegin, .trackingOngoing, .trackingEnd:
                return PhaseTransitionPlan(queue: [], target: (.trackingEnd, .idle))
            default:
                return PhaseTransitionPlan(queue: [], target: nil)
            }
        default:
            return PhaseTransitionPlan(queue: [], target: nil)
        }
    }

    private func emitPlanLocked(_ plan: PhaseTransitionPlan,
                                delta: (y: Double, x: Double),
                                emitTargetImmediately: Bool,
                                into frames: inout [FrameSnapshot]) {
        for item in plan.queue {
            emitPhaseLocked(item, delta: delta, into: &frames)
        }
        if let target = plan.target {
            if emitTargetImmediately {
                emitPhaseLocked(target, delta: delta, into: &frames)
            } else {
                phase = target.0
                pendingPhaseAfterDelivery = target.1
            }
        }
    }

    private func emitPlanLocked(_ plan: PhaseTransitionPlan,
                                delta: (y: Double, x: Double),
                                emitTargetImmediately: Bool) {
        var ignored: [FrameSnapshot] = []
        emitPlanLocked(plan, delta: delta, emitTargetImmediately: emitTargetImmediately, into: &ignored)
        for frame in ignored { enqueue(frame) }
    }

    private func emitPhaseLocked(_ item: (Phase, Phase?),
                                 delta: (y: Double, x: Double),
                                 into frames: inout [FrameSnapshot]) {
        phase = item.0
        pendingPhaseAfterDelivery = item.1
        if let frame = makeFrameLocked(vertical: delta.y,
                                       horizontal: delta.x,
                                       isPhaseTransition: true) {
            frames.append(frame)
            didDeliverFrameLocked()
        } else {
            didDeliverFrameLocked()
        }
    }

    private func didDeliverFrameLocked() {
        if let next = pendingPhaseAfterDelivery {
            phase = next
            pendingPhaseAfterDelivery = nil
        }
    }

    private func makeFrameLocked(vertical: Double,
                                 horizontal: Double,
                                 isPhaseTransition: Bool) -> FrameSnapshot? {
        guard targetPID > 0,
              CFAbsoluteTimeGetCurrent() - capturedAt <= eventTTL else {
            return nil
        }
        let phaseValues = simulatesTrackpad ? values(for: phase) : nil
        return FrameSnapshot(generation: generation,
                             targetPID: targetPID,
                             capturedAt: capturedAt,
                             enqueuedAt: CFAbsoluteTimeGetCurrent(),
                             flags: capturedFlags,
                             location: capturedLocation,
                             vertical: vertical,
                             horizontal: horizontal,
                             phase: phaseValues,
                             isPhaseTransition: isPhaseTransition)
    }

    private func enqueue(_ frame: FrameSnapshot) {
        var shouldScheduleDrain = false
        var accepted = true

        mailboxLock.lock()
        // Only adjacent motion frames are coalesced. A phase transition forms
        // an ordering boundary and is never silently crossed.
        if !frame.isPhaseTransition,
           let last = mailbox.last,
           !last.isPhaseTransition,
           last.generation == frame.generation {
            mailbox[mailbox.count - 1] = frame
            recordCoalescedFrame()
        } else {
            if mailbox.count >= mailboxCapacity {
                if let staleMotion = mailbox.firstIndex(where: { !$0.isPhaseTransition }) {
                    mailbox.remove(at: staleMotion)
                    recordDroppedFrame()
                } else if !frame.isPhaseTransition {
                    // All four slots contain ordering-critical phase frames.
                    // Prefer those over a motion frame that can be represented
                    // by the next display refresh.
                    accepted = false
                    recordDroppedFrame()
                } else {
                    // The state machine emits at most a small bounded burst of
                    // phase frames. If an abnormal fifth transition arrives,
                    // discard the oldest now-stale transition to keep the
                    // mailbox bounded and the newest end state deliverable.
                    mailbox.removeFirst()
                    recordDroppedFrame()
                }
            }
            if accepted { mailbox.append(frame) }
        }

        if accepted {
            recordQueueDepth(mailbox.count)
            if !mailboxDrainScheduled {
                mailboxDrainScheduled = true
                shouldScheduleDrain = true
            }
        }
        mailboxLock.unlock()

        if shouldScheduleDrain {
            postQueue.async { [weak self] in self?.drainMailbox() }
        }
    }

    private func drainMailbox() {
        while true {
            mailboxLock.lock()
            guard !mailbox.isEmpty else {
                mailboxDrainScheduled = false
                mailboxLock.unlock()
                return
            }
            let frame = mailbox.removeFirst()
            mailboxLock.unlock()

            let now = CFAbsoluteTimeGetCurrent()
            let maximumQueueAge = frame.isPhaseTransition
                ? maximumPhaseQueueAge
                : maximumMotionQueueAge
            guard now - frame.enqueuedAt <= maximumQueueAge,
                  now - frame.capturedAt <= eventTTL else {
                recordDroppedFrame()
                continue
            }

            lock.lock()
            let valid = enabled && generation == frame.generation
            lock.unlock()
            guard valid,
                  let event = CGEvent(scrollWheelEvent2Source: nil,
                                      units: .pixel,
                                      wheelCount: 2,
                                      wheel1: 0,
                                      wheel2: 0,
                                      wheel3: 0) else {
                recordDroppedFrame()
                continue
            }

            // Create a clean synthetic wheel event. Copying the physical event
            // and posting it at the session boundary can replay its private
            // IOHID attachment even after public mouse delta fields are zeroed,
            // which presents as an occasional cursor jump.
            event.flags = frame.flags
            event.location = frame.location
            event.setIntegerValueField(.eventTargetUnixProcessID,
                                       value: Int64(frame.targetPID))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1,
                                      value: frame.vertical)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2,
                                      value: frame.horizontal)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis3, value: 0)
            event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase = frame.phase {
                event.setDoubleValueField(.scrollWheelEventScrollPhase, value: phase.scroll)
                event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phase.momentum)
            }
            event.setIntegerValueField(.eventSourceUserData,
                                       value: Self.syntheticEventMarker)
            // Use the session boundary for compatibility with browsers and
            // apps that reject CGEventPostToPid wheel events. The event is
            // still freshly constructed, so no physical IOHID payload or
            // hidden mouse delta can affect pointer movement.
            event.post(tap: .cgSessionEventTap)
            recordPostedFrame(latency: CFAbsoluteTimeGetCurrent() - frame.enqueuedAt)
        }
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        mailboxLock.lock()
        let currentQueueDepth = mailbox.count
        mailboxLock.unlock()

        renderSignalLock.lock()
        let renderWorkPending = renderSignalPending || renderDrainScheduled
        renderSignalLock.unlock()

        lock.lock()
        let displayLinkRunning = displayLink.map(CVDisplayLinkIsRunning) ?? false
        lock.unlock()

        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return DiagnosticsSnapshot(postedFrames: postedFrameCount,
                                   coalescedFrames: coalescedFrameCount,
                                   droppedFrames: droppedFrameCount,
                                   coalescedRenderTicks: coalescedRenderTickCount,
                                   currentQueueDepth: currentQueueDepth,
                                   renderWorkPending: renderWorkPending,
                                   displayLinkRunning: displayLinkRunning,
                                   maxQueueDepth: maximumQueueDepth,
                                   maximumPostLatency: maximumPostLatency,
                                   maximumRenderDuration: maximumRenderDuration,
                                   maximumStateLockWait: maximumStateLockWait,
                                   displayLinkStarts: displayLinkStartCount,
                                   displayLinkStops: displayLinkStopCount,
                                   idleCallbacks: idleCallbackCount)
    }

    private func recordPostedFrame(latency: CFTimeInterval) {
        diagnosticsLock.lock()
        postedFrameCount &+= 1
        maximumPostLatency = max(maximumPostLatency, latency)
        diagnosticsLock.unlock()
    }

    private func recordCoalescedFrame() {
        diagnosticsLock.lock()
        coalescedFrameCount &+= 1
        diagnosticsLock.unlock()
    }

    private func recordDroppedFrame() {
        recordDroppedFrames(1)
    }

    private func recordDroppedFrames(_ count: UInt64) {
        diagnosticsLock.lock()
        droppedFrameCount &+= count
        diagnosticsLock.unlock()
    }

    private func recordCoalescedRenderTicks(_ count: UInt64) {
        diagnosticsLock.lock()
        coalescedRenderTickCount &+= count
        diagnosticsLock.unlock()
    }

    private func recordRenderDuration(_ duration: CFTimeInterval) {
        diagnosticsLock.lock()
        maximumRenderDuration = max(maximumRenderDuration, duration)
        diagnosticsLock.unlock()
    }

    private func recordStateLockWait(_ duration: CFTimeInterval) {
        diagnosticsLock.lock()
        maximumStateLockWait = max(maximumStateLockWait, duration)
        diagnosticsLock.unlock()
    }

    @inline(__always)
    private func lockStateForHotPath() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        recordStateLockWait(ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private func recordQueueDepth(_ depth: Int) {
        diagnosticsLock.lock()
        maximumQueueDepth = max(maximumQueueDepth, depth)
        diagnosticsLock.unlock()
    }

    private func recordDisplayLinkStart() {
        diagnosticsLock.lock()
        displayLinkStartCount &+= 1
        diagnosticsLock.unlock()
    }

    private func recordDisplayLinkStop() {
        diagnosticsLock.lock()
        displayLinkStopCount &+= 1
        diagnosticsLock.unlock()
    }

    private func recordIdleCallback() {
        diagnosticsLock.lock()
        idleCallbackCount &+= 1
        diagnosticsLock.unlock()
    }

    private func values(for phase: Phase) -> (scroll: Double, momentum: Double) {
        switch phase {
        case .idle: return (0, 0)
        case .hold: return (128, 0)
        case .trackingBegin: return (1, 0)
        case .trackingOngoing: return (2, 0)
        case .trackingEnd: return (4, 0)
        case .momentumBegin: return (0, 1)
        case .momentumOngoing: return (0, 2)
        case .momentumEnd: return (0, 3)
        case .leave: return (8, 0)
        }
    }

    private func targetPIDForPosting(_ event: CGEvent) -> pid_t {
        let eventPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if eventPID > 1,
           eventPID != ProcessInfo.processInfo.processIdentifier {
            updateCachedFrontmostPID(eventPID)
            return eventPID
        }
        // Some session-tap paths report 0/1 (or AZS itself). Reading the
        // workspace here for every wheel notch adds AppKit work to the input
        // hot path, so use the activation-notification cache instead.
        lock.lock()
        let frontmostPID = cachedFrontmostPID
        lock.unlock()
        guard frontmostPID > 1,
              frontmostPID != ProcessInfo.processInfo.processIdentifier else {
            return 0
        }
        return frontmostPID
    }

    private func updateCachedFrontmostPID(_ pid: pid_t) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        lock.lock()
        cachedFrontmostPID = pid > 1 && pid != ownPID ? pid : 0
        lock.unlock()
    }

    private static func isRemoteSmoothedEvent(_ event: CGEvent) -> Bool {
        // Mos only skips continuous events from known remote-control sources.
        // Keeping this narrow is important for high-resolution mouse wheels.
        let continuous = event.getDoubleValueField(.scrollWheelEventIsContinuous)
        guard continuous == 1.0 else { return false }
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard sourcePID != 0,
              let app = NSRunningApplication(processIdentifier: sourcePID) else {
            return false
        }
        let remoteBundleIDs = [
            "com.apple.ScreenSharing", "com.teamviewer.TeamViewer",
            "com.anydesk.AnyDesk", "com.google.ChromeRemoteDesktop",
            "com.microsoft.rdc.macos", "com.realvnc.vncviewer",
            "com.rustdesk.RustDesk"
        ]
        if let bundleID = app.bundleIdentifier, remoteBundleIDs.contains(bundleID) {
            return true
        }
        let remotePathKeywords = ["screensharingd", "teamviewer", "anydesk", "rustdesk"]
        guard let path = app.executableURL?.path else { return false }
        return remotePathKeywords.contains { path.localizedCaseInsensitiveContains($0) }
    }
}

/// A small non-recursive lock for the MOS state hot path. The lock is kept in
/// a reference type so the underlying os_unfair_lock address never moves.
private final class AZSUnfairLock {
    private var raw = os_unfair_lock_s()

    @inline(__always)
    func lock() {
        os_unfair_lock_lock(&raw)
    }

    @inline(__always)
    func unlock() {
        os_unfair_lock_unlock(&raw)
    }
}

private struct MosWheelEvent {
    let y: Axis
    let x: Axis
    let isTrackpad: Bool

    struct Axis {
        let line: Int64
        let point: Double
        let fixed: Double
        let usable: Double
        let valid: Bool
    }

    init(event: CGEvent) {
        y = Self.read(event,
                      line: .scrollWheelEventDeltaAxis1,
                      point: .scrollWheelEventPointDeltaAxis1,
                      fixed: .scrollWheelEventFixedPtDeltaAxis1)
        x = Self.read(event,
                      line: .scrollWheelEventDeltaAxis2,
                      point: .scrollWheelEventPointDeltaAxis2,
                      fixed: .scrollWheelEventFixedPtDeltaAxis2)
        let phaseLooksContinuous = event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0.0 ||
            event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0.0 ||
            event.getDoubleValueField(.scrollWheelEventScrollCount) != 0.0
        // Mos deliberately treats Logitech Options' continuous mouse stream
        // as a mouse, despite the phase fields it attaches to the event.
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let sourceIsLogitechOptions = NSRunningApplication(processIdentifier: sourcePID)?.bundleIdentifier ==
            "com.logitech.manager.daemon"
        isTrackpad = phaseLooksContinuous && !sourceIsLogitechOptions
    }

    var hasUsableDelta: Bool { (y.valid && y.usable != 0) || (x.valid && x.usable != 0) }

    private static func read(_ event: CGEvent,
                             line: CGEventField,
                             point: CGEventField,
                             fixed: CGEventField) -> Axis {
        let lineValue = Int64(event.getIntegerValueField(line))
        let pointValue = event.getDoubleValueField(point)
        let fixedValue = event.getDoubleValueField(fixed)
        if pointValue != 0 {
            return Axis(line: lineValue, point: pointValue, fixed: fixedValue,
                        usable: pointValue, valid: true)
        }
        if fixedValue != 0 {
            return Axis(line: lineValue, point: pointValue, fixed: fixedValue,
                        usable: fixedValue, valid: true)
        }
        if lineValue != 0 {
            return Axis(line: lineValue, point: pointValue, fixed: fixedValue,
                        usable: Double(lineValue), valid: true)
        }
        return Axis(line: lineValue, point: pointValue, fixed: fixedValue,
                    usable: 0, valid: false)
    }
}

private struct MosCurveFilter {
    private var y = [0.0, 0.0]
    private var x = [0.0, 0.0]

    mutating func fill(with value: (y: Double, x: Double),
                       elapsed: CFTimeInterval) -> (y: Double, x: Double) {
        // Mos's 0.23 filter coefficient is a per-frame value at 60 Hz.
        // Normalize it alongside the main interpolator for ProMotion displays.
        let coefficient = 1.0 - pow(1.0 - 0.23, elapsed * 60.0)
        y = polish(y, next: value.y, coefficient: coefficient)
        x = polish(x, next: value.x, coefficient: coefficient)
        return (y[0], x[0])
    }

    mutating func reset() {
        y = [0, 0]
        x = [0, 0]
    }

    private func polish(_ values: [Double],
                        next: Double,
                        coefficient: Double) -> [Double] {
        let first = values[1]
        let diff = next - first
        return [first, first + coefficient * diff, first + 0.5 * diff,
                first + 0.77 * diff, next]
    }
}

private let azsSmoothScrollDisplayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, _, _, _, context in
    guard let context else { return kCVReturnError }
    let engine = Unmanaged<AZSSmoothScrollEngine>.fromOpaque(context).takeUnretainedValue()
    return engine.signalRenderTick()
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
