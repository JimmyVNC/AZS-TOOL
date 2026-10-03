import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe invalidation for device jobs queued across sleep/wake.
final class AZSOperationEpoch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0
  var token: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func invalidate() {
    lock.lock()
    value &+= 1
    lock.unlock()
  }
  func isCurrent(_ token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value == token
  }
}

/// Preserve existing preferences. Schema metadata does not reset user settings.
enum AZSSettingsMigration {
  static func apply(to defaults: UserDefaults) {
    guard defaults.integer(forKey: "AZSConfigurationVersion") < 1 else { return }
    if defaults.string(forKey: "AZSLastSettingsPage") == "utilities" {
      defaults.set("mouse", forKey: "AZSLastSettingsPage")
    }
    // Retain old tuning before the existing Mos v3 compatibility migration.
    if defaults.integer(forKey: "AZSMosTuningVersion") < 3 {
      let keys = [
        "AZSSmoothScrollStep", "AZSSmoothScrollSpeed", "AZSSmoothScrollDuration",
        "AZSSmoothScrollDeadZone", "AZSSmoothScrollSimulatesTrackpad",
      ]
      var backup: [String: Any] = [:]
      for key in keys { if let value = defaults.object(forKey: key) { backup[key] = value } }
      if !backup.isEmpty { defaults.set(backup, forKey: "AZSLegacyScrollTuningBackup") }
    }
    defaults.set(1, forKey: "AZSConfigurationVersion")
  }
}

/// Short feedback without activating a window or interrupting typing.
@MainActor
final class AZSFeedbackHUD {
  static let shared = AZSFeedbackHUD()
  private var panel: NSPanel?
  private var dismissal: DispatchWorkItem?
  func show(_ message: String, success: Bool) {
    dismissal?.cancel()
    let window =
      panel
      ?? NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 390, height: 64),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel = window
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .statusBar
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = NSHostingView(
      rootView:
        Label(
          message, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(message))
    if let frame = NSScreen.main?.visibleFrame {
      window.setFrameOrigin(NSPoint(x: frame.midX - 195, y: frame.minY + 80))
    }
    window.orderFrontRegardless()
    let work = DispatchWorkItem { [weak window] in window?.orderOut(nil) }
    dismissal = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }
}

/// Bounded aggregate diagnostics. Never receives keycodes, text or clipboard data.
enum AZSDiagnostics {
  private static let lock = NSLock()
  private static var counts: [String: Int] = [:]
  private static var durations: [String: [Double]] = [:]
  private static let launched = ProcessInfo.processInfo.systemUptime
  static func increment(_ name: String) {
    lock.lock()
    counts[name, default: 0] += 1
    lock.unlock()
  }
  static func measure(_ name: String, since start: Double) {
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    lock.lock()
    var values = durations[name] ?? []
    if values.count == 256 { values.removeFirst() }
    values.append(elapsed)
    durations[name] = values
    lock.unlock()
  }
  static func summary() -> String {
    lock.lock()
    let counters = counts
    let samples = durations
    lock.unlock()
    var lines = ["Thời gian chạy: \(Int(ProcessInfo.processInfo.systemUptime - launched)) giây"]
    lines += counters.keys.sorted().map { "\($0): \(counters[$0] ?? 0)" }
    for key in samples.keys.sorted() {
      let sorted = (samples[key] ?? []).sorted()
      guard !sorted.isEmpty else { continue }
      let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
      lines.append(String(format: "%@: p95 %.3f ms (%d mẫu gần nhất)", key, p95, sorted.count))
    }
    return lines.joined(separator: "\n")
  }
}

struct AZSSettingsDocument: Codable {
  var version = 1
  var flags: [String: Bool]
  var numbers: [String: Double]
  var buttonActions: [String: String]
  var buttonApplications: [String: String]
  var actionHotKeys: [String: Int32]
  var applicationHotKeys: [String: Int32]
  var applicationPaths: [String: String]
  var zoomModifier: String
  var accessibilityApps: [String]
}

@MainActor
enum AZSConfigurationFile {
  private static let typingFlags: [String: ReferenceWritableKeyPath<AppState, Bool>] = [
    "isVietnamese": \.isVietnamese, "checkSpelling": \.checkSpelling,
    "modernOrthography": \.modernOrthography, "freeMark": \.freeMark, "quickTelex": \.quickTelex,
    "restoreIfWrongSpelling": \.restoreIfWrongSpelling,
    "fixRecommendBrowser": \.fixRecommendBrowser,
    "fixChromiumBrowser": \.fixChromiumBrowser, "upperCaseFirstChar": \.upperCaseFirstChar,
    "tempOffSpelling": \.tempOffSpelling, "allowZFWJ": \.allowZFWJ,
    "quickStartConsonant": \.quickStartConsonant, "quickEndConsonant": \.quickEndConsonant,
    "tempOffByCommand": \.tempOffByCommand, "otherLanguage": \.otherLanguage,
    "fixSpotlight": \.fixSpotlight, "useAXReplacement": \.useAXReplacement,
    "useMacro": \.useMacro, "useMacroInEnglishMode": \.useMacroInEnglishMode,
    "autoCapsMacro": \.autoCapsMacro,
    "useSmartSwitchKey": \.useSmartSwitchKey, "rememberCode": \.rememberCode,
    "sendKeyStepByStep": \.sendKeyStepByStep, "performLayoutCompat": \.performLayoutCompat,
    "grayIcon": \.grayIcon, "showIconOnDock": \.showIconOnDock,
    "showUIOnStartup": \.showUIOnStartup,
    "convertAlert": \.convertAlert, "convertRemoveMark": \.convertRemoveMark,
  ]
  private static let utilityFlags: [String: ReferenceWritableKeyPath<AZSUtilityController, Bool>] =
    [
      "reverseScrolling": \.reverseScrolling, "smoothScrolling": \.smoothScrolling,
      "audioControlsEnabled": \.audioControlsEnabled,
      "displayControlsEnabled": \.displayControlsEnabled,
      "smoothScrollSimulatesTrackpad": \.smoothScrollSimulatesTrackpad,
      "scrollToZoomEnabled": \.scrollToZoomEnabled, "scrollToZoomReversed": \.scrollToZoomReversed,
      "scrollToZoomUsesCommandKeys": \.scrollToZoomUsesCommandKeys,
    ]
  private static let tuning:
    [String: (ReferenceWritableKeyPath<AZSUtilityController, Double>, ClosedRange<Double>)] = [
      "smoothScrollStep": (\.smoothScrollStep, 10...80),
      "smoothScrollSpeed": (\.smoothScrollSpeed, 0.5...5),
      "smoothScrollDuration": (\.smoothScrollDuration, 0.5...5),
      "smoothScrollDeadZone": (\.smoothScrollDeadZone, 0.25...3),
      "scrollToZoomSensitivity": (\.scrollToZoomSensitivity, 0.25...3),
    ]

  static func snapshot() -> AZSSettingsDocument {
    let state = AppState.shared
    let utilities = AZSUtilityController.shared
    let clipboard = ClipboardManager.shared
    var flags = typingFlags.mapValues { state[keyPath: $0] }
    flags.merge(utilityFlags.mapValues { utilities[keyPath: $0] }) { _, new in new }
    flags["clipboardEnabled"] = clipboard.enabled
    flags["clipboardPinOnTop"] = clipboard.pinOnTop
    flags["clipboardAutoHide"] = clipboard.autoHide
    var numbers = tuning.mapValues { utilities[keyPath: $0.0] }
    numbers["inputType"] = Double(state.inputType)
    numbers["codeTable"] = Double(state.codeTable)
    numbers["switchKeyStatus"] = Double(state.switchKeyStatus)
    numbers["clipboardHotKey"] = Double(clipboard.hotKey)
    numbers["clipboardMaxItems"] = Double(clipboard.maxItems)
    numbers["convertFromCode"] = Double(state.convertFromCode)
    numbers["convertToCode"] = Double(state.convertToCode)
    numbers["convertCaseMode"] = Double(state.convertCaseMode)
    numbers["convertHotKey"] = Double(state.convertHotKey)
    return AZSSettingsDocument(
      flags: flags, numbers: numbers,
      buttonActions: utilities.buttonActions.reduce(into: [:]) {
        $0[String($1.key)] = $1.value.rawValue
      },
      buttonApplications: utilities.buttonApplications.reduce(into: [:]) {
        $0[String($1.key)] = $1.value
      },
      actionHotKeys: utilities.actionHotKeys,
      applicationHotKeys: utilities.applicationShortcutHotKeys.reduce(into: [:]) {
        $0[String($1.key)] = $1.value
      },
      applicationPaths: utilities.applicationShortcutPaths.reduce(into: [:]) {
        $0[String($1.key)] = $1.value
      },
      zoomModifier: utilities.scrollToZoomModifier.rawValue, accessibilityApps: state.axIncludeApps)
  }

  static func validate(_ document: AZSSettingsDocument) throws {
    func require(_ condition: Bool, _ message: String) throws {
      if !condition {
        throw NSError(
          domain: "AZSConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
      }
    }
    try require(document.version == 1, "Phiên bản cấu hình chưa được hỗ trợ")
    let allowedFlags = Set(typingFlags.keys).union(utilityFlags.keys).union([
      "clipboardEnabled", "clipboardPinOnTop", "clipboardAutoHide",
    ])
    try require(
      Set(document.flags.keys).isSubset(of: allowedFlags),
      "Cấu hình chứa tùy chọn không được hỗ trợ")
    var bounds = tuning.mapValues { $0.1 }
    bounds.merge([
      "inputType": 0...3, "codeTable": 0...4, "clipboardMaxItems": 10...100,
      "convertFromCode": 0...4, "convertToCode": 0...4, "convertCaseMode": 0...4,
      "switchKeyStatus": Double(Int32.min)...Double(Int32.max),
      "clipboardHotKey": Double(Int32.min)...Double(Int32.max),
      "convertHotKey": Double(Int32.min)...Double(Int32.max),
    ]) { _, new in new }
    for (key, value) in document.numbers {
      try require(
        value.isFinite && (bounds[key]?.contains(value) ?? false), "Giá trị không hợp lệ: \(key)")
      if tuning[key] == nil {
        try require(value.rounded() == value, "Giá trị phải là số nguyên: \(key)")
      }
    }
    try require(
      AZSScrollZoomModifier(rawValue: document.zoomModifier) != nil, "Phím zoom không hợp lệ")
    for (key, action) in document.buttonActions {
      try require(
        (Int(key).map { (2...9).contains($0) } ?? false) && AZSMouseAction(rawValue: action) != nil,
        "Gán nút chuột không hợp lệ")
    }
    let actions = Set(AZSMouseAction.customShortcutActions.map(\.rawValue))
    try require(
      Set(document.actionHotKeys.keys).isSubset(of: actions), "Shortcut không được hỗ trợ")
    try require(
      document.applicationHotKeys.keys.allSatisfy { Int($0).map { (0...4).contains($0) } ?? false },
      "Vị trí ứng dụng không hợp lệ")
    for (key, path) in document.applicationPaths {
      try require(
        (Int(key).map { (0...4).contains($0) } ?? false) && path.hasPrefix("/")
          && path.hasSuffix(".app"), "Đường dẫn ứng dụng không hợp lệ")
    }
    for (key, path) in document.buttonApplications {
      try require(
        (Int(key).map { (2...9).contains($0) } ?? false) && path.hasPrefix("/")
          && path.hasSuffix(".app"), "Đường dẫn ứng dụng chuột không hợp lệ")
    }
    try require(
      document.accessibilityApps.count <= 100
        && document.accessibilityApps.allSatisfy { $0.count <= 255 && !$0.contains("/") },
      "Danh sách ứng dụng Trợ năng không hợp lệ")
  }

  static func apply(_ document: AZSSettingsDocument) throws {
    try validate(document)  // Validate the entire document before changing anything.
    let state = AppState.shared
    let utilities = AZSUtilityController.shared
    let clipboard = ClipboardManager.shared
    utilities.withSettingsBatch {
      for (key, value) in document.flags {
        if let path = typingFlags[key] { state[keyPath: path] = value }
        if let path = utilityFlags[key] { utilities[keyPath: path] = value }
      }
      for (key, value) in document.numbers {
        if let entry = tuning[key] { utilities[keyPath: entry.0] = value }
      }
      utilities.buttonActions = document.buttonActions.reduce(into: [:]) {
        if let key = Int($1.key), let action = AZSMouseAction(rawValue: $1.value) {
          $0[key] = action
        }
      }
      utilities.buttonApplications = document.buttonApplications.reduce(into: [:]) {
        if let key = Int($1.key) { $0[key] = $1.value }
      }
      utilities.actionHotKeys = document.actionHotKeys
      utilities.applicationShortcutHotKeys = document.applicationHotKeys.reduce(into: [:]) {
        if let key = Int($1.key) { $0[key] = $1.value }
      }
      utilities.applicationShortcutPaths = document.applicationPaths.reduce(into: [:]) {
        if let key = Int($1.key) { $0[key] = $1.value }
      }
      utilities.scrollToZoomModifier =
        AZSScrollZoomModifier(rawValue: document.zoomModifier) ?? .option
    }
    if let value = document.numbers["inputType"] { state.inputType = Int(value) }
    if let value = document.numbers["codeTable"] { state.codeTable = Int(value) }
    if let value = document.numbers["switchKeyStatus"] { state.switchKeyStatus = Int32(value) }
    if let value = document.numbers["convertFromCode"] { state.convertFromCode = Int(value) }
    if let value = document.numbers["convertToCode"] { state.convertToCode = Int(value) }
    if let value = document.numbers["convertCaseMode"] { state.convertCaseMode = Int(value) }
    if let value = document.numbers["convertHotKey"] { state.convertHotKey = Int32(value) }
    if let value = document.numbers["clipboardHotKey"] { clipboard.hotKey = Int32(value) }
    if let value = document.numbers["clipboardMaxItems"] { clipboard.maxItems = Int(value) }
    if let value = document.flags["clipboardEnabled"] { clipboard.enabled = value }
    if let value = document.flags["clipboardPinOnTop"] { clipboard.pinOnTop = value }
    if let value = document.flags["clipboardAutoHide"] { clipboard.autoHide = value }
    state.axIncludeApps = document.accessibilityApps
    utilities.refreshActionHotKeys()
    clipboard.refreshHotKeyRegistration()
    UserDefaults.standard.set(1, forKey: "AZSConfigurationVersion")
  }

  static func exportSettings() throws -> Bool {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "AZS-Tools-settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(snapshot()).write(to: url, options: .atomic)
    return true
  }
  static func importSettings() throws -> Bool {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 1_048_576 else {
      throw NSError(
        domain: "AZSConfiguration", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "File cấu hình quá lớn"])
    }
    try apply(JSONDecoder().decode(AZSSettingsDocument.self, from: Data(contentsOf: url)))
    return true
  }

  static func diagnosticReport() -> String {
    let state = AppState.shared
    let utilities = AZSUtilityController.shared
    let displays = AZSDisplayController.shared
    return """
      AZS Tools — Chẩn đoán
      macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      Phiên bản: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
      Trợ năng: \(state.accessibilityGranted)
      Input Monitoring: \(state.inputMonitoringGranted)
      Bộ gõ đang chạy: \(state.eventTapRunning)
      Cuộn mượt: \(utilities.smoothScrolling)
      Zoom: \(utilities.scrollToZoomEnabled)
      Âm thanh: \(utilities.audioControlsEnabled)
      Độ sáng: \(utilities.displayControlsEnabled)
      Số màn hình: \(displays.targets.count)
      Màn hình: \(displays.status)
      Lệnh màn hình chờ: \(displays.pendingWriteCount)
      Lượt ghi màn hình đang chạy: \(displays.hasWriteInFlight)
      Số chuột: \(utilities.mouseDevices.count)
      Lỗi shortcut: \(utilities.shortcutErrors.count)
      Clipboard đang polling: \(ClipboardManager.shared.isPolling)
      Lỗi shortcut Clipboard: \(ClipboardManager.shared.hotKeyError ?? "Không có")
      Quạt đang polling: \(AZSFanController.shared.isPolling)
      Trạng thái quạt: \(AZSFanController.shared.status)
      \(AZSDiagnostics.summary())
      """
  }
  static func exportDiagnostics() throws -> Bool {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "AZS-Tools-diagnostics.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    try diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
    return true
  }
}
