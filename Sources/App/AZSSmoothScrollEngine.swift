import CoreGraphics
import CoreVideo
import AppKit
import Foundation

/// Mouse-wheel smoothing ported from Mos's ScrollCore/ScrollEvent,
/// ScrollFilter, ScrollPhase and ScrollPoster flow.
///
/// The implementation intentionally keeps Mos's data path:
///   physical wheel -> buffer/current interpolation -> curve filter
///   -> PointDeltaAxis event -> CGSessionEventTap
///
/// It does not rewrite private event fields. The original event template and
/// target PID are retained for the complete gesture, just as Mos does through
/// ScrollDispatchContext. AZS posts at the session boundary because its own
/// marker safely bypasses the shared input tap and permits cross-app delivery.
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
        let event: CGEvent
        let targetPID: pid_t
        let capturedAt: CFTimeInterval
        let vertical: Double
        let horizontal: Double
        let phase: (scroll: Double, momentum: Double)?
    }

    private let lock = NSLock()
    private let postQueue = DispatchQueue(label: "site.vncard.azstools.mos.post",
                                           qos: .userInteractive)

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

    private var eventTemplate: CGEvent?
    private var targetPID: pid_t = 0
    private var capturedAt: CFTimeInterval = 0
    private var generation: UInt64 = 0
    private var lastDisplayLinkCallbackTime: CFTimeInterval = 0

    private let manualContinuationThreshold: CFTimeInterval = 0.18
    private let manualSeparationThreshold: CFTimeInterval = 0.45
    private let trackingEndAdvance: CFTimeInterval = 0.04
    private let momentumEndDelay: CFTimeInterval = 0.13
    private let eventTTL: CFTimeInterval = 5.0

    private init() {}

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
        lock.lock()
        let canPost = postEventAccess
        lock.unlock()
        guard canPost,
              let copiedEvent = event.copy() else {
            resetMotion()
            return false
        }

        ensureDisplayLinkRunning()

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard enabled,
              let link = displayLink,
              CVDisplayLinkIsRunning(link),
              targetPIDForPosting(event) > 0 else {
            lock.unlock()
            return false
        }

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

        eventTemplate = copiedEvent
        targetPID = targetPIDForPosting(event)
        capturedAt = now

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
                lock.unlock()
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

        lock.lock()
        if enabled && displayLink == nil {
            displayLink = candidate
            lastDisplayLinkCallbackTime = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        } else {
            lock.unlock()
            CVDisplayLinkStop(candidate)
        }
    }

    private func stopDisplayLink() {
        lock.lock()
        let oldLink = displayLink
        displayLink = nil
        lastDisplayLinkCallbackTime = 0
        lock.unlock()
        if let oldLink, CVDisplayLinkIsRunning(oldLink) { CVDisplayLinkStop(oldLink) }
    }

    fileprivate func renderFrame() -> CVReturn {
        var stopPhase: Phase?
        var frames: [FrameSnapshot] = []

        lock.lock()
        lastDisplayLinkCallbackTime = CFAbsoluteTimeGetCurrent()
        guard enabled else {
            lock.unlock()
            return kCVReturnSuccess
        }

        // Exact Mos interpolation: current += lerp(current, buffer, duration).
        let frame = (
            y: (buffer.y - current.y) * durationTransition,
            x: (buffer.x - current.x) * durationTransition
        )
        current.y += frame.y
        current.x += frame.x

        let filtered = filter.fill(with: frame)
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
                                           useCurrentPhase: true) {
                frames.append(frame)
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
        lock.unlock()

        for frame in frames { enqueue(frame) }
        if let stopPhase { finish(phase: stopPhase) }
        return kCVReturnSuccess
    }

    private func finish(phase endPhase: Phase) {
        lock.lock()
        let link = displayLink
        let shouldFinish = enabled
        lock.unlock()
        // Stop outside the state lock. CVDisplayLinkStop may wait for an
        // in-flight callback, and that callback also takes this lock.
        if shouldFinish, let link, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }

        lock.lock()
        guard enabled else {
            lock.unlock()
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
        eventTemplate = nil
        targetPID = 0
        capturedAt = 0
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
                                       useCurrentPhase: false) {
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
                                 useCurrentPhase: Bool) -> FrameSnapshot? {
        guard let template = eventTemplate?.copy(),
              targetPID > 0,
              CFAbsoluteTimeGetCurrent() - capturedAt <= eventTTL else {
            return nil
        }
        let phaseValues = simulatesTrackpad
            ? values(for: useCurrentPhase ? phase : phase)
            : nil
        return FrameSnapshot(generation: generation,
                             event: template,
                             targetPID: targetPID,
                             capturedAt: capturedAt,
                             vertical: vertical,
                             horizontal: horizontal,
                             phase: phaseValues)
    }

    private func enqueue(_ frame: FrameSnapshot) {
        postQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.enabled && self.generation == frame.generation
            self.lock.unlock()
            guard valid,
                  CFAbsoluteTimeGetCurrent() - frame.capturedAt <= self.eventTTL,
                  let event = frame.event.copy() else { return }

            // Mos's poster payload is the interpolated PointDeltaAxis and,
            // when enabled, the public phase fields. Standalone Mos delivers
            // straight to the target PID, where replacing PointDelta is
            // sufficient. AZS has to post at the session boundary for reliable
            // cross-app delivery, so the physical wheel's line/fixed deltas
            // must be cleared first. Otherwise every display-link frame also
            // repeats the original wheel notch and scrolling becomes many
            // times faster than Mos.
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                      value: 0.0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                      value: 0.0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3,
                                      value: 0.0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1,
                                      value: frame.vertical)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2,
                                      value: frame.horizontal)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis3,
                                      value: 0.0)
            // The template is a hardware wheel event captured while the mouse
            // may also be moving. Mos posts directly to a PID, but AZS posts at
            // the session boundary; never replay any incidental pointer delta
            // carried by that template on every momentum frame.
            event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
            if let phase = frame.phase {
                event.setDoubleValueField(.scrollWheelEventScrollPhase, value: phase.scroll)
                event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phase.momentum)
            }
            event.setIntegerValueField(.eventSourceUserData,
                                       value: Self.syntheticEventMarker)
            // CGEventPostToPid is reliable in standalone Mos, but AZS also
            // owns the session and ScrollToZoom taps. On current macOS builds
            // direct cross-process delivery can be discarded even though the
            // PostEvent preflight succeeds, leaving the consumed wheel event
            // with no replacement. Post through the session boundary instead.
            // The marker above makes MKEngineHook pass this frame through
            // unchanged, so it cannot enter MOS recursively.
            event.post(tap: .cgSessionEventTap)
        }
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
           eventPID != ProcessInfo.processInfo.processIdentifier,
           NSRunningApplication(processIdentifier: eventPID) != nil {
            return eventPID
        }
        // The Mos reference normally receives the active target PID in the
        // event. Some session-tap paths report 0/1 (or AZS itself) instead;
        // posting to that sentinel consumes the original event but delivers
        // no replacement. Resolve the actual frontmost application instead.
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID > 1,
              frontmostPID != ProcessInfo.processInfo.processIdentifier else {
            return 0
        }
        return frontmostPID
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

    mutating func fill(with value: (y: Double, x: Double)) -> (y: Double, x: Double) {
        y = polish(y, next: value.y)
        x = polish(x, next: value.x)
        return (y[0], x[0])
    }

    mutating func reset() {
        y = [0, 0]
        x = [0, 0]
    }

    private func polish(_ values: [Double], next: Double) -> [Double] {
        let first = values[1]
        let diff = next - first
        return [first, first + 0.23 * diff, first + 0.5 * diff,
                first + 0.77 * diff, next]
    }
}

private let azsSmoothScrollDisplayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, _, _, _, context in
    guard let context else { return kCVReturnError }
    let engine = Unmanaged<AZSSmoothScrollEngine>.fromOpaque(context).takeUnretainedValue()
    return engine.renderFrame()
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
