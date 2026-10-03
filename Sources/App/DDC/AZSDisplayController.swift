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
  var volumeConfirmed = false
  var brightnessConfirmed = false
}

private enum AZSBuiltInBrightness {
  private typealias GetBrightness =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private static let handle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
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

/// UI state is main-thread owned. DDC transport objects are queue-owned.
final class AZSDisplayController: ObservableObject {
  static let shared = AZSDisplayController()
  @Published private(set) var targets: [AZSDisplayTarget] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var status = "Chưa quét màn hình"
  @Published var selectedID: CGDirectDisplayID? {
    didSet {
      if !restoringSelection, let id = selectedID {
        UserDefaults.standard.set(Self.stableID(id), forKey: "AZSSelectedDisplay")
      }
    }
  }
  private struct Key: Hashable {
    let id: CGDirectDisplayID
    let command: UInt8
  }
  private struct Write {
    let value: UInt16
    let normalized: Float
    let builtIn: Bool
    let version: UInt64
    let retry: Int
  }
  private struct Screen {
    let id: CGDirectDisplayID
    let name: String
    let builtIn: Bool
  }
  private var armServices: [CGDirectDisplayID: IOAVService] = [:]
  private var intelServices: [CGDirectDisplayID: IntelDDC] = [:]
  private let queue = DispatchQueue(label: "site.vncard.azs.ddc", qos: .userInitiated)
  private var pending: [Key: Write] = [:]
  private var versions: [Key: UInt64] = [:]
  private var generation: UInt64 = 0
  private let validityLock = NSLock()
  private var validGeneration: UInt64 = 0
  private var validVersions: [Key: UInt64] = [:]
  private var flushWork: DispatchWorkItem?
  private var refreshWork: DispatchWorkItem?
  private var writeInFlight = false
  private var refreshAgain = false
  private var audioEnabled = false
  private var brightnessEnabled = false
  private var sleeping = false
  private var restoringSelection = false
  private var observers: [NSObjectProtocol] = []
  var pendingWriteCount: Int { pending.count }
  var hasWriteInFlight: Bool { writeInFlight }
  #if AZS_TESTING
    private var testTransport: ((CGDirectDisplayID, UInt8, UInt16) -> Bool)?
    init(
      testTargets: [AZSDisplayTarget],
      transport: @escaping (CGDirectDisplayID, UInt8, UInt16) -> Bool
    ) {
      targets = testTargets
      testTransport = transport
      audioEnabled = true
      brightnessEnabled = true
      selectedID = testTargets.first?.id
    }
    func testSleep() {
      sleeping = true
      invalidateConnection()
    }
  #endif

  private init() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.invalidateConnection()
        self?.scheduleRefresh(delay: 0.3)
      })
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.sleeping = true
        self?.invalidateConnection()
        self?.status = "Tạm dừng khi máy ngủ"
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.sleeping = false
        self?.scheduleRefresh(delay: 1)
      })
  }

  func configure(audio: Bool, brightness: Bool) {
    guard audio != audioEnabled || brightness != brightnessEnabled else { return }
    audioEnabled = audio
    brightnessEnabled = brightness
    let retained = pending.filter { key, _ in key.command == 0x62 ? audio : brightness }
    invalidateConnection()
    pending = retained
    for (key, write) in retained { versions[key] = write.version }
    validityLock.lock()
    validVersions = versions
    validityLock.unlock()
    if audio || brightness {
      scheduleRefresh(delay: 0.1)
    } else {
      status = "Điều khiển âm thanh & màn hình đã tắt"
    }
  }

  private func invalidateConnection() {
    generation &+= 1
    validityLock.lock()
    validGeneration = generation
    validVersions.removeAll()
    validityLock.unlock()
    pending.removeAll()
    versions.removeAll()
    flushWork?.cancel()
    flushWork = nil
    refreshWork?.cancel()
    refreshWork = nil
    queue.async { [weak self] in
      self?.armServices.removeAll()
      self?.intelServices.removeAll()
    }
  }

  private func scheduleRefresh(delay: Double) {
    refreshWork?.cancel()
    guard !sleeping, audioEnabled || brightnessEnabled else { return }
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    refreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  func refresh() {
    guard !sleeping, audioEnabled || brightnessEnabled else { return }
    #if AZS_TESTING
      if testTransport != nil {
        flushPendingWrites()
        return
      }
    #endif
    guard !isRefreshing else {
      refreshAgain = true
      return
    }
    refreshWork?.cancel()
    refreshWork = nil
    isRefreshing = true
    status = "Đang quét màn hình…"
    let token = generation
    let readAudio = audioEnabled
    let readBrightness = brightnessEnabled
    let initialVersions = versions
    let screens = NSScreen.screens.map {
      Screen(
        id: $0.azsDisplayID, name: $0.localizedName,
        builtIn: CGDisplayIsBuiltin($0.azsDisplayID) != 0)
    }
    let ids = screens.filter { !$0.builtIn }.map(\.id)
    AZSDiagnostics.increment("display.scan")
    queue.async { [weak self] in
      guard let self else { return }
      var arm: [CGDirectDisplayID: IOAVService] = [:]
      var intel: [CGDirectDisplayID: IntelDDC] = [:]
      if Arm64DDC.isArm64 {
        for match in Arm64DDC.getServiceMatches(displayIDs: ids)
        where match.service != nil && !match.dummy { arm[match.displayID] = match.service }
      } else {
        for id in ids { if let ddc = IntelDDC(for: id) { intel[id] = ddc } }
      }
      let values = screens.map { screen -> AZSDisplayTarget in
        let id = screen.id
        let connected = arm[id] != nil || intel[id] != nil
        let volume =
          readAudio && connected ? self.readVCP(command: 0x62, id: id, arm: arm, intel: intel) : nil
        let brightness =
          readBrightness && connected
          ? self.readVCP(command: 0x10, id: id, arm: arm, intel: intel) : nil
        let native = readBrightness && screen.builtIn ? AZSBuiltInBrightness.get(id) : nil
        let vmax = max(1, volume?.1 ?? 100)
        let bmax = max(1, brightness?.1 ?? 100)
        return AZSDisplayTarget(
          id: id, name: screen.name.isEmpty ? "Màn hình" : screen.name,
          volume: volume.map { min(1, max(0, Float($0.0) / Float(vmax))) } ?? 0.5, maximum: vmax,
          brightness: min(1, max(0, native ?? brightness.map { Float($0.0) / Float(bmax) } ?? 0.5)),
          brightnessMaximum: bmax,
          available: connected,
          brightnessAvailable: screen.builtIn ? AZSBuiltInBrightness.available : connected,
          isBuiltIn: screen.builtIn, volumeConfirmed: volume != nil,
          brightnessConfirmed: native != nil || brightness != nil)
      }
      self.validityLock.lock()
      let valid = self.validGeneration == token
      self.validityLock.unlock()
      if valid {
        self.armServices = arm
        self.intelServices = intel
      }
      DispatchQueue.main.async {
        self.isRefreshing = false
        if token == self.generation && !self.sleeping
          && (self.audioEnabled || self.brightnessEnabled)
        {
          self.targets = values.map { value in
            var target = value
            if let old = self.targets.first(where: { $0.id == value.id }) {
              if self.versions[Key(id: value.id, command: 0x62)]
                != initialVersions[Key(id: value.id, command: 0x62)]
                || self.pending[Key(id: value.id, command: 0x62)] != nil
              {
                target.volume = old.volume
                target.volumeConfirmed = false
              }
              if self.versions[Key(id: value.id, command: 0x10)]
                != initialVersions[Key(id: value.id, command: 0x10)]
                || self.pending[Key(id: value.id, command: 0x10)] != nil
              {
                target.brightness = old.brightness
                target.brightnessConfirmed = false
              }
            }
            return target
          }
          self.restoreSelection()
          self.pending = self.pending.filter { key, _ in
            self.targets.contains {
              $0.id == key.id && (key.command == 0x62 ? $0.available : $0.brightnessAvailable)
            }
          }
          self.status =
            values.isEmpty ? "Chưa tìm thấy màn hình" : "Đã quét \(values.count) màn hình"
          self.flushPendingWrites()
        }
        if self.refreshAgain || token != self.generation {
          self.refreshAgain = false
          self.scheduleRefresh(delay: 0.2)
        }
      }
    }
  }

  private static func stableID(_ id: CGDirectDisplayID) -> String {
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
      return CFUUIDCreateString(nil, uuid) as String
    }
    return "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
  }
  private func restoreSelection() {
    restoringSelection = true
    defer { restoringSelection = false }
    let saved = UserDefaults.standard.string(forKey: "AZSSelectedDisplay")
    if let match = targets.first(where: { Self.stableID($0.id) == saved }) {
      selectedID = match.id
    } else if !targets.contains(where: { $0.id == selectedID }) {
      selectedID = targets.first?.id
    }
  }
  func volume(for id: CGDirectDisplayID) -> Float {
    targets.first(where: { $0.id == id })?.volume ?? 0.5
  }
  func brightness(for id: CGDirectDisplayID) -> Float {
    targets.first(where: { $0.id == id })?.brightness ?? 0.5
  }
  var keyboardTargetID: CGDirectDisplayID? {
    guard audioEnabled, !sleeping else { return nil }
    return targets.first(where: { $0.id == selectedID && $0.available })?.id
      ?? targets.first(where: { $0.available })?.id
  }
  var keyboardBrightnessTargetID: CGDirectDisplayID? {
    guard brightnessEnabled, !sleeping else { return nil }
    return targets.first(where: { $0.id == selectedID && $0.brightnessAvailable })?.id
      ?? targets.first(where: { $0.brightnessAvailable })?.id
  }
  @discardableResult
  func stepKeyboardVolume(by amount: Float) -> (CGDirectDisplayID, Float)? {
    guard let id = keyboardTargetID else { return nil }
    let value = max(0, min(1, volume(for: id) + amount))
    setVolume(value, for: id)
    return (id, value)
  }
  @discardableResult
  func stepKeyboardBrightness(by amount: Float) -> (CGDirectDisplayID, Float)? {
    guard let id = keyboardBrightnessTargetID else { return nil }
    let value = max(0, min(1, brightness(for: id) + amount))
    setBrightness(value, for: id)
    return (id, value)
  }
  func setVolume(_ value: Float, for id: CGDirectDisplayID) {
    enqueue(value, id: id, command: 0x62)
  }
  func setBrightness(_ value: Float, for id: CGDirectDisplayID) {
    enqueue(value, id: id, command: 0x10)
  }

  private func enqueue(_ value: Float, id: CGDirectDisplayID, command: UInt8) {
    guard !sleeping, value.isFinite, command == 0x62 ? audioEnabled : brightnessEnabled,
      let index = targets.firstIndex(where: { $0.id == id }),
      command == 0x62 ? targets[index].available : targets[index].brightnessAvailable
    else { return }
    let normalized = max(0, min(1, value))
    let maxValue = max(
      1, command == 0x62 ? targets[index].maximum : targets[index].brightnessMaximum)
    let key = Key(id: id, command: command)
    let version = (versions[key] ?? 0) &+ 1
    versions[key] = version
    validityLock.lock()
    validVersions[key] = version
    validityLock.unlock()
    if command == 0x62 {
      targets[index].volume = normalized
      targets[index].volumeConfirmed = false
    } else {
      targets[index].brightness = normalized
      targets[index].brightnessConfirmed = false
    }
    pending[key] = Write(
      value: UInt16((normalized * Float(maxValue)).rounded()), normalized: normalized,
      builtIn: targets[index].isBuiltIn, version: version, retry: 0)
    status = "Đang áp dụng…"
    guard flushWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in self?.flushPendingWrites() }
    flushWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
  }

  func flushPendingWrites() {
    flushWork?.cancel()
    flushWork = nil
    guard !writeInFlight, !isRefreshing, !sleeping, !pending.isEmpty else { return }
    let batch = pending
    pending.removeAll()
    let token = generation
    writeInFlight = true
    queue.async { [weak self] in
      guard let self else { return }
      var failures: [Key: Write] = [:]
      var applied = false
      for (key, write) in batch {
        self.validityLock.lock()
        let valid = self.validGeneration == token && self.validVersions[key] == write.version
        self.validityLock.unlock()
        guard valid else { continue }
        AZSDiagnostics.increment("display.write")
        let success = self.writeValue(write, key: key)
        if success { applied = true } else { failures[key] = write }
      }
      DispatchQueue.main.async {
        self.writeInFlight = false
        guard token == self.generation else {
          self.flushPendingWrites()
          return
        }
        var reconnect = false
        for (key, write) in failures
        where self.versions[key] == write.version && self.pending[key] == nil {
          if write.retry == 0 && !write.builtIn {
            self.pending[key] = Write(
              value: write.value, normalized: write.normalized, builtIn: false,
              version: write.version, retry: 1)
            reconnect = true
          } else {
            self.status = "Không áp dụng được. Kiểm tra kết nối và DDC/CI rồi quét lại."
            AZSDiagnostics.increment("display.write.failed")
          }
        }
        if failures.isEmpty && self.pending.isEmpty && applied {
          self.status = "Đã gửi giá trị yêu cầu tới màn hình"
        }
        if reconnect { self.refresh() } else { self.flushPendingWrites() }
      }
    }
  }
  private func writeValue(_ write: Write, key: Key) -> Bool {
    #if AZS_TESTING
      if let transport = testTransport { return transport(key.id, key.command, write.value) }
    #endif
    if write.builtIn { return AZSBuiltInBrightness.set(write.normalized, for: key.id) }
    if Arm64DDC.isArm64 {
      return Arm64DDC.write(service: armServices[key.id], command: key.command, value: write.value)
    }
    return intelServices[key.id]?.write(
      command: key.command, value: write.value, errorRecoveryWaitTime: 2000) ?? false
  }

  private func readVCP(
    command: UInt8, id: CGDirectDisplayID, arm: [CGDirectDisplayID: IOAVService],
    intel: [CGDirectDisplayID: IntelDDC]
  ) -> (UInt16, UInt16)? {
    if Arm64DDC.isArm64 {
      return Arm64DDC.read(service: arm[id], command: command, numOfRetryAttemps: 2)
    }
    return intel[id]?.read(command: command, tries: 2)
  }
}
extension NSScreen {
  fileprivate var azsDisplayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }
}
