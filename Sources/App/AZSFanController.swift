import Foundation
import SwiftUI
import Darwin

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
        lastErrorMessage = "Helper Fan Control chưa được cài. Hãy thoát và mở lại app để thử cấp quyền một lần nữa."
        return false
    }

    private static func installPersistentHelper(executable: String) -> Bool {
        let destinationHelper = "/Library/PrivilegedHelperTools/\(helperLabel)"
        let destinationPlist = "/Library/LaunchDaemons/\(helperLabel).plist"
        let uid = getuid()
        let gid = getgid()
        let plist: [String: Any] = [
            "Label": helperLabel,
            "ProgramArguments": [destinationHelper, "--launchd-server", persistentSocketPath, "\(uid)", "\(gid)"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 2
        ]
        let temporaryPlist = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(helperLabel)-\(UUID().uuidString).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: temporaryPlist, options: .atomic)
        } catch {
            lastErrorMessage = "Không tạo được cấu hình helper: \(error.localizedDescription)"
            return false
        }

        let bootout = "/bin/launchctl bootout system/\(helperLabel) >/dev/null 2>&1 || /usr/bin/true"
        let installBinary = "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(executable)) \(shellQuote(destinationHelper))"
        let installPlist = "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(temporaryPlist.path)) \(shellQuote(destinationPlist))"
        let bootstrap = "/bin/launchctl bootstrap system \(shellQuote(destinationPlist))"
        let kickstart = "/bin/launchctl kickstart -k system/\(helperLabel)"
        let command = "\(bootout); \(installBinary) && \(installPlist) && \(bootstrap) && \(kickstart)"
        let installed = executePrivilegedShell(command)
        try? FileManager.default.removeItem(at: temporaryPlist)
        guard installed else {
            lastErrorMessage = "macOS không cài được helper Fan Control"
            return false
        }

        for _ in 0..<60 {
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
            try FileManager.default.createDirectory(at: directory,
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

    private static func runOneShot(executable: String, command: String, index: Int, rpm: Double?) -> Bool {
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
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        return error == nil
    }

    private static func send(_ message: String, to socketPath: String) -> Bool {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socketPath]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            input.fileHandleForWriting.write(Data((message + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let response = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            return process.terminationStatus == 0 && response?.hasPrefix("OK") == true
        } catch {
            return false
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AZSFanReading: Identifiable, Equatable {
    let id: Int
    var actualRPM: Double
    var minimumRPM: Double
    var maximumRPM: Double
    var targetRPM: Double
    var manual: Bool
}

@MainActor
final class AZSFanController: ObservableObject {
    static let shared = AZSFanController()

    @Published private(set) var fans: [AZSFanReading] = []
    @Published private(set) var status = "Chưa đọc tốc độ quạt"
    @Published private(set) var isAvailable = false

    private var timer: Timer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let count = AZSSMCReadFanCount()
        var newFans: [AZSFanReading] = []
        if count > 0 {
            for index in 0..<Int(count) {
                var actual = 0.0, minimum = 0.0, maximum = 0.0, target = 0.0
                var manual: Int32 = 0
                if AZSSMCReadFan(Int32(index), &actual, &minimum, &maximum, &target, &manual) != 0 {
                    newFans.append(AZSFanReading(id: index,
                                                 actualRPM: actual,
                                                 minimumRPM: minimum,
                                                 maximumRPM: maximum,
                                                 targetRPM: target,
                                                 manual: manual != 0))
                }
            }
        }

        fans = newFans
        isAvailable = !newFans.isEmpty
        if isAvailable {
            status = "Đang theo dõi AppleSMC"
        } else if let error = String(validatingCString: AZSSMCLastError()) {
            status = error.isEmpty ? "Không tìm thấy cảm biến SMC" : error
        } else {
            status = "Không tìm thấy cảm biến SMC"
        }
    }

    func setTarget(for index: Int, rpm: Double) {
        guard let fan = fans.first(where: { $0.id == index }) else { return }
        let lower = max(0, fan.minimumRPM)
        let upper = max(lower + 100, fan.maximumRPM)
        let clamped = min(max(rpm, lower), upper)
        if AZSSMCSetFanTarget(Int32(index), clamped) != 0 || AZSPrivilegedSMC.setTarget(index: index, rpm: clamped) {
            status = "Đã đặt Quạt \(index + 1) ở \(Int(clamped)) RPM"
            refresh()
        } else {
            status = AZSPrivilegedSMC.lastErrorMessage
                ?? String(validatingCString: AZSSMCLastError())
                ?? "Không đặt được RPM"
        }
    }

    func setAuto(for index: Int) {
        if AZSSMCSetFanAuto(Int32(index)) != 0 || AZSPrivilegedSMC.setAuto(index: index) {
            status = "Quạt \(index + 1) đã về Tự động"
            refresh()
        } else {
            status = AZSPrivilegedSMC.lastErrorMessage
                ?? String(validatingCString: AZSSMCLastError())
                ?? "Không trả quạt về tự động"
        }
    }

    func setAllAuto() {
        guard !fans.isEmpty else { return }
        var success = true
        for fan in fans {
            let direct = AZSSMCSetFanAuto(Int32(fan.id)) != 0
            success = (direct || AZSPrivilegedSMC.setAuto(index: fan.id)) && success
        }
        status = success
            ? "Tất cả quạt đã về Tự động"
            : (AZSPrivilegedSMC.lastErrorMessage
               ?? String(validatingCString: AZSSMCLastError())
               ?? "Không trả được quạt về tự động")
        refresh()
    }
}

struct AZSFanControlSection: View {
    @ObservedObject private var controller = AZSFanController.shared

    var body: some View {
        Section {
            HStack {
                Button { controller.refresh() } label: {
                    Label("Đọc lại", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Tự động tất cả") { controller.setAllAuto() }
                    .buttonStyle(.borderless)
                    .disabled(controller.fans.isEmpty)
            }

            if controller.fans.isEmpty {
                Label(controller.status, systemImage: "fan")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.fans) { fan in
                        AZSFanRow(fan: fan, setTarget: { controller.setTarget(for: fan.id, rpm: $0) }, setAuto: { controller.setAuto(for: fan.id) })
                    }
                }
            }
            Text(controller.status).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Label("Fan Control", systemImage: "fan")
        } footer: {
            Text("Hiển thị RPM hiện tại, cho phép đặt RPM thủ công hoặc trả quạt về chế độ Tự động của macOS.")
                .font(.footnote)
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

private struct AZSFanRow: View {
    let fan: AZSFanReading
    let setTarget: (Double) -> Void
    let setAuto: () -> Void
    @State private var target: Double

    init(fan: AZSFanReading, setTarget: @escaping (Double) -> Void, setAuto: @escaping () -> Void) {
        self.fan = fan
        self.setTarget = setTarget
        self.setAuto = setAuto
        _target = State(initialValue: fan.targetRPM)
    }

    var body: some View {
        let lowerBound = max(0, fan.minimumRPM)
        let upperBound = max(lowerBound + 100, fan.maximumRPM)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Quạt \(fan.id + 1)").fontWeight(.semibold)
                Spacer()
                Text("\(Int(fan.actualRPM.rounded())) RPM")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(fan.manual ? "Thủ công" : "Tự động")
                    .font(.caption).foregroundStyle(fan.manual ? .orange : .secondary)
            }
            Text("Giới hạn: \(Int(lowerBound))–\(Int(upperBound)) RPM")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(value: $target,
                       in: lowerBound...upperBound,
                       step: 50)
                Text("\(Int(target.rounded())) RPM")
                    .monospacedDigit().frame(width: 82, alignment: .trailing)
                Button("Áp dụng") { setTarget(target) }
                    .buttonStyle(.borderedProminent)
                Button("Tự động", action: setAuto).buttonStyle(.borderless)
            }
        }
        .onChange(of: fan.targetRPM) { _, newValue in target = newValue }
    }
}
