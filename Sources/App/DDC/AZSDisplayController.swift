import AppKit
import Foundation

struct AZSDisplayTarget: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    var volume: Float
    var maximum: UInt16
    var brightness: Float
    var brightnessMaximum: UInt16
    var available: Bool
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

    private init() { refresh() }

    func refresh() {
        let screens = NSScreen.screens.filter { CGDisplayIsBuiltin($0.azsDisplayID) == 0 }
        let ids = screens.map { $0.azsDisplayID }
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
                let name = (screen.localizedName.isEmpty ? "Màn hình ngoài" : screen.localizedName)
                let available = arm[id] != nil || intel[id] != nil
                let volumeReading = self.readVCP(command: 0x62, id: id, arm: arm, intel: intel)
                let brightnessReading = self.readVCP(command: 0x10, id: id, arm: arm, intel: intel)
                let volumeMax = volumeReading?.1 ?? 100
                let brightnessMax = brightnessReading?.1 ?? 100
                let volume = volumeReading.map { volumeMax == 0 ? 0 : Float($0.0) / Float(volumeMax) } ?? 0.5
                let brightness = brightnessReading.map { brightnessMax == 0 ? 0 : Float($0.0) / Float(brightnessMax) } ?? 0.5
                return AZSDisplayTarget(id: id, name: name, volume: volume, maximum: volumeMax,
                                        brightness: brightness, brightnessMaximum: brightnessMax,
                                        available: available)
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
            if Arm64DDC.isArm64 {
                _ = Arm64DDC.write(service: self.armServices[id], command: 0x62, value: ddcValue)
            } else {
                _ = self.intelServices[id]?.write(command: 0x62, value: ddcValue, errorRecoveryWaitTime: 2000)
            }
        }
    }

    @discardableResult
    func stepKeyboardBrightness(by amount: Float) -> (CGDirectDisplayID, Float)? {
        guard let id = keyboardTargetID else { return nil }
        let value = max(0, min(1, brightness(for: id) + amount))
        setBrightness(value, for: id)
        return (id, value)
    }

    func setBrightness(_ value: Float, for id: CGDirectDisplayID) {
        let normalized = max(0, min(1, value))
        guard let target = targets.first(where: { $0.id == id }), target.available else { return }
        let maxValue = target.brightnessMaximum == 0 ? 100 : target.brightnessMaximum
        let ddcValue = UInt16(max(0, min(Int(maxValue), Int((normalized * Float(maxValue)).rounded()))))
        if let index = targets.firstIndex(where: { $0.id == id }) { targets[index].brightness = normalized }
        queue.async { [weak self] in
            guard let self else { return }
            if Arm64DDC.isArm64 {
                _ = Arm64DDC.write(service: self.armServices[id], command: 0x10, value: ddcValue)
            } else {
                _ = self.intelServices[id]?.write(command: 0x10, value: ddcValue, errorRecoveryWaitTime: 2000)
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
