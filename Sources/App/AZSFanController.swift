import Darwin
import Foundation
import SwiftUI

enum AZSPrivilegedSMC {
  private static let helperLabel = "site.vncard.azstools.smc-helper"
  private static var serverSocketPath: String?
  private static var authorizationRequested = false
  private static var installationAttempted = false
  private(set) static var lastErrorMessage: String?

  private static var persistentSocketPath: String {
    "/var/run/\(helperLabel).\(getuid()).sock"
  }

  static func setTarget(index: Int, rpm: Double) -> Bool {
    run(command: "set-target", index: index, rpm: rpm)
  }

  static func setAuto(index: Int) -> Bool {
    run(command: "set-auto", index: index, rpm: nil)
  }

  static func isReady() -> Bool {
    send("ping", to: persistentSocketPath)
  }

  /// Installs and starts the helper without changing any fan setting.
  /// This keeps the one-time authorization separate from the first RPM drag.
  static func authorize() -> Bool {
    if isReady() {
      lastErrorMessage = nil
      return true
    }
    let executable = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/azs-smc-helper").path
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      lastErrorMessage = "Không tìm thấy helper Fan Control trong ứng dụng"
      return false
    }
    installationAttempted = true
    let installed = installPersistentHelper(executable: executable)
    if installed { lastErrorMessage = nil }
    return installed
  }

  static func shutdown() {
    if let socketPath = serverSocketPath {
      _ = send("quit", to: socketPath)
      let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
      try? FileManager.default.removeItem(at: directory)
      serverSocketPath = nil
    }
    authorizationRequested = false
  }

  private static func run(command: String, index: Int, rpm: Double?) -> Bool {
    let executable = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/azs-smc-helper").path
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      lastErrorMessage = "Không tìm thấy helper Fan Control trong ứng dụng"
      return false
    }
    var message = "\(command) \(index)"
    if let rpm { message += " \(Int(rpm.rounded()))" }

    // Prefer the installed launch daemon. It survives app/window restarts,
    // so authorization is requested only during the one-time installation.
    if send(message, to: persistentSocketPath) {
      lastErrorMessage = nil
      return true
    }

    if let socketPath = serverSocketPath, send(message, to: socketPath) {
      lastErrorMessage = nil
      return true
    }

    if !installationAttempted {
      installationAttempted = true
      if installPersistentHelper(executable: executable), send(message, to: persistentSocketPath) {
        lastErrorMessage = nil
        return true
      }
    }

    // Do not show another password dialog for every Apply. A failed
    // installation is reported once and can be retried after reopening
    // the app, instead of silently falling back to repeated prompts.
    lastErrorMessage =
      "Helper Fan Control chưa được cài. Hãy thoát và mở lại app để thử cấp quyền một lần nữa."
    return false
  }

  private static func installPersistentHelper(executable: String) -> Bool {
    let destinationHelper = "/Library/PrivilegedHelperTools/\(helperLabel)"
    let destinationPlist = "/Library/LaunchDaemons/\(helperLabel).plist"
    let uid = getuid()
    let gid = getgid()
    let plist: [String: Any] = [
      "Label": helperLabel,
      "ProgramArguments": [
        destinationHelper, "--launchd-server", persistentSocketPath, "\(uid)", "\(gid)",
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Background",
      "ThrottleInterval": 2,
    ]
    let temporaryPlist = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(helperLabel)-\(UUID().uuidString).plist")
    do {
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: temporaryPlist, options: .atomic)
    } catch {
      lastErrorMessage = "Không tạo được cấu hình helper: \(error.localizedDescription)"
      return false
    }

    let bootout = "/bin/launchctl bootout system/\(helperLabel) >/dev/null 2>&1 || /usr/bin/true"
    let installBinary =
      "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(executable)) \(shellQuote(destinationHelper))"
    let installPlist =
      "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(temporaryPlist.path)) \(shellQuote(destinationPlist))"
    let bootstrap = "/bin/launchctl bootstrap system \(shellQuote(destinationPlist))"
    let kickstart = "/bin/launchctl kickstart -k system/\(helperLabel)"
    let command = "\(bootout); \(installBinary) && \(installPlist) && \(bootstrap) && \(kickstart)"
    let installed = executePrivilegedShell(command)
    try? FileManager.default.removeItem(at: temporaryPlist)
    guard installed else {
      lastErrorMessage = "macOS không cài được helper Fan Control"
      return false
    }

    let readinessDeadline = ProcessInfo.processInfo.systemUptime + 5
    while ProcessInfo.processInfo.systemUptime < readinessDeadline {
      if send("ping", to: persistentSocketPath) {
        return true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    lastErrorMessage = "Helper đã cài nhưng chưa khởi động được"
    return false
  }

  private static func startServer(executable: String) -> Bool {
    guard !authorizationRequested else { return false }
    authorizationRequested = true
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("azs-smc-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch {
      authorizationRequested = false
      return false
    }
    let socketPath = directory.appendingPathComponent("control.sock").path
    // The helper daemonizes itself. Keeping this command foreground lets
    // AppleScript complete cleanly after the parent exits while the child
    // remains available for subsequent RPM writes.
    let command = "\(shellQuote(executable)) --server \(shellQuote(socketPath))"
    guard executePrivilegedShell(command) else {
      try? FileManager.default.removeItem(at: directory)
      authorizationRequested = false
      return false
    }

    // Wait briefly for the root process to bind its socket.
    for _ in 0..<20 {
      if FileManager.default.fileExists(atPath: socketPath), send("ping", to: socketPath) {
        serverSocketPath = socketPath
        return true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    try? FileManager.default.removeItem(at: directory)
    authorizationRequested = false
    return false
  }

  private static func runOneShot(executable: String, command: String, index: Int, rpm: Double?)
    -> Bool
  {
    let helperCommand = command == "set-target" ? "--set-target" : "--set-auto"
    var arguments = "\(helperCommand) \(index)"
    if let rpm { arguments += " \(Int(rpm.rounded()))" }
    return executePrivileged(executable: executable, arguments: arguments)
  }

  private static func executePrivileged(executable: String, arguments: String) -> Bool {
    executePrivilegedShell("\(shellQuote(executable)) \(arguments)")
  }

  private static func executePrivilegedShell(_ command: String) -> Bool {
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    // Keep script execution off the app's UI thread. macOS still presents its
    // normal administrator prompt; no authorization is requested at launch.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    do {
      try process.run()
      guard completion.wait(timeout: .now() + 60) == .success else {
        process.terminate()
        if completion.wait(timeout: .now() + 0.2) != .success {
          kill(process.processIdentifier, SIGKILL)
        }
        lastErrorMessage = "Hết thời gian xác thực. Bấm Bật điều khiển để thử lại."
        return false
      }
      return process.terminationStatus == 0
    } catch {
      lastErrorMessage = "Không chạy được yêu cầu xác thực: \(error.localizedDescription)"
      return false
    }
  }

  private static func send(_ message: String, to socketPath: String) -> Bool {
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-w", "2", "-U", socketPath]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    do {
      try process.run()
      input.fileHandleForWriting.write(Data((message + "\n").utf8))
      input.fileHandleForWriting.closeFile()
      guard completion.wait(timeout: .now() + 2.5) == .success else {
        process.terminate()
        if completion.wait(timeout: .now() + 0.2) != .success {
          kill(process.processIdentifier, SIGKILL)
        }
        lastErrorMessage = "Helper không phản hồi. Hãy thử lại hoặc cấp lại quyền điều khiển."
        return false
      }
      let response = String(
        data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
      return process.terminationStatus == 0 && response?.hasPrefix("OK") == true
    } catch {
      return false
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

struct AZSFanReading: Identifiable, Equatable, Sendable {
  let id: Int
  var actualRPM: Double
  var minimumRPM: Double
  var maximumRPM: Double
  var targetRPM: Double
  var manual: Bool
}

private struct AZSFanRefreshSnapshot: Sendable {
  let fans: [AZSFanReading]
  let status: String
}

/// AppleSMC uses synchronous IOConnect calls. Read it away from the main
/// run loop because the shared mouse event tap is serviced there as well.
private func AZSReadFanSnapshot() -> AZSFanRefreshSnapshot {
  let count = AZSSMCReadFanCount()
  var newFans: [AZSFanReading] = []
  if count > 0 {
    for index in 0..<Int(count) {
      var actual = 0.0
      var minimum = 0.0
      var maximum = 0.0
      var target = 0.0
      var manual: Int32 = 0
      if AZSSMCReadFan(Int32(index), &actual, &minimum, &maximum, &target, &manual) != 0 {
        newFans.append(
          AZSFanReading(
            id: index,
            actualRPM: actual,
            minimumRPM: minimum,
            maximumRPM: maximum,
            targetRPM: target,
            manual: manual != 0))
      }
    }
  }

  if !newFans.isEmpty {
    return AZSFanRefreshSnapshot(fans: newFans, status: "Đang theo dõi AppleSMC")
  }
  if let error = String(validatingCString: AZSSMCLastError()), !error.isEmpty {
    return AZSFanRefreshSnapshot(fans: [], status: error)
  }
  return AZSFanRefreshSnapshot(fans: [], status: "Không tìm thấy cảm biến SMC")
}

@MainActor
final class AZSFanController: ObservableObject {
  static let shared = AZSFanController()

  @Published private(set) var fans: [AZSFanReading] = []
  @Published private(set) var status = "Chưa đọc tốc độ quạt"
  @Published private(set) var isAvailable = false
  @Published private(set) var canControl = false
  @Published private(set) var isPerformingAction = false
  private var viewers: Set<String> = []
  private var sleeping = false
  nonisolated private let operationEpoch = AZSOperationEpoch()

  private var timer: Timer?
  var isPolling: Bool { timer?.isValid == true }
  private var refreshInFlight = false
  private let refreshQueue = DispatchQueue(
    label: "site.vncard.azstools.smc.monitor",
    qos: .utility)
  private init() {}
  func start(owner: String = "settings") {
    viewers.insert(owner)
    guard !sleeping, timer == nil else { return }
    refresh()
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    timer.tolerance = 0.4
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop(owner: String = "settings") {
    viewers.remove(owner)
    guard viewers.isEmpty else { return }
    timer?.invalidate()
    timer = nil
  }

  func prepareForSleep() {
    sleeping = true
    operationEpoch.invalidate()
    timer?.invalidate()
    timer = nil
  }

  func resumeAfterWake() {
    sleeping = false
    if let owner = viewers.first { start(owner: owner) }
  }

  func refresh() {
    guard !refreshInFlight, !sleeping, !isPerformingAction else { return }
    refreshInFlight = true
    let epoch = operationEpoch.token
    AZSDiagnostics.increment("fan.scan")
    refreshQueue.async { [weak self] in
      let snapshot = AZSReadFanSnapshot()
      let ready = AZSPrivilegedSMC.isReady()
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshInFlight = false
        guard !self.sleeping, self.operationEpoch.isCurrent(epoch) else { return }
        self.fans = snapshot.fans
        self.isAvailable = !snapshot.fans.isEmpty
        self.canControl = ready
        if !self.isPerformingAction { self.status = snapshot.status }
      }
    }
  }

  private func perform(_ message: String, successMessage: String, action: @escaping () -> Bool) {
    guard !isPerformingAction, !sleeping else { return }
    isPerformingAction = true
    status = message
    let epoch = operationEpoch.token
    refreshQueue.async { [weak self] in
      guard let self else { return }
      guard self.operationEpoch.isCurrent(epoch) else {
        Task { @MainActor in self.isPerformingAction = false }
        return
      }
      let success = action()
      let error =
        AZSPrivilegedSMC.lastErrorMessage
        ?? String(validatingCString: AZSSMCLastError()) ?? "Không thực hiện được thao tác"
      let snapshot = AZSReadFanSnapshot()
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isPerformingAction = false
        if !self.sleeping && self.operationEpoch.isCurrent(epoch) {
          self.canControl = success
          self.fans = snapshot.fans
          self.isAvailable = !snapshot.fans.isEmpty
          self.status = success ? successMessage : error
        }
      }
    }
  }

  func authorizeControl() {
    perform("Đang yêu cầu quyền điều khiển quạt…", successMessage: "Đã sẵn sàng điều khiển quạt") {
      AZSPrivilegedSMC.authorize()
    }
  }

  func setTarget(for index: Int, rpm: Double) {
    guard rpm.isFinite, let fan = fans.first(where: { $0.id == index }) else { return }
    let clamped = min(max(rpm, max(0, fan.minimumRPM)), max(fan.minimumRPM + 100, fan.maximumRPM))
    perform(
      "Đang đặt tốc độ quạt…", successMessage: "Đã đặt \(fanName(for: index)) ở \(Int(clamped)) RPM"
    ) {
      AZSSMCSetFanTarget(Int32(index), clamped) != 0
        || AZSPrivilegedSMC.setTarget(index: index, rpm: clamped)
    }
  }

  func setAuto(for index: Int) {
    perform("Đang trả quạt về tự động…", successMessage: "\(fanName(for: index)) đã về tự động") {
      AZSSMCSetFanAuto(Int32(index)) != 0 || AZSPrivilegedSMC.setAuto(index: index)
    }
  }

  func setAllAuto() {
    let ids = fans.map(\.id)
    guard !ids.isEmpty else { return }
    perform("Đang trả tất cả quạt về tự động…", successMessage: "Tất cả quạt đã về tự động") {
      var success = true
      for id in ids {
        let applied = AZSSMCSetFanAuto(Int32(id)) != 0 || AZSPrivilegedSMC.setAuto(index: id)
        success = success && applied
      }
      return success
    }
  }
  func fanName(for index: Int) -> String {
    if fans.count == 1 { return "Quạt hệ thống" }
    if fans.count == 2 { return index == 0 ? "Quạt bên trái" : "Quạt bên phải" }
    return "Quạt hệ thống \(index + 1)"
  }
}

struct AZSFanControlSection: View {
  @ObservedObject private var controller = AZSFanController.shared

  var body: some View {
    Section {
      HStack {
        Button {
          controller.refresh()
        } label: {
          Label("Đọc lại", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        Spacer()
        Button("Tự động tất cả") { controller.setAllAuto() }
          .buttonStyle(.borderless)
          .disabled(controller.fans.isEmpty)
      }

      if !controller.canControl && !controller.fans.isEmpty {
        HStack(spacing: 10) {
          Image(systemName: "lock.shield")
            .foregroundStyle(Color.accentColor)
          Text("Cấp quyền một lần để điều chỉnh tốc độ quạt.")
            .font(.callout)
          Spacer()
          Button("Bật điều khiển") { controller.authorizeControl() }
            .buttonStyle(.borderedProminent)
        }
      }

      if controller.fans.isEmpty {
        Label(controller.status, systemImage: "fan")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(controller.fans) { fan in
            AZSFanRow(
              name: controller.fanName(for: fan.id), fan: fan,
              enabled: controller.canControl,
              setTarget: { controller.setTarget(for: fan.id, rpm: $0) },
              setAuto: { controller.setAuto(for: fan.id) })
          }
        }
      }
      HStack {
        if controller.isPerformingAction { ProgressView().controlSize(.small) }
        Text(controller.status).font(.footnote).foregroundStyle(.secondary)
      }
    } header: {
      Label("Fan Control", systemImage: "fan")
    } footer: {
      Text(
        "Kéo và thả thanh RPM để áp dụng ngay. Bạn có thể trả từng quạt hoặc tất cả quạt về chế độ tự động của macOS."
      )
      .font(.footnote)
    }
    .disabled(controller.isPerformingAction)
    .onAppear { controller.start(owner: "settings") }
    .onDisappear { controller.stop(owner: "settings") }
  }
}

private struct AZSFanRow: View {
  let name: String
  let fan: AZSFanReading
  let enabled: Bool
  let setTarget: (Double) -> Void
  let setAuto: () -> Void
  @State private var target: Double

  init(
    name: String, fan: AZSFanReading, enabled: Bool,
    setTarget: @escaping (Double) -> Void, setAuto: @escaping () -> Void
  ) {
    self.name = name
    self.fan = fan
    self.enabled = enabled
    self.setTarget = setTarget
    self.setAuto = setAuto
    _target = State(initialValue: fan.targetRPM)
  }

  var body: some View {
    let lowerBound = max(0, fan.minimumRPM)
    let upperBound = max(lowerBound + 100, fan.maximumRPM)
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label(name, systemImage: "fan").fontWeight(.semibold)
        Spacer()
        Text("\(Int(fan.actualRPM.rounded())) RPM")
          .font(.title3.weight(.semibold)).monospacedDigit()
        Text(fan.manual ? "Thủ công" : "Tự động")
          .font(.caption).foregroundStyle(fan.manual ? .orange : .secondary)
        Button("Về tự động", action: setAuto)
          .buttonStyle(.borderless)
          .disabled(!enabled || !fan.manual)
      }
      Text("Giới hạn: \(Int(lowerBound))–\(Int(upperBound)) RPM")
        .font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Slider(
          value: $target,
          in: lowerBound...upperBound,
          step: 50,
          onEditingChanged: { editing in
            if !editing { setTarget(target) }
          }
        )
        .disabled(!enabled)
        Text("\(Int(target.rounded())) RPM")
          .monospacedDigit().frame(width: 82, alignment: .trailing)
      }
    }
    .onChange(of: fan.targetRPM) { _, newValue in target = newValue }
  }
}
