//
//  AZSUtilityController.swift
//  AZS Tools
//
//  Global mouse utilities and the native macOS volume HUD. This module is
//  independent from the Vietnamese engine event tap, so both can run together.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.hid

struct AZSMouseDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let manufacturer: String?
    let transport: String?
    let vendorID: Int?
    let productID: Int?
    let bluetoothAddress: String?
    let batteryPercent: Int?

    var displayName: String {
        guard let manufacturer,
              !manufacturer.isEmpty,
              !name.localizedCaseInsensitiveContains(manufacturer) else { return name }
        return "\(manufacturer) \(name)"
    }

    func replacingBattery(with batteryPercent: Int?) -> AZSMouseDevice {
        AZSMouseDevice(
            id: id,
            name: name,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            bluetoothAddress: bluetoothAddress,
            batteryPercent: batteryPercent
        )
    }
}

/// Small, read-only HID report exchange used by vendor battery providers.
/// Devices are opened only for the duration of one query and are never seized
/// from macOS or from the normal mouse event stream.
private final class AZSHIDReportExchange {
    private let device: IOHIDDevice
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private var received: (reportID: UInt32, bytes: [UInt8])?

    init(device: IOHIDDevice) {
        self.device = device
        reportBuffer = .allocate(capacity: 128)
        reportBuffer.initialize(repeating: 0, count: 128)
    }

    deinit {
        reportBuffer.deinitialize(count: 128)
        reportBuffer.deallocate()
    }

    func sendOutputAndWait(reportID: UInt32,
                           payload: [UInt8],
                           matches: ([UInt8]) -> Bool,
                           timeout: TimeInterval = 1.25) -> [UInt8]? {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let runLoop = CFRunLoopGetCurrent()!
        let runLoopMode = CFRunLoopMode.defaultMode!
        let hidRunLoopMode = runLoopMode.rawValue
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, hidRunLoopMode)
        defer { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, hidRunLoopMode) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 128,
                                               { context, result, _, reportType, reportID, report, length in
                                                   guard result == kIOReturnSuccess,
                                                         reportType == kIOHIDReportTypeInput,
                                                         let context else { return }
                                                   let exchange = Unmanaged<AZSHIDReportExchange>
                                                       .fromOpaque(context).takeUnretainedValue()
                                                   var bytes = Array(UnsafeBufferPointer(start: report,
                                                                                         count: Int(length)))
                                                   // IOHID normally passes the report ID separately, but a
                                                   // few Bluetooth HID stacks include it in the buffer too.
                                                   // Normalize both forms before HID++ response matching.
                                                   if reportID != 0,
                                                      bytes.first == UInt8(truncatingIfNeeded: reportID) {
                                                       bytes.removeFirst()
                                                   }
                                                   exchange.received = (reportID,
                                                                        bytes)
                                               }, context)
        defer { IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 128, nil, nil) }

        // IOHIDDeviceSetReport expects the report ID in byte 0 when the
        // device has more than one report (see IOHIDDevice.h).  The HID++
        // payload builders intentionally return only the 19-byte body; the
        // Bluetooth descriptor advertises a 20-byte report including 0x11.
        // Omitting this byte makes macOS accept the call but the M650 never
        // sends a response.
        var wirePayload = payload
        if reportID != 0 {
            wirePayload.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        let status = wirePayload.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, CFIndex(wirePayload.count))
        }
        guard status == kIOReturnSuccess else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = received, matches(response.bytes) {
                return response.bytes
            }
            _ = CFRunLoopRunInMode(runLoopMode, 0.02, true)
        }
        return nil
    }

    func setAndGetFeature(reportID: UInt32, payload: [UInt8], responseLength: Int = 90) -> [UInt8]? {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let status = payload.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, CFIndex(payload.count))
        }
        guard status == kIOReturnSuccess else { return nil }
        // Several wireless Razer devices acknowledge SetReport before their
        // feature response is ready. A bounded 180 ms wait is still fast in
        // the background refresh, but avoids reading an all-zero stale frame.
        usleep(180_000)

        var response = [UInt8](repeating: 0, count: responseLength)
        var length = response.count
        let getStatus = response.withUnsafeMutableBytes { rawBuffer -> IOReturn in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, &length)
        }
        guard getStatus == kIOReturnSuccess else { return nil }
        response.removeSubrange(length..<response.count)
        return response
    }
}

private enum AZSLogitechHIDPP {
    private static let vendorID = 0x046D
    private static let longReportID: UInt32 = 0x11
    private static let deviceNumber: UInt8 = 0xFF
    // HID++ software IDs are four bits. 0x0B is reserved for this app and is
    // deliberately different from Logitech Options+/Solaar IDs.
    private static let softwareID: UInt8 = 0x0B

    static func readBattery(from device: IOHIDDevice) -> Int? {
        guard (intProperty(device, key: kIOHIDVendorIDKey as String) ?? 0) == vendorID,
              (intProperty(device, key: kIOHIDMaxInputReportSizeKey as String) ?? 0) >= 20,
              (intProperty(device, key: kIOHIDMaxOutputReportSizeKey as String) ?? 0) >= 20 else {
            return nil
        }
        let exchange = AZSHIDReportExchange(device: device)
        let rootRequestID: UInt8 = softwareID
        let rootPayload = makeLongPayload(requestHigh: 0x00,
                                          requestLow: rootRequestID,
                                          parameters: [0x10, 0x04])
        var rootResponse: [UInt8]?
        for attempt in 0..<2 where rootResponse == nil {
            rootResponse = exchange.sendOutputAndWait(
                reportID: longReportID,
                payload: rootPayload,
                matches: { response in
                    response.count >= 4 && response[0] == deviceNumber &&
                    response[1] == 0x00 && response[2] == rootRequestID
                }
            )
            if rootResponse == nil, attempt == 0 { usleep(200_000) }
        }
        guard let rootResponse, rootResponse.count >= 6 else { return nil }

        let featureIndex = rootResponse[3]
        guard featureIndex != 0 else { return nil }
        let batteryFunctionID: UInt8 = 0x10 | softwareID
        let batteryPayload = makeLongPayload(requestHigh: featureIndex,
                                             requestLow: batteryFunctionID,
                                             parameters: [])
        var batteryResponse: [UInt8]?
        for attempt in 0..<2 where batteryResponse == nil {
            batteryResponse = exchange.sendOutputAndWait(
                reportID: longReportID,
                payload: batteryPayload,
                matches: { response in
                    response.count >= 4 && response[0] == deviceNumber &&
                    response[1] == featureIndex && response[2] == batteryFunctionID
                }
            )
            if batteryResponse == nil, attempt == 0 { usleep(200_000) }
        }
        guard let batteryResponse, batteryResponse.count >= 4 else { return nil }

        // Unified Battery getBatteryInfo returns percentage, level, status.
        return max(0, min(100, Int(batteryResponse[3])))
    }

    private static func makeLongPayload(requestHigh: UInt8,
                                        requestLow: UInt8,
                                        parameters: [UInt8]) -> [UInt8] {
        var payload = [deviceNumber, requestHigh, requestLow]
        payload.append(contentsOf: parameters)
        payload.append(contentsOf: repeatElement(UInt8(0), count: max(0, 19 - payload.count)))
        return Array(payload.prefix(19))
    }

    private static func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

/// macOS' Bluetooth daemon reads the standard BLE Battery Service before it
/// hands a Logitech mouse to IOHID.  Recent Logitech BLE devices (including
/// Signature M650 / M650 L) do not publish that value as an IORegistry
/// property, but bluetoothd records a compact, correlated VID/PID + battery
/// pair in the unified log whenever the mouse connects or wakes.
///
/// This is deliberately only a fallback after IORegistry and HID++ have both
/// failed. It is Logitech-only, bounded to a short look-back, timed out, and
/// throttled so the 30-second mouse refresh timer cannot repeatedly scan the
/// system log. No shell is involved.
private enum AZSBluetoothBatteryLog {
    private struct DeviceKey: Hashable {
        let vendorID: Int
        let productID: Int
    }

    private static let logitechVendorID = 0x046D
    private static let cacheLifetime: TimeInterval = 5 * 60
    private static let processTimeout: TimeInterval = 8
    private static let lock = NSLock()
    private static var cachedLevels: [DeviceKey: Int] = [:]
    private static var lastScan = Date.distantPast
    private static var scanInProgress = false

    static func readBattery(vendorID: Int, productID: Int) -> Int? {
        guard vendorID == logitechVendorID, productID != 0 else { return nil }
        let key = DeviceKey(vendorID: vendorID, productID: productID)

        lock.lock()
        let cached = cachedLevels[key]
        let cacheIsFresh = Date().timeIntervalSince(lastScan) < cacheLifetime
        if cacheIsFresh || scanInProgress {
            lock.unlock()
            return cached
        }
        scanInProgress = true
        lock.unlock()

        let levels = scanRecentBluetoothLog()

        lock.lock()
        if !levels.isEmpty {
            // Preserve previously known devices if the current short window
            // happens to contain only another Logitech peripheral.
            cachedLevels.merge(levels) { _, newest in newest }
        }
        lastScan = Date()
        scanInProgress = false
        let result = cachedLevels[key]
        lock.unlock()
        return result
    }

    private static func scanRecentBluetoothLog() -> [DeviceKey: Int] {
        let predicate = "subsystem == \"com.apple.bluetooth\" AND category == \"Server.GATT\" AND (eventMessage CONTAINS \"statedump: 0x001A Characteristic Value\" OR eventMessage CONTAINS \"statedump: 0x001D Characteristic Value\")"
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--style", "compact", "--info",
            "--predicate", predicate,
            "--last", "6h"
        ]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return [:]
        }

        // Drain concurrently so a busy Bluetooth log cannot fill the pipe and
        // prevent `log show` from exiting. The predicate above keeps output
        // small, while the timeout remains a hard upper bound for this fallback.
        let readGroup = DispatchGroup()
        var outputData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        guard exited.wait(timeout: .now() + processTimeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            outputPipe.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 1)
            return [:]
        }
        guard readGroup.wait(timeout: .now() + 1) == .success,
              process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8) else { return [:] }
        return parse(output)
    }

    /// bluetoothd emits two related records. For an M650 they look like:
    ///   0x001A [... 6D 04 2A B0 ...]  (VID 046D, PID B02A, little-endian)
    ///   0x001D [23]                   (battery 0x23 = 35%)
    /// Match by bluetoothd PID/thread token rather than merely pairing adjacent
    /// lines, because several GATT callbacks can interleave in the unified log.
    private static func parse(_ output: String) -> [DeviceKey: Int] {
        var pendingByThread: [String: DeviceKey] = [:]
        var mostRecentKey: DeviceKey?
        var result: [DeviceKey: Int] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let bytes = bracketBytes(in: line), !bytes.isEmpty else { continue }
            let thread = bluetoothThreadToken(in: line)

            if line.contains("0x001A Characteristic Value"), bytes.count >= 5 {
                let vendorID = Int(bytes[1]) | (Int(bytes[2]) << 8)
                let productID = Int(bytes[3]) | (Int(bytes[4]) << 8)
                guard vendorID == logitechVendorID, productID != 0 else { continue }
                let key = DeviceKey(vendorID: vendorID, productID: productID)
                if let thread { pendingByThread[thread] = key }
                mostRecentKey = key
            } else if line.contains("0x001D Characteristic Value"), bytes.count == 1 {
                let level = Int(bytes[0])
                guard (0...100).contains(level),
                      let key = thread.flatMap({ pendingByThread[$0] }) ?? mostRecentKey else { continue }
                result[key] = level
            }
        }
        return result
    }

    private static func bracketBytes(in line: String) -> [UInt8]? {
        // Use the last bracket pair because the compact log prefix itself also
        // contains `bluetoothd[pid:thread]`.
        guard let open = line.lastIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"),
              open < close else { return nil }
        return line[line.index(after: open)..<close]
            .split(whereSeparator: \.isWhitespace)
            .compactMap { UInt8($0, radix: 16) }
    }

    private static func bluetoothThreadToken(in line: String) -> String? {
        guard let marker = line.range(of: "bluetoothd["),
              let close = line[marker.upperBound...].firstIndex(of: "]") else { return nil }
        return String(line[marker.upperBound..<close])
    }
}

private enum AZSRazerHID {
    private static let vendorID = 0x1532
    // Product IDs whose battery command framing is documented by the
    // open-source Razer macOS driver. Unknown Razer devices are left alone.
    private static let supportedProductIDs: Set<Int> = [
        0x0059, 0x005A, 0x0060, 0x0062, 0x006C, 0x006F, 0x0070, 0x0072, 0x0073,
        0x007C, 0x007D, 0x0086, 0x0088, 0x0094, 0x0095, 0x00AA, 0x00AB, 0x00CC, 0x00CD
    ]
    private static let transaction3F: Set<Int> = [
        0x0059, 0x005A, 0x0072, 0x0073, 0x007C, 0x007D
    ]

    static func readBattery(from device: IOHIDDevice, productID: Int) -> Int? {
        guard (intProperty(device, key: kIOHIDVendorIDKey as String) ?? 0) == vendorID,
              supportedProductIDs.contains(productID),
              (intProperty(device, key: kIOHIDMaxFeatureReportSizeKey as String) ?? 0) >= 90 else {
            return nil
        }

        var request = [UInt8](repeating: 0, count: 90)
        request[1] = transaction3F.contains(productID) ? 0x3F : 0x1F
        request[5] = 0x02       // payload size
        request[6] = 0x07       // battery command class
        request[7] = 0x80       // get battery level
        request[88] = checksum(request)

        let exchange = AZSHIDReportExchange(device: device)
        var response: [UInt8]?
        for attempt in 0..<2 {
            let candidate = exchange.setAndGetFeature(reportID: 0,
                                                      payload: request,
                                                      responseLength: 90)
            if let candidate,
               candidate.count >= 10,
               candidate[0] == 0x02, // command successful
               candidate[6] == 0x07,
               candidate[7] == 0x80 {
                response = candidate
                break
            }
            if attempt == 0 { usleep(150_000) }
        }
        guard let response else { return nil }

        // Razer encodes the level as 0...255 in arguments[1].
        let raw = Int(response[9])
        return max(0, min(100, Int((Double(raw) * 100.0 / 255.0).rounded())))
    }

    private static func checksum(_ report: [UInt8]) -> UInt8 {
        report[2..<88].reduce(UInt8(0), ^)
    }

    private static func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

enum AZSMouseAction: String, CaseIterable, Identifiable {
    case none, back, forward
    case copy, paste, cut, moveCutFilesHere, undo, redo, selectAll
    case missionControl, appWindows, desktop, spotlight, lockScreen, screenshot
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    case openApplication, deleteSelectedFile, pastePlainText, copySelectedPath
    case showClipboardHistory, toggleVietnamese

    static let customShortcutActions: [AZSMouseAction] = [
        .cut, .moveCutFilesHere, .deleteSelectedFile, .showClipboardHistory, .toggleVietnamese,
        .brightnessUp, .brightnessDown
    ]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Không gán"
        case .back: return "Quay lại"
        case .forward: return "Đi tới"
        case .copy: return "Sao chép (⌘C)"
        case .paste: return "Dán (⌘V)"
        case .cut: return "Cắt file Finder (Bước 1)"
        case .moveCutFilesHere: return "Dán file đã cắt / Di chuyển tới đây (Bước 2)"
        case .undo: return "Hoàn tác (⌘Z)"
        case .redo: return "Làm lại (⇧⌘Z)"
        case .selectAll: return "Chọn tất cả (⌘A)"
        case .volumeUp: return "Tăng âm lượng"
        case .volumeDown: return "Giảm âm lượng"
        case .mute: return "Tắt/bật âm thanh"
        case .brightnessUp: return "Tăng độ sáng màn hình"
        case .brightnessDown: return "Giảm độ sáng màn hình"
        case .missionControl: return "Mission Control"
        case .appWindows: return "Cửa sổ ứng dụng"
        case .desktop: return "Hiện Desktop"
        case .spotlight: return "Mở Spotlight"
        case .lockScreen: return "Khóa màn hình"
        case .screenshot: return "Chụp vùng màn hình"
        case .openApplication: return "Mở ứng dụng…"
        case .deleteSelectedFile: return "Xóa file đang chọn vào Thùng rác"
        case .pastePlainText: return "Dán dạng văn bản thuần"
        case .copySelectedPath: return "Copy đường dẫn file đang chọn"
        case .showClipboardHistory: return "Mở lịch sử Clipboard AZS"
        case .toggleVietnamese: return "Bật/tắt bộ gõ Tiếng Việt"
        }
    }
}

final class AZSUtilityController: ObservableObject {
    static let shared = AZSUtilityController()
    // Keep generated utility shortcuts out of AZS's own keyboard pipeline.
    // The matching marker is checked by MKEngineHook before Vietnamese input
    // processing or utility hot-key routing is attempted.
    static let syntheticUtilityEventMarker: Int64 = 0x415A535554494C59

    @Published var reverseScrolling: Bool { didSet { saveAndRestart() } }
    @Published var smoothScrolling: Bool { didSet { saveAndRestart() } }
    @Published var smoothScrollStep: Double { didSet { saveAndRestart() } }
    @Published var smoothScrollSpeed: Double { didSet { saveAndRestart() } }
    @Published var smoothScrollDuration: Double { didSet { saveAndRestart() } }
    @Published var smoothScrollDeadZone: Double { didSet { saveAndRestart() } }
    @Published var smoothScrollSimulatesTrackpad: Bool { didSet { saveAndRestart() } }
    @Published var scrollToZoomEnabled: Bool { didSet { saveAndRestart() } }
    @Published var scrollToZoomModifier: AZSScrollZoomModifier { didSet { saveAndRestart() } }
    @Published var scrollToZoomSensitivity: Double { didSet { saveAndRestart() } }
    @Published var scrollToZoomReversed: Bool { didSet { saveAndRestart() } }
    @Published var scrollToZoomUsesCommandKeys: Bool { didSet { saveAndRestart() } }
    /// CGEvent button numbers start at 2 for the physical middle button. A
    /// dictionary lets users assign any of the common Button 3–10 slots.
    @Published var buttonActions: [Int: AZSMouseAction] { didSet { saveAndRestart() } }
    @Published var buttonApplications: [Int: String] { didSet { saveAndRestart() } }
    @Published var actionHotKeys: [String: Int32] { didSet { saveActionHotKeys() } }
    @Published var actionApplicationPath: String? { didSet { saveActionApplication() } }
    @Published var applicationShortcutHotKeys: [Int: Int32] { didSet { saveApplicationShortcuts() } }
    @Published var applicationShortcutPaths: [Int: String] { didSet { saveApplicationShortcuts() } }
    @Published private(set) var lastDetectedButton: Int?
    @Published private(set) var mouseDevices: [AZSMouseDevice] = []
    @Published private(set) var inputMonitoringGranted = false

    private let defaults = UserDefaults.standard
    private var lock = NSLock()
    private var reverseSnapshot = false
    private var smoothSnapshot = false
    private var actionsSnapshot: [Int: AZSMouseAction] = [:]
    private var applicationsSnapshot: [Int: String] = [:]
    private var lastExternalVolume: Float = 0.5
    private var actionHotKeyMonitors: [String: GlobalHotKey] = [:]

    private init() {
        reverseScrolling = defaults.bool(forKey: "AZSReverseScrolling")
        smoothScrolling = defaults.object(forKey: "AZSSmoothScrolling") == nil
            ? true
            : defaults.bool(forKey: "AZSSmoothScrolling")
        // v3 resets tuning once because the cross-app session poster now uses
        // the same effective PointDelta payload as standalone Mos. Values from
        // the older AZS implementation (for example speed 5 / short duration)
        // are not equivalent and make the corrected engine much too fast.
        let needsMosTuningMigration = defaults.integer(forKey: "AZSMosTuningVersion") < 3
        smoothScrollStep = needsMosTuningMigration
            ? 33.6
            : (defaults.object(forKey: "AZSSmoothScrollStep") == nil ? 33.6 : defaults.double(forKey: "AZSSmoothScrollStep"))
        smoothScrollSpeed = needsMosTuningMigration
            ? 2.70
            : (defaults.object(forKey: "AZSSmoothScrollSpeed") == nil ? 2.70 : defaults.double(forKey: "AZSSmoothScrollSpeed"))
        smoothScrollDuration = needsMosTuningMigration
            ? 4.35
            : (defaults.object(forKey: "AZSSmoothScrollDuration") == nil ? 4.35 : defaults.double(forKey: "AZSSmoothScrollDuration"))
        smoothScrollDeadZone = needsMosTuningMigration
            ? 1.0
            : (defaults.object(forKey: "AZSSmoothScrollDeadZone") == nil ? 1.0 : defaults.double(forKey: "AZSSmoothScrollDeadZone"))
        smoothScrollSimulatesTrackpad = needsMosTuningMigration
            ? false
            : (defaults.object(forKey: "AZSSmoothScrollSimulatesTrackpad") == nil || defaults.bool(forKey: "AZSSmoothScrollSimulatesTrackpad"))
        scrollToZoomEnabled = defaults.bool(forKey: "AZSScrollToZoomEnabled")
        scrollToZoomModifier = AZSScrollZoomModifier(rawValue: defaults.string(forKey: "AZSScrollToZoomModifier") ?? "option") ?? .option
        scrollToZoomSensitivity = defaults.object(forKey: "AZSScrollToZoomSensitivity") == nil
            ? 1.0
            : defaults.double(forKey: "AZSScrollToZoomSensitivity")
        scrollToZoomReversed = defaults.bool(forKey: "AZSScrollToZoomReversed")
        scrollToZoomUsesCommandKeys = defaults.bool(forKey: "AZSScrollToZoomUsesCommandKeys")
        var actions: [Int: AZSMouseAction] = [2: .none, 3: .back, 4: .forward]
        if let saved = defaults.dictionary(forKey: "AZSMouseButtonActions") as? [String: String] {
            for (key, rawValue) in saved {
                if let button = Int(key), let action = AZSMouseAction(rawValue: rawValue) {
                    actions[button] = action
                }
            }
        } else {
            // Migrate the original three fixed slots without losing a user's
            // existing configuration.
            actions[2] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSMiddleAction") ?? "none") ?? AZSMouseAction.none
            actions[3] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSBackAction") ?? "back") ?? .back
            actions[4] = AZSMouseAction(rawValue: defaults.string(forKey: "AZSForwardAction") ?? "forward") ?? .forward
        }
        buttonActions = actions
        var applications: [Int: String] = [:]
        if let saved = defaults.dictionary(forKey: "AZSMouseButtonApplications") as? [String: String] {
            for (key, path) in saved where Int(key) != nil { applications[Int(key)!] = path }
        }
        buttonApplications = applications
        let savedBrightnessUp = Int32(truncatingIfNeeded: defaults.integer(forKey: "AZSBrightnessUpHotKey"))
        let savedBrightnessDown = Int32(truncatingIfNeeded: defaults.integer(forKey: "AZSBrightnessDownHotKey"))
        var savedActions: [String: Int32] = [:]
        if let saved = defaults.dictionary(forKey: "AZSActionHotKeys") {
            for (key, value) in saved {
                if let number = value as? NSNumber {
                    savedActions[key] = Int32(truncatingIfNeeded: number.int64Value)
                }
            }
        }
        // Keep only AZS-specific keyboard actions. Enum cases for native macOS
        // commands remain available to mouse-button mappings and old settings,
        // but their legacy global hotkeys must no longer be registered.
        let allowedActionKeys = Set(AZSMouseAction.customShortcutActions.map(\.rawValue))
        savedActions = savedActions.filter { allowedActionKeys.contains($0.key) }
        // Migrate the two original brightness-only shortcuts into the unified
        // action shortcut store once, preserving existing user choices.
        if savedActions[AZSMouseAction.brightnessUp.rawValue] == nil, savedBrightnessUp != 0 {
            savedActions[AZSMouseAction.brightnessUp.rawValue] = savedBrightnessUp
        }
        if savedActions[AZSMouseAction.brightnessDown.rawValue] == nil, savedBrightnessDown != 0 {
            savedActions[AZSMouseAction.brightnessDown.rawValue] = savedBrightnessDown
        }
        UserDefaults.standard.set(savedActions.mapValues(Int.init), forKey: "AZSActionHotKeys")
        actionHotKeys = savedActions
        let legacyApplicationPath = defaults.string(forKey: "AZSActionApplicationPath")
        actionApplicationPath = legacyApplicationPath
        var appHotKeys: [Int: Int32] = [:]
        var appPaths: [Int: String] = [:]
        if let saved = defaults.dictionary(forKey: "AZSApplicationShortcutHotKeys") as? [String: NSNumber] {
            for (key, value) in saved { if let slot = Int(key) { appHotKeys[slot] = Int32(truncatingIfNeeded: value.int64Value) } }
        }
        if let saved = defaults.dictionary(forKey: "AZSApplicationShortcutPaths") as? [String: String] {
            for (key, value) in saved { if let slot = Int(key) { appPaths[slot] = value } }
        }
        if appHotKeys[0] == nil, let legacy = savedActions[AZSMouseAction.openApplication.rawValue] {
            appHotKeys[0] = legacy
        }
        if appPaths[0] == nil, let legacy = legacyApplicationPath { appPaths[0] = legacy }
        applicationShortcutHotKeys = appHotKeys
        applicationShortcutPaths = appPaths
        lastDetectedButton = nil
        inputMonitoringGranted = CGPreflightListenEventAccess()
        defaults.set(3, forKey: "AZSMosTuningVersion")
        refreshSnapshot()
        registerActionHotKeys()
    }

    func start() {
        // Utility events are routed through MKBridge's Accessibility tap.
        // Keeping this method makes startup/wake lifecycle calls idempotent.
        refreshSnapshot()
        AZSSmoothScrollEngine.shared.configure(enabled: smoothScrolling,
                                                step: smoothScrollStep,
                                                speed: smoothScrollSpeed,
                                                duration: smoothScrollDuration,
                                                deadZone: smoothScrollDeadZone,
                                                simulatesTrackpad: smoothScrollSimulatesTrackpad)
        configureScrollToZoom()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        // Device inventory is refreshed once at startup and explicitly from
        // the UI. A recurring scan invokes system_profiler/ioreg (and may open
        // a Bluetooth HID device), which can briefly perturb a wireless mouse
        // even though the work itself is dispatched off the main thread.
        refreshMouseDevices()
    }

    func refreshMouseDevices() {
        // HID report exchanges can wait for a Bluetooth/receiver response and
        // may require a TCC permission check. Keep all of that off the main
        // thread so opening the menu never stutters.
        let inputAccess = CGPreflightListenEventAccess()
        inputMonitoringGranted = inputAccess
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = Self.readMouseDevices()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inputMonitoringGranted = inputAccess || CGPreflightListenEventAccess()
                // BatteryBoi keeps the most recent level when a later OS scan
                // temporarily omits it. Do the same only while the exact mouse
                // remains present, so a sleeping BLE device does not make the
                // menu flicker between a percentage and “no information”.
                self.mouseDevices = Self.preservingLastKnownBattery(
                    in: devices,
                    previous: self.mouseDevices
                )
            }
        }
    }

    /// HID++/Razer battery queries require the macOS Input Monitoring grant.
    /// The regular CGEventTap permission used by the Vietnamese engine is a
    /// separate TCC grant, so expose an explicit action for vendor devices.
    @discardableResult
    func requestMouseInputMonitoringAccess() -> Bool {
        if CGPreflightListenEventAccess() {
            inputMonitoringGranted = true
            return true
        }
        CGRequestListenEventAccess()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        return false
    }

    private static func readMouseDevices() -> [AZSMouseDevice] {
        // BatteryBoi's strongest vendor-neutral path is System Information +
        // IORegistry. Collect it once per refresh (internally cached) and use
        // it before sending any vendor HID command that needs TCC access.
        let compatibilityRecords = AZSBatteryBoiCompatibility.collectRecords()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let mouseMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(manager, mouseMatch as CFDictionary)
        // Device metadata is readable without opening the HID input stream.
        // Requiring IOHIDManagerOpen here would hide every mouse when macOS
        // denies Input Monitoring even though product/battery data is visible.
        let hidDevices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)
            .map(Array.init) ?? []
        let logitechTransports = logitechHIDPPDevices()
        let razerControls = razerControlDevices()

        var devices = hidDevices.compactMap { device -> AZSMouseDevice? in
            let name = stringProperty(device, keys: [kIOHIDProductKey as String, "ProductName"])
            guard let name, !name.isEmpty else { return nil }
            let vendorID = intProperty(device, keys: [kIOHIDVendorIDKey as String]) ?? 0
            let productID = intProperty(device, keys: [kIOHIDProductIDKey as String]) ?? 0
            let locationID = intProperty(device, keys: [kIOHIDLocationIDKey as String]) ?? 0
            let registryID = IOHIDDeviceGetService(device)
            let stableID = "\(vendorID):\(productID):\(locationID):\(registryID)"
            let address = AZSBatteryBoiCompatibility.normalizeAddress(
                stringProperty(device, keys: ["DeviceAddress", "BluetoothAddress"])
            )
            let compatibility = bestCompatibilityRecord(
                name: name,
                vendorID: vendorID == 0 ? nil : vendorID,
                productID: productID == 0 ? nil : productID,
                address: address,
                records: compatibilityRecords
            )
            let standardBattery = batteryPercent(for: device)
            let systemBattery = compatibility?.batteryPercent
            let vendorQueryDevice: IOHIDDevice
            if vendorID == 0x046D {
                vendorQueryDevice = bestLogitechHIDPPDevice(
                    for: device,
                    candidates: logitechTransports
                ) ?? device
            } else if vendorID == 0x1532 {
                vendorQueryDevice = bestRazerControlDevice(
                    for: device,
                    candidates: razerControls
                ) ?? device
            } else {
                vendorQueryDevice = device
            }
            let vendorBattery = standardBattery == nil && systemBattery == nil
                ? vendorBatteryPercent(for: vendorQueryDevice, productID: productID)
                : nil
            return AZSMouseDevice(
                id: stableID,
                name: name,
                manufacturer: stringProperty(device, keys: [kIOHIDManufacturerKey as String])
                    ?? compatibility?.manufacturer,
                transport: stringProperty(device, keys: [kIOHIDTransportKey as String])
                    ?? compatibility?.transport,
                vendorID: vendorID == 0 ? nil : vendorID,
                productID: productID == 0 ? nil : productID,
                bluetoothAddress: address ?? compatibility?.address,
                batteryPercent: standardBattery ?? systemBattery ?? vendorBattery
            )
        }

        // system_profiler can still see a connected Bluetooth mouse when its
        // generic IOHID collection is sleeping or hidden by a vendor driver.
        // Add only records positively classified as a mouse and deduplicate by
        // address first, then VID/PID/name.
        for record in compatibilityRecords where record.isMouse && record.isConnected {
            if devices.contains(where: { compatibilityScore(device: $0, record: record) > 0 }) {
                continue
            }
            let name = record.name ?? "Bluetooth Mouse"
            let identity = record.address
                ?? "\(record.vendorID ?? 0):\(record.productID ?? 0):\(normalizedDeviceName(name))"
            devices.append(AZSMouseDevice(
                id: "system:\(identity)",
                name: name,
                manufacturer: record.manufacturer,
                transport: record.transport ?? (record.address == nil ? nil : "Bluetooth"),
                vendorID: record.vendorID,
                productID: record.productID,
                bluetoothAddress: record.address,
                batteryPercent: record.batteryPercent
            ))
        }

        return devices
            .reduce(into: [AZSMouseDevice]()) { unique, device in
                if let index = unique.firstIndex(where: { sameMouse($0, device) }) {
                    let old = unique[index]
                    // Prefer the record with a real battery value, otherwise
                    // keep the first IOHID-backed record and its stable ID.
                    if old.batteryPercent == nil, device.batteryPercent != nil {
                        unique[index] = AZSMouseDevice(
                            id: old.id,
                            name: old.name,
                            manufacturer: old.manufacturer ?? device.manufacturer,
                            transport: old.transport ?? device.transport,
                            vendorID: old.vendorID ?? device.vendorID,
                            productID: old.productID ?? device.productID,
                            bluetoothAddress: old.bluetoothAddress ?? device.bluetoothAddress,
                            batteryPercent: device.batteryPercent
                        )
                    }
                } else {
                    unique.append(device)
                }
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Logitech's HID++ transport can be a vendor collection separate from
    /// the generic mouse collection. Direct BLE mice such as M650 use
    /// 0xFF43/0x0202; USB/Bolt/classic transports normally use 0xFF00/0x0002.
    private static func logitechHIDPPDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x046D,
                kIOHIDDeviceUsagePageKey as String: 0xFF43,
                kIOHIDDeviceUsageKey as String: 0x0202
            ],
            [
                kIOHIDVendorIDKey as String: 0x046D,
                kIOHIDDeviceUsagePageKey as String: 0xFF00,
                kIOHIDDeviceUsageKey as String: 0x0002
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)
            .map(Array.init) ?? []
    }

    private static func bestLogitechHIDPPDevice(
        for mouse: IOHIDDevice,
        candidates: [IOHIDDevice]
    ) -> IOHIDDevice? {
        let vendorID = intProperty(mouse, keys: [kIOHIDVendorIDKey as String]) ?? 0
        guard vendorID == 0x046D else { return nil }
        let productID = intProperty(mouse, keys: [kIOHIDProductIDKey as String]) ?? 0
        let locationID = intProperty(mouse, keys: [kIOHIDLocationIDKey as String]) ?? 0
        let address = AZSBatteryBoiCompatibility.normalizeAddress(
            stringProperty(mouse, keys: ["DeviceAddress", "BluetoothAddress"])
        )

        let eligible = candidates.filter { candidate in
            (intProperty(candidate, keys: [kIOHIDProductIDKey as String]) ?? 0) == productID &&
            (intProperty(candidate, keys: [kIOHIDMaxInputReportSizeKey as String]) ?? 0) >= 20 &&
            (intProperty(candidate, keys: [kIOHIDMaxOutputReportSizeKey as String]) ?? 0) >= 20
        }
        if let address,
           let exact = eligible.first(where: { candidate in
               AZSBatteryBoiCompatibility.normalizeAddress(
                   stringProperty(candidate, keys: ["DeviceAddress", "BluetoothAddress"])
               ) == address
           }) {
            return exact
        }
        if locationID != 0,
           let exact = eligible.first(where: {
               intProperty($0, keys: [kIOHIDLocationIDKey as String]) == locationID
           }) {
            return exact
        }
        // A unique exact PID is safe for direct Bluetooth. Do not choose an
        // arbitrary candidate when two identical mice/receiver slots exist.
        return eligible.count == 1 ? eligible[0] : nil
    }

    private static func razerControlDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey as String: 0x1532]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)
            .map(Array.init) ?? []
    }

    private static func bestRazerControlDevice(
        for mouse: IOHIDDevice,
        candidates: [IOHIDDevice]
    ) -> IOHIDDevice? {
        let productID = intProperty(mouse, keys: [kIOHIDProductIDKey as String]) ?? 0
        let locationID = intProperty(mouse, keys: [kIOHIDLocationIDKey as String]) ?? 0
        let address = AZSBatteryBoiCompatibility.normalizeAddress(
            stringProperty(mouse, keys: ["DeviceAddress", "BluetoothAddress"])
        )
        let eligible = candidates.filter { candidate in
            (intProperty(candidate, keys: [kIOHIDProductIDKey as String]) ?? 0) == productID &&
            (intProperty(candidate, keys: [kIOHIDMaxFeatureReportSizeKey as String]) ?? 0) >= 90
        }
        if let address,
           let exact = eligible.first(where: { candidate in
               AZSBatteryBoiCompatibility.normalizeAddress(
                   stringProperty(candidate, keys: ["DeviceAddress", "BluetoothAddress"])
               ) == address
           }) {
            return exact
        }
        if locationID != 0,
           let exact = eligible.first(where: {
               intProperty($0, keys: [kIOHIDLocationIDKey as String]) == locationID
           }) {
            return exact
        }
        return eligible.count == 1 ? eligible[0] : nil
    }

    private static func bestCompatibilityRecord(
        name: String,
        vendorID: Int?,
        productID: Int?,
        address: String?,
        records: [AZSBatteryBoiRecord]
    ) -> AZSBatteryBoiRecord? {
        let ranked = records
            .map { record in
                (record, compatibilityScore(name: name,
                                            vendorID: vendorID,
                                            productID: productID,
                                            address: address,
                                            record: record))
            }
            .filter { $0.1 > 0 }
        guard let highest = ranked.map(\.1).max() else { return nil }
        let best = ranked.filter { $0.1 == highest }.map(\.0)

        // Two identical mice can share VID/PID/name. Never borrow one mouse's
        // battery for another unless the Bluetooth address identifies it, or
        // the non-address candidate is unambiguous.
        if let address,
           let exact = best.first(where: { $0.address == address }) {
            return exact
        }
        let identities = Set(best.map(compatibilityIdentity))
        guard identities.count == 1 else { return nil }
        return best.first
    }

    private static func compatibilityScore(device: AZSMouseDevice,
                                           record: AZSBatteryBoiRecord) -> Int {
        compatibilityScore(name: device.name,
                           vendorID: device.vendorID,
                           productID: device.productID,
                           address: device.bluetoothAddress,
                           record: record)
    }

    private static func compatibilityScore(name: String,
                                           vendorID: Int?,
                                           productID: Int?,
                                           address: String?,
                                           record: AZSBatteryBoiRecord) -> Int {
        if let address, let recordAddress = record.address,
           address == recordAddress {
            return 100
        }
        if let vendorID, let recordVendor = record.vendorID, vendorID != recordVendor {
            return 0
        }
        if let productID, let recordProduct = record.productID, productID != recordProduct {
            return 0
        }
        if let vendorID, let productID,
           vendorID == record.vendorID, productID == record.productID {
            return 80
        }

        let lhs = normalizedDeviceName(name)
        let rhs = normalizedDeviceName(record.name ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 70 }
        if min(lhs.count, rhs.count) >= 5,
           lhs.contains(rhs) || rhs.contains(lhs) {
            return 50
        }
        return 0
    }

    private static func sameMouse(_ lhs: AZSMouseDevice, _ rhs: AZSMouseDevice) -> Bool {
        if lhs.id == rhs.id { return true }
        if let left = lhs.bluetoothAddress, let right = rhs.bluetoothAddress {
            return left == right
        }
        // Never collapse two real IOHID devices merely because they are the
        // same model. Product matching is only for merging a synthetic System
        // Information record into its IOHID-backed device.
        guard lhs.id.hasPrefix("system:") || rhs.id.hasPrefix("system:") else {
            return false
        }
        guard lhs.vendorID == rhs.vendorID,
              lhs.productID == rhs.productID,
              normalizedDeviceName(lhs.name) == normalizedDeviceName(rhs.name) else {
            return false
        }
        return lhs.vendorID != nil || lhs.productID != nil
    }

    private static func compatibilityIdentity(_ record: AZSBatteryBoiRecord) -> String {
        record.address
            ?? "\(record.vendorID ?? -1):\(record.productID ?? -1):\(normalizedDeviceName(record.name ?? ""))"
    }

    private static func preservingLastKnownBattery(
        in devices: [AZSMouseDevice],
        previous: [AZSMouseDevice]
    ) -> [AZSMouseDevice] {
        devices.map { device in
            guard device.batteryPercent == nil,
                  let old = previous.first(where: { sameMouse($0, device) }),
                  let battery = old.batteryPercent else { return device }
            return device.replacingBattery(with: battery)
        }
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func property(_ device: IOHIDDevice, keys: [String]) -> Any? {
        for key in keys {
            if let value = IOHIDDeviceGetProperty(device, key as CFString) { return value }
        }
        return nil
    }

    private static func stringProperty(_ device: IOHIDDevice, keys: [String]) -> String? {
        property(device, keys: keys) as? String
    }

    private static func intProperty(_ device: IOHIDDevice, keys: [String]) -> Int? {
        if let number = property(device, keys: keys) as? NSNumber { return number.intValue }
        return nil
    }

    private static func batteryPercent(for device: IOHIDDevice) -> Int? {
        let keys = ["BatteryPercent", "BatteryLevel", "BatteryCapacity", "AppleDeviceBatteryLevel"]
        if let number = property(device, keys: keys) as? NSNumber {
            return normalizedBatteryPercent(number)
        }

        // Newer Apple Bluetooth HID drivers may expose BatteryPercent on a
        // related IORegistry service rather than on IOHIDDevice itself.
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        for key in keys {
            let searchOptions: [IOOptionBits] = [
                IOOptionBits(kIORegistryIterateRecursively),
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ]
            for options in searchOptions {
                if let value = IORegistryEntrySearchCFProperty(
                    service,
                    kIOServicePlane,
                    key as CFString,
                    kCFAllocatorDefault,
                    options
                ) as? NSNumber {
                    return normalizedBatteryPercent(value)
                }
            }
        }
        return nil
    }

    private static func normalizedBatteryPercent(_ number: NSNumber) -> Int {
        let value = number.doubleValue
        let type = String(cString: number.objCType)
        // Only floating-point 0...1 values are ratios. An integer value of 1
        // is a legitimate one-percent reading and must stay 1%, not 100%.
        let normalized = (type == "f" || type == "d") && value >= 0 && value <= 1
            ? value * 100
            : value
        return max(0, min(100, Int(normalized.rounded())))
    }

    private static func vendorBatteryPercent(for device: IOHIDDevice, productID: Int) -> Int? {
        let vendorID = intProperty(device, keys: [kIOHIDVendorIDKey as String]) ?? 0
        switch vendorID {
        case 0x046D:
            return AZSLogitechHIDPP.readBattery(from: device)
                ?? AZSBluetoothBatteryLog.readBattery(vendorID: vendorID, productID: productID)
        case 0x1532:
            return AZSRazerHID.readBattery(from: device, productID: productID)
        default:
            return nil
        }
    }

    private func saveAndRestart() {
        defaults.set(reverseScrolling, forKey: "AZSReverseScrolling")
        defaults.set(smoothScrolling, forKey: "AZSSmoothScrolling")
        defaults.set(smoothScrollStep, forKey: "AZSSmoothScrollStep")
        defaults.set(smoothScrollSpeed, forKey: "AZSSmoothScrollSpeed")
        defaults.set(smoothScrollDuration, forKey: "AZSSmoothScrollDuration")
        defaults.set(smoothScrollDeadZone, forKey: "AZSSmoothScrollDeadZone")
        defaults.set(smoothScrollSimulatesTrackpad, forKey: "AZSSmoothScrollSimulatesTrackpad")
        defaults.set(scrollToZoomEnabled, forKey: "AZSScrollToZoomEnabled")
        defaults.set(scrollToZoomModifier.rawValue, forKey: "AZSScrollToZoomModifier")
        defaults.set(scrollToZoomSensitivity, forKey: "AZSScrollToZoomSensitivity")
        defaults.set(scrollToZoomReversed, forKey: "AZSScrollToZoomReversed")
        defaults.set(scrollToZoomUsesCommandKeys, forKey: "AZSScrollToZoomUsesCommandKeys")
        let saved = buttonActions.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value.rawValue
        }
        defaults.set(saved, forKey: "AZSMouseButtonActions")
        let savedApplications = buttonApplications.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value
        }
        defaults.set(savedApplications, forKey: "AZSMouseButtonApplications")
        refreshSnapshot()
        AZSSmoothScrollEngine.shared.configure(enabled: smoothScrolling,
                                                step: smoothScrollStep,
                                                speed: smoothScrollSpeed,
                                                duration: smoothScrollDuration,
                                                deadZone: smoothScrollDeadZone,
                                                simulatesTrackpad: smoothScrollSimulatesTrackpad)
        configureScrollToZoom()
    }

    func applyMosSmoothScrollDefaults() {
        smoothScrollStep = 33.6
        smoothScrollSpeed = 2.70
        smoothScrollDuration = 4.35
        smoothScrollDeadZone = 1.0
        smoothScrollSimulatesTrackpad = false
    }

    private func configureScrollToZoom() {
        AZSScrollToZoomEngine.shared.configure(enabled: scrollToZoomEnabled,
                                                modifier: scrollToZoomModifier,
                                                sensitivity: scrollToZoomSensitivity,
                                                reversed: scrollToZoomReversed,
                                                usesCommandKeys: scrollToZoomUsesCommandKeys)
    }

    /// Rebuild the reference event-tap pipeline after Accessibility becomes
    /// available or AZS recreates its shared tap after wake/failure.
    func restartScrollToZoom() {
        AZSScrollToZoomEngine.shared.stop()
        configureScrollToZoom()
    }

    /// Rebuild MOS after the shared Accessibility event tap becomes usable.
    /// The initial utility configuration happens before TCC is granted on a
    /// first launch, so the poster needs the same explicit restart boundary
    /// as ScrollToZoom.
    func restartSmoothScroll() {
        AZSSmoothScrollEngine.shared.restartAfterEventTap()
    }

    func stopScrollToZoom() {
        AZSScrollToZoomEngine.shared.stop()
    }

    private func saveActionHotKeys() {
        let allowedActionKeys = Set(AZSMouseAction.customShortcutActions.map(\.rawValue))
        let filtered = actionHotKeys.filter { allowedActionKeys.contains($0.key) }
        defaults.set(filtered.mapValues(Int.init), forKey: "AZSActionHotKeys")
        registerActionHotKeys()
    }

    private func saveActionApplication() {
        defaults.set(actionApplicationPath, forKey: "AZSActionApplicationPath")
        registerActionHotKeys()
    }

    private func saveApplicationShortcuts() {
        defaults.set(applicationShortcutHotKeys.reduce(into: [String: Int]()) { $0[String($1.key)] = Int($1.value) }, forKey: "AZSApplicationShortcutHotKeys")
        defaults.set(applicationShortcutPaths.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }, forKey: "AZSApplicationShortcutPaths")
        registerActionHotKeys()
    }

    private func registerActionHotKeys() {
        actionHotKeyMonitors.values.forEach { $0.unregister() }
        actionHotKeyMonitors.removeAll()
        for action in AZSMouseAction.customShortcutActions {
            guard let status = actionHotKeys[action.rawValue] else { continue }
            let monitor = GlobalHotKey()
            monitor.onPressed = { [weak self] in
                self?.perform(action, applicationPath: action == .openApplication ? self?.actionApplicationPath : nil)
            }
            monitor.register(status: status)
            actionHotKeyMonitors[action.rawValue] = monitor
        }
        for slot in applicationShortcutHotKeys.keys {
            guard let status = applicationShortcutHotKeys[slot] else { continue }
            let monitor = GlobalHotKey()
            monitor.onPressed = { [weak self] in
                guard let path = self?.applicationShortcutPaths[slot], FileManager.default.fileExists(atPath: path) else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            monitor.register(status: status)
            actionHotKeyMonitors["openApplication\(slot)"] = monitor
        }
    }

    func suspendActionHotKeys() {
        actionHotKeyMonitors.values.forEach { $0.unregister() }
    }

    func resumeActionHotKeys() {
        registerActionHotKeys()
    }

    private func refreshSnapshot() {
        lock.lock()
        reverseSnapshot = reverseScrolling
        smoothSnapshot = smoothScrolling
        actionsSnapshot = buttonActions
        applicationsSnapshot = buttonApplications
        lock.unlock()
    }

    fileprivate func handle(_ type: CGEventType,
                            _ event: CGEvent,
                            tapProxy: UnsafeMutableRawPointer? = nil) -> Bool {

        lock.lock()
        let reverse = reverseSnapshot
        let smooth = smoothSnapshot
        let actions = actionsSnapshot
        let applications = applicationsSnapshot
        lock.unlock()

        if type == .scrollWheel {
            // ScrollToZoom owns a source-identical hard/soft event-tap
            // pipeline. This shared AZS tap now handles only reverse/smooth.
            if reverse { reverseScrollEvent(event) }
            // Smooth scrolling owns the complete discrete-wheel gesture. Only
            // consume after the engine confirms that its display-synchronised
            // replacement path is healthy; otherwise preserve native input.
            if smooth && !AZSScrollToZoomShouldBypassMOS(),
               AZSSmoothScrollEngine.shared.process(event) {
                return true
            }
        }

        if type == .otherMouseDown {
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            // Publish the physical button even when it is currently unmapped;
            // this makes discovering unusual mouse buttons straightforward.
            DispatchQueue.main.async { [weak self] in self?.lastDetectedButton = button }
            if let action = actions[button], action != .none {
                let applicationPath = applications[button]
                DispatchQueue.main.async { [weak self] in self?.perform(action, applicationPath: applicationPath) }
                return true
            }
        }

        if type == azsSystemDefinedType {
            return handleMediaKey(event)
        }
        // A few third-party keyboards expose the media row as ordinary
        // keyDown/keyUp events instead of NX system-defined events. Support
        // those key codes as a fallback while leaving normal typing untouched.
        if type == .keyDown || type == .keyUp {
            return handleKeyboardMediaKey(type, event)
        }
        return false
    }

    /// Scroll Reverser writes DeltaAxis first, then FixedPtDeltaAxis, and
    /// PointDeltaAxis last. CoreGraphics recalculates smooth-scroll fields when
    /// DeltaAxis changes, so the ordering is essential for mice and trackpads.
    private func reverseScrollEvent(_ event: CGEvent) {
        let integerAxes: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis3),
        ]
        let fixedAxes: [CGEventField] = [
            .scrollWheelEventFixedPtDeltaAxis1,
            .scrollWheelEventFixedPtDeltaAxis2,
            .scrollWheelEventFixedPtDeltaAxis3,
        ]

        let deltas = integerAxes.map { event.getIntegerValueField($0.0) }
        // Mos's ScrollEvent.reverse preserves PointDeltaAxis as a floating
        // value. Reading it through the integer accessor truncates high-
        // resolution wheel input to zero and leaves MOS with no usable delta.
        let points = integerAxes.map { event.getDoubleValueField($0.1) }
        let fixed = fixedAxes.map { event.getDoubleValueField($0) }

        for (index, fields) in integerAxes.enumerated() {
            event.setIntegerValueField(fields.0, value: -deltas[index])
        }
        for (index, field) in fixedAxes.enumerated() {
            event.setDoubleValueField(field, value: -fixed[index])
        }
        for (index, fields) in integerAxes.enumerated() {
            event.setDoubleValueField(fields.1, value: -points[index])
        }
    }

    private func perform(_ action: AZSMouseAction, applicationPath: String? = nil) {
        switch action {
        case .none: break
        case .back: postKey(code: 33, flags: .maskCommand)
        case .forward: postKey(code: 30, flags: .maskCommand)
        case .copy: postKey(code: 8, flags: .maskCommand)
        case .paste: postKey(code: 9, flags: .maskCommand)
        case .cut: prepareFinderFileMove()
        case .moveCutFilesHere: completeFinderFileMove()
        case .undo: postKey(code: 6, flags: .maskCommand)
        case .redo: postKey(code: 6, flags: [.maskCommand, .maskShift])
        case .selectAll: postKey(code: 0, flags: .maskCommand)
        case .missionControl: postKey(code: 126, flags: .maskControl)
        case .appWindows: postKey(code: 125, flags: .maskControl)
        case .desktop: postKey(code: 103, flags: [])
        case .spotlight: postKey(code: 49, flags: .maskCommand)
        case .lockScreen: postKey(code: 12, flags: [.maskCommand, .maskControl])
        case .screenshot: postKey(code: 21, flags: [.maskCommand, .maskShift])
        case .volumeUp: changeVolume(by: 0.0625)
        case .volumeDown: changeVolume(by: -0.0625)
        case .mute: toggleVolumeMute()
        case .brightnessUp: changeBrightness(by: 0.0625)
        case .brightnessDown: changeBrightness(by: -0.0625)
        case .openApplication:
            guard let applicationPath, FileManager.default.fileExists(atPath: applicationPath) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: applicationPath))
        case .deleteSelectedFile:
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"Finder\" to delete (selection as list)")
            _ = script?.executeAndReturnError(&error)
        case .pastePlainText:
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            postKey(code: 9, flags: .maskCommand)
        case .copySelectedPath:
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"Finder\" to get POSIX path of (selection as list)")
            if let script, let result = script.executeAndReturnError(&error).stringValue {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
        case .showClipboardHistory:
            DispatchQueue.main.async {
                ClipboardManager.shared.togglePicker()
            }
        case .toggleVietnamese:
            DispatchQueue.main.async {
                AppState.shared.isVietnamese.toggle()
            }
        }
    }

    private func changeVolume(by amount: Float) {
        let displays = AZSDisplayController.shared
        if let id = displays.keyboardTargetID {
            let next = max(0, min(1, displays.volume(for: id) + amount))
            displays.setVolume(next, for: id)
            AZSVolumeHUD.shared.show(value: next, muted: next == 0, displayID: id)
        } else {
            AZSAudio.setVolume(AZSAudio.volume() + amount)
            AZSVolumeHUD.shared.show(value: AZSAudio.volume())
        }
    }

    /// Finder intentionally has no Command-X operation for files. Its native
    /// move workflow is Command-C followed by Option-Command-V, which preserves
    /// all Finder pasteboard flavours (aliases, packages and multiple files).
    private func prepareFinderFileMove() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            NSSound.beep()
            return
        }
        postKey(code: 8, flags: .maskCommand)
    }

    /// Completes the Cut workflow with Finder's native "Move Item Here"
    /// command. This is intentionally separate from normal Command-V so users
    /// can assign a convenient key without reintroducing macOS's Paste action.
    private func completeFinderFileMove() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            NSSound.beep()
            return
        }
        postKey(code: 9, flags: [.maskCommand, .maskAlternate])
    }

    private func toggleVolumeMute() {
        let displays = AZSDisplayController.shared
        if let id = displays.keyboardTargetID {
            let current = displays.volume(for: id)
            let next = current > 0 ? 0 : max(0.0625, lastExternalVolume)
            if current > 0 { lastExternalVolume = current }
            displays.setVolume(next, for: id)
            AZSVolumeHUD.shared.show(value: next, muted: next == 0, displayID: id)
        } else {
            AZSAudio.setMuted(!AZSAudio.isMuted())
            AZSVolumeHUD.shared.show(value: AZSAudio.volume(), muted: AZSAudio.isMuted())
        }
    }

    private func changeBrightness(by amount: Float) {
        let displays = AZSDisplayController.shared
        if let (displayID, value) = displays.stepKeyboardBrightness(by: amount) {
            AZSVolumeHUD.shared.showBrightness(value: value, displayID: displayID)
        }
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags) {
        // A Carbon global hotkey has already consumed the physical key event.
        // Post the generated command through the session tap so the current
        // frontmost application receives it reliably (not AZS Tools).
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticUtilityEventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticUtilityEventMarker)
        down?.post(tap: .cgSessionEventTap); up?.post(tap: .cgSessionEventTap)
    }

    /// Returns true when the media-key event belongs to an external display and
    /// must not continue to macOS's normal CoreAudio volume handler.
    private func handleMediaKey(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        // The data1 payload is stable across macOS versions; do not reject a
        // valid media key only because its system-defined subtype changed.
        let data = ns.data1
        let key = (data >> 16) & 0xFFFF
        let state = (data >> 8) & 0xFF
        // NX_KEYTYPE_SOUND_UP/DOWN/MUTE = 0/1/7,
        // NX_KEYTYPE_BRIGHTNESS_UP/DOWN = 2/3.
        guard key == 0 || key == 1 || key == 2 || key == 3 || key == 7 else { return false }

        let displays = AZSDisplayController.shared
        let displayID = (key == 2 || key == 3)
            ? displays.keyboardBrightnessTargetID
            : displays.keyboardTargetID
        guard let displayID else {
            // No external DDC target: allow macOS to update CoreAudio, then show
            // the same percentage HUD for the built-in/default audio output.
            if (key == 0 || key == 1 || key == 7) && state == 0xA {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    AZSVolumeHUD.shared.show(value: AZSAudio.volume(), muted: AZSAudio.isMuted())
                }
            }
            return false
        }

        // Consume both key-down and key-up. Only key-down performs an action;
        // repeated key-down events naturally provide press-and-hold behavior.
        // NX_KEYDOWN is 0xA and NX_KEYUP is 0xB. Newer systems may add a
        // repeat bit, so compare the low nibble instead of the whole byte.
        guard (state & 0x0F) == 0xA else { return true }
        applyMediaKey(key, displayID: displayID, displays: displays)
        return true
    }

    private func handleKeyboardMediaKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Apple media-row virtual key codes; external keyboards commonly use
        // these directly when the function row is configured as media keys.
        let key: Int
        switch keyCode {
        case 72: key = 0   // volume up
        case 73: key = 1   // volume down
        case 74: key = 7   // mute
        case 113: key = 2  // brightness up
        case 107: key = 3  // brightness down
        case 144: key = 2  // standard brightness-up media key
        case 145: key = 3  // standard brightness-down media key
        default: return false
        }
        let displays = AZSDisplayController.shared
        let displayID = (key == 2 || key == 3)
            ? displays.keyboardBrightnessTargetID
            : displays.keyboardTargetID
        guard let displayID else { return false }
        if type == .keyDown {
            applyMediaKey(key, displayID: displayID, displays: displays)
        }
        return true
    }

    private func applyMediaKey(_ key: Int, displayID: CGDirectDisplayID, displays: AZSDisplayController) {
        switch key {
        case 0:
            if let (_, value) = displays.stepKeyboardVolume(by: 0.0625) {
                lastExternalVolume = max(value, 0.0625)
                AZSVolumeHUD.shared.show(value: value, muted: false, displayID: displayID)
            }
        case 1:
            if let (_, value) = displays.stepKeyboardVolume(by: -0.0625) {
                if value > 0 { lastExternalVolume = value }
                AZSVolumeHUD.shared.show(value: value, muted: value == 0, displayID: displayID)
            }
        case 7:
            let current = displays.volume(for: displayID)
            if current > 0 {
                lastExternalVolume = current
                displays.setVolume(0, for: displayID)
                AZSVolumeHUD.shared.show(value: 0, muted: true, displayID: displayID)
            } else {
                let restored = max(0.0625, lastExternalVolume)
                displays.setVolume(restored, for: displayID)
                AZSVolumeHUD.shared.show(value: restored, muted: false, displayID: displayID)
            }
        case 2:
            changeBrightness(by: 0.0625)
        case 3:
            changeBrightness(by: -0.0625)
        default: break
        }
    }
}

/// C entry point used by the primary OpenKey Accessibility tap. Using an
/// opaque pointer keeps the Swift/Objective-C++ boundary stable and avoids a
/// second event tap that may be denied by macOS.
@_cdecl("AZSHandleUtilityEvent")
func AZSHandleUtilityEvent(_ typeRaw: UInt32,
                           _ eventPointer: UnsafeMutableRawPointer?,
                           _ tapProxy: UnsafeMutableRawPointer?) -> Int32 {
    guard let eventPointer, let type = CGEventType(rawValue: typeRaw) else { return 0 }
    let event = Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()
    return AZSUtilityController.shared.handle(type, event, tapProxy: tapProxy) ? 1 : 0
}

private let azsSystemDefinedType = CGEventType(rawValue: 14)!

enum AZSAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func device() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }
    static func volume() -> Float32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        let id = device()
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        if status == noErr { return max(0, min(1, value)) }

        // Some USB/Bluetooth devices do not expose the virtual-main property.
        // Read the physical left/right channels instead and average them.
        var values: [Float32] = []
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var channel: Float32 = 0
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &channel) == noErr { values.append(channel) }
        }
        return values.isEmpty ? 0 : max(0, min(1, values.reduce(0, +) / Float32(values.count)))
    }
    static func setVolume(_ value: Float32) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = max(0, min(1, value)); let size = UInt32(MemoryLayout<Float32>.size); let id = device()
        if AudioObjectSetPropertyData(id, &address, 0, nil, size, &v) == noErr { return }
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            _ = AudioObjectSetPropertyData(id, &address, 0, nil, size, &v)
        }
    }
    static func isMuted() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device(), &address, 0, nil, &size, &value); return value != 0
    }
    static func setMuted(_ muted: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0; let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device(), &address, 0, nil, size, &value)
    }
}

final class AZSVolumeHUD {
    static let shared = AZSVolumeHUD()
    private var panel: NSPanel?
    private var view: AZSVolumeHUDView?
    private var dismissWorkItem: DispatchWorkItem?

    func show(value: Float, muted: Bool = false, displayID: CGDirectDisplayID? = nil) {
        show(value: value, muted: muted, displayID: displayID, brightness: false)
    }

    func showBrightness(value: Float, displayID: CGDirectDisplayID? = nil) {
        show(value: value, muted: false, displayID: displayID, brightness: true)
    }

    private func show(value: Float, muted: Bool, displayID: CGDirectDisplayID?, brightness: Bool) {
        DispatchQueue.main.async {
            if self.panel == nil {
                let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 226, height: 62),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
                p.isOpaque = false
                p.backgroundColor = .clear
                p.level = .statusBar
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                p.hasShadow = true
                p.ignoresMouseEvents = true
                let v = AZSVolumeHUDView(frame: p.contentView?.bounds ?? .zero)
                v.autoresizingMask = [.width, .height]
                p.contentView = v
                self.panel = p
                self.view = v
            }
            self.view?.set(value: value, muted: muted, brightness: brightness)
            let screen = displayID.flatMap { id in
                NSScreen.screens.first(where: { $0.azsHUDDisplayID == id })
            } ?? NSScreen.main
            if let screen {
                let frame = screen.visibleFrame
                self.panel?.setFrameOrigin(NSPoint(x: frame.midX - 113, y: frame.minY + 64))
            }
            self.panel?.orderFrontRegardless()
            self.dismissWorkItem?.cancel()
            let dismiss = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            self.dismissWorkItem = dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: dismiss)
        }
    }
}

/// Draws the entire HUD in one view. This avoids a transparent/visual-effect
/// subview ordering issue on macOS 26 that previously produced a blank white
/// rectangle instead of the slider contents.
private final class AZSVolumeHUDView: NSView {
    private var value: CGFloat = 0.5
    private var muted = false
    private var brightness = false

    override var isOpaque: Bool { false }

    func set(value: Float, muted: Bool, brightness: Bool) {
        self.value = CGFloat(max(0, min(1, value)))
        self.muted = muted
        self.brightness = brightness
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = bounds.insetBy(dx: 2, dy: 2)
        let backgroundPath = NSBezierPath(roundedRect: background, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.055, alpha: 0.86).setFill()
        backgroundPath.fill()

        // A subtle inner highlight gives the panel a soft glass edge without
        // the heavy outlined-box appearance of the previous HUD.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        backgroundPath.lineWidth = 0.75
        backgroundPath.stroke()

        let iconCircle = NSRect(x: 12, y: 11, width: 40, height: 40)
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(ovalIn: iconCircle).fill()

        let symbolName: String
        if brightness {
            symbolName = "sun.max.fill"
        } else if muted || value <= 0.001 {
            symbolName = "speaker.slash.fill"
        } else if value < 0.34 {
            symbolName = "speaker.wave.1.fill"
        } else if value < 0.67 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let pointConfig = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [
                brightness ? .systemYellow : .white
            ])
            let configured = image.withSymbolConfiguration(pointConfig.applying(colorConfig)) ?? image
            let imageSize = configured.size
            let imageRect = NSRect(x: iconCircle.midX - imageSize.width / 2,
                                   y: iconCircle.midY - imageSize.height / 2,
                                   width: imageSize.width, height: imageSize.height)
            configured.draw(in: imageRect)
        }

        let percent = Int((value * 100).rounded())
        let percentString = "\(percent)%" as NSString
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.76),
        ]
        let percentWidth = percentString.size(withAttributes: percentAttributes).width
        percentString.draw(at: NSPoint(x: bounds.width - 14 - percentWidth, y: 24),
                           withAttributes: percentAttributes)

        let percentAreaWidth: CGFloat = 38
        let track = NSRect(x: 64, y: 27.5,
                           width: bounds.width - 64 - percentAreaWidth - 12,
                           height: 7)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * value, height: track.height)
        if fill.width > 0 {
            (brightness ? NSColor.systemYellow : NSColor.systemBlue).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }
}

private extension NSScreen {
    var azsHUDDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
