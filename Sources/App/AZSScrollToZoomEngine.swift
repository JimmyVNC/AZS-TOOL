import Foundation

// ScrollToZoom by alphaArgon is vendored under Sources/Platform/ScrollToZoom.
// This file intentionally contains configuration only; wheel-event handling,
// gesture construction, timing, and Mos compatibility stay in the original C
// modules instead of being approximated in Swift.

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

    fileprivate var sourceValue: UInt32 {
        switch self {
        case .option: return 0
        case .control: return 1
        case .command: return 2
        case .shift: return 3
        }
    }
}

final class AZSScrollToZoomEngine {
    static let shared = AZSScrollToZoomEngine()
    private init() {}

    func configure(enabled: Bool,
                   modifier: AZSScrollZoomModifier,
                   sensitivity: Double,
                   reversed: Bool,
                   usesCommandKeys: Bool) {
        let apply = {
            AZSConfigureScrollToZoom(enabled,
                                     modifier.sourceValue,
                                     sensitivity,
                                     reversed,
                                     usesCommandKeys)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func stop() {
        if Thread.isMainThread {
            AZSStopScrollToZoom()
        } else {
            DispatchQueue.main.async {
                AZSStopScrollToZoom()
            }
        }
    }
}
