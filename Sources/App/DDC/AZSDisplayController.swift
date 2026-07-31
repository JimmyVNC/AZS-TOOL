import AppKit
import Darwin
import Foundation

struct AZSDisplayTarget: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    var volume: Float
    var maximum: UInt16
    var brightness: Float
    var brightnessMaximum: UInt16
    var available: Bool
    var brightnessAvailable: Bool
    let isBuiltIn: Bool
}

private enum AZSBuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFunction: GetBrightness? = symbol("DisplayServicesGetBrightness")
    private static let setFunction: SetBrightness? = symbol("DisplayServicesSetBrightness")

    static var available: Bool { getFunction != nil && setFunction != nil }

    static func get(_ id: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value: Float = 0
        return getFunction(id, &value) == 0 ? max(0, min(1, value)) : nil
    }

    @discardableResult
    static func set(_ value: Float, for id: CGDirectDisplayID) -> Bool {
        guard let setFunction else { return false }
        return setFunction(id, max(0, min(1, value))) == 0
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// Small DDC facade for external monitor speakers. It uses the same DDC
/// transport as MonitorControl: Arm64DDC on Apple silicon and IntelDDC on x86.
final class AZSDisplayController: ObservableObject {
    static let shared = AZSDisplayController()
    @Published private(set) var targets: [AZSDisplayTarget] = []
    @Published var selectedID: CGDirectDisplayID?

    private var armServices: [CGDirectDisplayID: IOAVService] = [:]
    private var intelServices: [CGDirectDisplayID: IntelDDC] = [:]
    private let queue = DispatchQueue(label: "site.vncard.azs.ddc", qos: .userInitiated)

    private init() {
        // DDC services are invalidated when a monitor is connected, removed,
        // or the display arrangement changes. Rebuild the mapping instead of
        // continuing to write through a stale IOAV/I2C service.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Do not keep IOAV/I2C objects across sleep. macOS recreates the
            // display transport on wake, so these references become stale.
            self?.queue.async {
                self?.armServices.removeAll()
                self?.intelServices.removeAll()
            }
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Wait for WindowServer/IOKit to publish the new display services.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        let screens = NSScreen.screens
        let ids = screens.map { $0.azsDisplayID }.filter { CGDisplayIsBuiltin($0) == 0 }
        queue.async { [weak self] in
            guard let self else { return }
            var arm: [CGDirectDisplayID: IOAVService] = [:]
            var intel: [CGDirectDisplayID: IntelDDC] = [:]
            if Arm64DDC.isArm64 {
                for match in Arm64DDC.getServiceMatches(displayIDs: ids) where match.service != nil && !match.dummy {
                    arm[match.displayID] = match.service
                }
            } else {
                for id in ids {
                    if let ddc = IntelDDC(for: id) { intel[id] = ddc }
                }
            }
            let values = screens.map { screen -> AZSDisplayTarget in
                let id = screen.azsDisplayID
                let isBuiltIn = CGDisplayIsBuiltin(id) != 0
                let name = (screen.localizedName.isEmpty ? "Màn hình ngoài" : screen.localizedName)
                let ddcAvailable = arm[id] != nil || intel[id] != nil
                let volumeReading = self.readVCP(command: 0x62, id: id, arm: arm, intel: intel)
                let ddcBrightnessReading = self.readVCP(command: 0x10, id: id, arm: arm, intel: intel)
                let nativeBrightness = isBuiltIn ? AZSBuiltInBrightness.get(id) : nil
                let volumeMax = volumeReading?.1 ?? 100
                let brightnessMax = ddcBrightnessReading?.1 ?? 100
                let volume = volumeReading.map { volumeMax == 0 ? 0 : Float($0.0) / Float(volumeMax) } ?? 0.5
                let brightness = nativeBrightness
                    ?? ddcBrightnessReading.map { brightnessMax == 0 ? 0 : Float($0.0) / Float(brightnessMax) }
                    ?? 0.5
                return AZSDisplayTarget(id: id, name: name, volume: volume, maximum: volumeMax,
                                        brightness: brightness, brightnessMaximum: brightnessMax,
                                        // Some monitors accept VCP writes but do not
                                        // return reliable reads. MonitorControl supports
                                        // this write-only mode as well, so transport
                                        // availability must be the capability gate.
                                        available: ddcAvailable,
                                        brightnessAvailable: isBuiltIn ? AZSBuiltInBrightness.available : ddcAvailable,
                                        isBuiltIn: isBuiltIn)
            }
            DispatchQueue.main.async {
                self.armServices = arm; self.intelServices = intel
                self.targets = values
                if self.selectedID == nil { self.selectedID = values.first?.id }
            }
        }
    }

    func volume(for id: CGDirectDisplayID) -> Float {
        targets.first(where: { $0.id == id })?.volume ?? 0.5
    }

    func brightness(for id: CGDirectDisplayID) -> Float {
        targets.first(where: { $0.id == id })?.brightness ?? 0.5
    }

    /// The display controlled by the hardware volume keys. Prefer the display
    /// selected in Utilities, then fall back to the first DDC-capable display.
    var keyboardTargetID: CGDirectDisplayID? {
        if let selectedID,
           targets.contains(where: { $0.id == selectedID && $0.available }) {
            return selectedID
        }
        return targets.first(where: { $0.available })?.id
    }

    /// Brightness support is independent from speaker-volume support in DDC.
    var keyboardBrightnessTargetID: CGDirectDisplayID? {
        if let selectedID,
           targets.contains(where: { $0.id == selectedID && $0.brightnessAvailable }) {
            return selectedID
        }
        return targets.first(where: { $0.brightnessAvailable })?.id
    }

    /// Changes external-display volume and returns the value actually applied.
    /// Keeping this calculation here means rapid key-repeat events always build
    /// on the latest UI value instead of an earlier asynchronous DDC read.
    @discardableResult
    func stepKeyboardVolume(by amount: Float) -> (CGDirectDisplayID, Float)? {
        guard let id = keyboardTargetID else { return nil }
        let value = max(0, min(1, volume(for: id) + amount))
        setVolume(value, for: id)
        return (id, value)
    }

    func setVolume(_ value: Float, for id: CGDirectDisplayID) {
        let normalized = max(0, min(1, value))
        guard let target = targets.first(where: { $0.id == id }), target.available else { return }
        let maxValue = target.maximum == 0 ? 100 : target.maximum
        let ddcValue = UInt16(max(0, min(Int(maxValue), Int((normalized * Float(maxValue)).rounded()))))
        if let index = targets.firstIndex(where: { $0.id == id }) { targets[index].volume = normalized }
        queue.async { [weak self] in
            guard let self else { return }
            var success = false
            if Arm64DDC.isArm64 {
                success = Arm64DDC.write(service: self.armServices[id], command: 0x62, value: ddcValue)
            } else {
                success = self.intelServices[id]?.write(command: 0x62, value: ddcValue, errorRecoveryWaitTime: 2000) ?? false
            }
            if !success {
                self.retryWriteAfterReconnect(command: 0x62, value: ddcValue, id: id)
            }
        }
    }

    @discardableResult
    func stepKeyboardBrightness(by amount: Float) -> (CGDirectDisplayID, Float)? {
        guard let id = keyboardBrightnessTargetID else { return nil }
        let value = max(0, min(1, brightness(for: id) + amount))
        setBrightness(value, for: id)
        return (id, value)
    }

    func setBrightness(_ value: Float, for id: CGDirectDisplayID) {
        let normalized = max(0, min(1, value))
        guard let target = targets.first(where: { $0.id == id }), target.brightnessAvailable else { return }
        let maxValue = target.brightnessMaximum == 0 ? 100 : target.brightnessMaximum
        let ddcValue = UInt16(max(0, min(Int(maxValue), Int((normalized * Float(maxValue)).rounded()))))
        if let index = targets.firstIndex(where: { $0.id == id }) { targets[index].brightness = normalized }
        if target.isBuiltIn {
            _ = AZSBuiltInBrightness.set(normalized, for: id)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var success = false
            if Arm64DDC.isArm64 {
                success = Arm64DDC.write(service: self.armServices[id], command: 0x10, value: ddcValue)
            } else {
                success = self.intelServices[id]?.write(command: 0x10, value: ddcValue, errorRecoveryWaitTime: 2000) ?? false
            }
            if !success {
                self.retryWriteAfterReconnect(command: 0x10, value: ddcValue, id: id)
            }
        }
    }

    private func retryWriteAfterReconnect(command: UInt8,
                                          value: UInt16,
                                          id: CGDirectDisplayID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self,
                      let target = self.targets.first(where: { $0.id == id }),
                      target.available else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    if Arm64DDC.isArm64 {
                        _ = Arm64DDC.write(service: self.armServices[id], command: command, value: value)
                    } else {
                        _ = self.intelServices[id]?.write(command: command, value: value, errorRecoveryWaitTime: 2000)
                    }
                }
            }
        }
    }

    private func readVCP(command: UInt8, id: CGDirectDisplayID, arm: [CGDirectDisplayID: IOAVService], intel: [CGDirectDisplayID: IntelDDC]) -> (UInt16, UInt16)? {
        if Arm64DDC.isArm64 { return Arm64DDC.read(service: arm[id], command: command, numOfRetryAttemps: 2) }
        return intel[id]?.read(command: command, tries: 2)
    }
}

private extension NSScreen {
    var azsDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
