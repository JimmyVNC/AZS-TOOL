//
//  AZSBatteryBoiCompatibility.swift
//  AZS Tools
//
//  Compatibility collector inspired by BatteryBoi's GPLv3 Bluetooth device
//  discovery strategy. BatteryBoi combines System Information and the
//  AppleDeviceManagementHIDEventService IORegistry class. This is a native
//  Swift reimplementation: it does not bundle or require Python.
//

import Foundation

struct AZSBatteryBoiRecord: Equatable {
    let name: String?
    let manufacturer: String?
    let transport: String?
    let address: String?
    let vendorID: Int?
    let productID: Int?
    let batteryPercent: Int?
    let isMouse: Bool
    let isConnected: Bool
}

enum AZSBatteryBoiCompatibility {
    private static let systemProfilerPath = "/usr/sbin/system_profiler"
    private static let ioRegistryPath = "/usr/sbin/ioreg"
    private static let cacheLifetime: TimeInterval = 60
    private static let systemProfilerTimeout: TimeInterval = 7
    private static let ioRegistryTimeout: TimeInterval = 5
    private static let profilerOutputLimit = 4 * 1_024 * 1_024
    private static let classIORegistryOutputLimit = 2 * 1_024 * 1_024

    private static let cacheLock = NSLock()
    private static var cachedAt = Date.distantPast
    private static var cachedRecords: [AZSBatteryBoiRecord] = []
    private static var collectionInProgress = false

    /// Returns connected-device metadata and any battery level macOS already
    /// knows about. The result is cached because System Information can take a
    /// few seconds on machines with many Bluetooth devices.
    static func collectRecords(forceRefresh: Bool = false) -> [AZSBatteryBoiRecord] {
        cacheLock.lock()
        let cacheIsFresh = Date().timeIntervalSince(cachedAt) < cacheLifetime
        if !forceRefresh && cacheIsFresh {
            let result = cachedRecords
            cacheLock.unlock()
            return result
        }
        if collectionInProgress {
            let result = cachedRecords
            cacheLock.unlock()
            return result
        }
        collectionInProgress = true
        cacheLock.unlock()

        var records: [AZSBatteryBoiRecord] = []

        if let json = runProcess(
            executable: systemProfilerPath,
            arguments: ["SPBluetoothDataType", "-json", "-detailLevel", "full"],
            timeout: systemProfilerTimeout,
            outputLimit: profilerOutputLimit
        ) {
            records.append(contentsOf: parseSystemProfiler(data: json))
        }

        // JSON was introduced after the XML output and can occasionally be
        // unavailable or incomplete on older macOS releases. Only pay for the
        // second profiler pass when the first one found no device records.
        if records.isEmpty,
           let xml = runProcess(
               executable: systemProfilerPath,
               arguments: ["SPBluetoothDataType", "-xml", "-detailLevel", "full"],
               timeout: systemProfilerTimeout,
               outputLimit: profilerOutputLimit
           ) {
            records.append(contentsOf: parseSystemProfiler(data: xml))
        }

        // BatteryBoi originally queried only the first class. Newer macOS
        // releases moved many Bluetooth HID devices under IOHIDUserDevice and
        // AppleUserHIDEventService. Query those targeted classes too; this is
        // dramatically cheaper than dumping the complete IORegistry tree.
        let hidServiceClasses = [
            "AppleDeviceManagementHIDEventService",
            "IOHIDUserDevice",
            "AppleUserHIDEventService"
        ]
        var ioRegistryRecords: [AZSBatteryBoiRecord] = []
        for className in hidServiceClasses {
            guard let classData = runProcess(
                executable: ioRegistryPath,
                arguments: ["-c", className, "-r", "-l", "-w", "0"],
                timeout: ioRegistryTimeout,
                outputLimit: classIORegistryOutputLimit
            ), let output = String(data: classData, encoding: .utf8) else { continue }
            ioRegistryRecords.append(contentsOf: parseIORegistry(text: output))
        }
        records.append(contentsOf: ioRegistryRecords)

        let result = mergeRecords(records)
            .filter { $0.isMouse && $0.isConnected }
            .sorted {
                ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }

        cacheLock.lock()
        cachedRecords = result
        cachedAt = Date()
        collectionInProgress = false
        cacheLock.unlock()
        return result
    }

    // MARK: - Testable parsers

    /// Parses either JSON (`system_profiler -json`) or XML plist
    /// (`system_profiler -xml`) output.
    static func parseSystemProfiler(data: Data) -> [AZSBatteryBoiRecord] {
        let root: Any
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            root = json
        } else if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) {
            root = plist
        } else {
            return []
        }

        var records: [AZSBatteryBoiRecord] = []
        walkProfilerObject(root, inherited: [:], connectedContext: nil, into: &records)
        return mergeRecords(records)
    }

    /// Parses BatteryBoi's original class-specific ioreg text and the targeted
    /// HID-service classes used by newer macOS versions.
    static func parseIORegistry(text: String) -> [AZSBatteryBoiRecord] {
        guard !text.isEmpty else { return [] }

        var records: [AZSBatteryBoiRecord] = []
        var properties: [String: Any] = [:]
        var entryName: String?
        var entryClass: String?
        var rawBlock = ""

        func finishEntry() {
            guard !properties.isEmpty || entryName != nil || entryClass != nil else { return }
            if let entryName, properties["__entryName"] == nil {
                properties["__entryName"] = entryName
            }
            if let entryClass {
                properties["__entryClass"] = entryClass
            }
            properties["__rawBlock"] = rawBlock

            if let record = makeRecord(
                from: properties,
                defaultConnected: true,
                sourceIsIORegistry: true
            ) {
                let classIsBatteryService = entryClass?.localizedCaseInsensitiveContains(
                    "AppleDeviceManagementHIDEventService"
                ) == true
                if record.batteryPercent != nil || record.isMouse || classIsBatteryService {
                    records.append(record)
                }
            }
        }

        for substring in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)
            if isIORegistryEntryLine(line) {
                finishEntry()
                properties.removeAll(keepingCapacity: true)
                rawBlock = line
                let header = parseIORegistryEntryHeader(line)
                entryName = header.name
                entryClass = header.className
                continue
            }

            if !rawBlock.isEmpty {
                rawBlock.append("\n")
                rawBlock.append(line)
            }

            if let property = parseIORegistryProperty(line) {
                properties[property.key] = property.value
            }
        }
        finishEntry()

        return mergeRecords(records)
    }

    static func normalizeAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.unicodeScalars.filter { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
        }
        let flattened = String(String.UnicodeScalarView(hex)).lowercased()
        guard flattened.count == 12 else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: ":", with: "-")
        }
        return stride(from: 0, to: 12, by: 2)
            .map { index -> String in
                let start = flattened.index(flattened.startIndex, offsetBy: index)
                let end = flattened.index(start, offsetBy: 2)
                return String(flattened[start..<end])
            }
            .joined(separator: "-")
    }

    static func normalizeIdentifier(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber, !isBoolean(number) {
            return number.intValue
        }
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let hexRange = trimmed.range(of: #"0[xX][0-9a-fA-F]+"#, options: .regularExpression) {
            let token = trimmed[hexRange].dropFirst(2)
            return Int(token, radix: 16)
        }
        if let decimalRange = trimmed.range(of: #"[-+]?\d+"#, options: .regularExpression) {
            return Int(trimmed[decimalRange])
        }
        return nil
    }

    static func normalizeBatteryPercent(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        let value: Double
        let isExplicitRatio: Bool

        if let number = raw as? NSNumber, !isBoolean(number) {
            value = number.doubleValue
            let type = String(cString: number.objCType)
            isExplicitRatio = (type == "f" || type == "d") && value >= 0 && value <= 1
        } else if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = trimmed.range(
                of: #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#,
                options: .regularExpression
            ), let parsed = Double(trimmed[range]) else { return nil }
            value = parsed
            isExplicitRatio = !trimmed.contains("%") && trimmed.contains(".") && value >= 0 && value <= 1
        } else {
            return nil
        }

        let percent = isExplicitRatio ? value * 100 : value
        guard percent.isFinite, percent >= 0, percent <= 100 else { return nil }
        return Int(percent.rounded())
    }

    // MARK: - System profiler parsing

    private static func walkProfilerObject(
        _ object: Any,
        inherited: [String: Any],
        connectedContext: Bool?,
        into records: inout [AZSBatteryBoiRecord]
    ) {
        if let array = object as? [Any] {
            for child in array {
                walkProfilerObject(
                    child,
                    inherited: inherited,
                    connectedContext: connectedContext,
                    into: &records
                )
            }
            return
        }

        guard let dictionary = dictionaryWithStringKeys(object) else { return }
        var context = inherited
        var localMetadata: [String: Any] = [:]
        for (key, value) in dictionary where isRelevantMetadataKey(key) {
            localMetadata[key] = value
            let normalizedKey = key.lowercased()
            // `_name` at the top of a System Profiler report commonly means
            // "Bluetooth" or the data-type name. Keep it for this candidate,
            // but do not leak it into child device dictionaries.
            if normalizedKey != "_name" && normalizedKey != "name" {
                context[key] = value
            }
        }

        var localConnected = connectedContext
        if let explicit = boolValue(value(in: dictionary, keys: [
            "device_isConnected", "isConnected", "Connected", "connected"
        ])) {
            localConnected = explicit
        }

        if hasDeviceEvidence(dictionary) {
            var candidate = context
            for (key, value) in localMetadata {
                candidate[key] = value
            }
            if let record = makeRecord(
                from: candidate,
                defaultConnected: localConnected ?? true,
                sourceIsIORegistry: false
            ), record.name != nil || record.address != nil || record.vendorID != nil {
                records.append(record)
            }
        }

        for (key, child) in dictionary {
            var childContext = context
            if dictionaryWithStringKeys(child) != nil, isProfilerDeviceWrapperKey(key) {
                childContext["__entryName"] = key
            }
            let childConnected: Bool?
            if key.caseInsensitiveCompare("device_connected") == .orderedSame,
               child is [Any] || dictionaryWithStringKeys(child) != nil {
                childConnected = true
            } else if key.caseInsensitiveCompare("device_not_connected") == .orderedSame,
                      child is [Any] || dictionaryWithStringKeys(child) != nil {
                childConnected = false
            } else {
                childConnected = localConnected
            }
            walkProfilerObject(
                child,
                inherited: childContext,
                connectedContext: childConnected,
                into: &records
            )
        }
    }

    private static func hasDeviceEvidence(_ dictionary: [String: Any]) -> Bool {
        let keys = dictionary.keys.map { $0.lowercased() }
        return keys.contains(where: {
            $0 == "device_address" ||
            $0 == "device_productid" ||
            $0 == "device_vendorid" ||
            $0 == "device_minortype" ||
            $0.hasPrefix("device_batterylevel") ||
            $0 == "batterypercent"
        })
    }

    private static func isProfilerDeviceWrapperKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        guard !normalized.isEmpty,
              !normalized.hasPrefix("_"),
              !normalized.hasPrefix("device_"),
              !normalized.hasPrefix("sp"),
              normalized != "items",
              normalized != "bluetooth" else { return false }
        return true
    }

    // MARK: - IORegistry text parsing

    private static func isIORegistryEntryLine(_ line: String) -> Bool {
        guard let range = line.range(of: "+-o") else { return false }
        let prefix = line[..<range.lowerBound]
        return prefix.allSatisfy { $0 == " " || $0 == "|" }
    }

    private static func parseIORegistryEntryHeader(_ line: String) -> (name: String?, className: String?) {
        guard let marker = line.range(of: "+-o") else { return (nil, nil) }
        let remainder = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        let name: String?
        if let separator = remainder.range(of: "  <") {
            name = String(remainder[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            name = remainder.split(separator: "<", maxSplits: 1).first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
        }

        let className: String?
        if let range = remainder.range(
            of: #"<class\s+([^,>]+)"#,
            options: .regularExpression
        ) {
            let matched = String(remainder[range])
            className = matched
                .replacingOccurrences(of: "<class", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            className = nil
        }
        return (name?.isEmpty == false ? name : nil, className)
    }

    private static func parseIORegistryProperty(_ line: String) -> (key: String, value: Any)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let left = line[..<equals]
        guard let firstQuote = left.firstIndex(of: "\"") else { return nil }
        let afterFirst = left.index(after: firstQuote)
        guard let secondQuote = left[afterFirst...].firstIndex(of: "\"") else { return nil }
        let key = String(left[afterFirst..<secondQuote])
        guard !key.isEmpty else { return nil }

        let rawValue = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"") && rawValue.count >= 2 {
            return (key, String(rawValue.dropFirst().dropLast()))
        }
        if rawValue.caseInsensitiveCompare("Yes") == .orderedSame ||
            rawValue.caseInsensitiveCompare("true") == .orderedSame {
            return (key, true)
        }
        if rawValue.caseInsensitiveCompare("No") == .orderedSame ||
            rawValue.caseInsensitiveCompare("false") == .orderedSame {
            return (key, false)
        }
        if let identifier = normalizeIdentifier(rawValue),
           rawValue.range(of: #"^[-+]?(?:0[xX][0-9a-fA-F]+|\d+)$"#, options: .regularExpression) != nil {
            return (key, identifier)
        }
        return (key, rawValue)
    }

    // MARK: - Record normalization

    private static func makeRecord(
        from properties: [String: Any],
        defaultConnected: Bool,
        sourceIsIORegistry: Bool
    ) -> AZSBatteryBoiRecord? {
        let rawName = stringValue(value(in: properties, keys: [
            "device_name", "DeviceName", "Product", "ProductName", "__entryName", "_name", "Name"
        ]))
        let name = cleanDeviceName(rawName)
        let rawManufacturer = stringValue(value(in: properties, keys: [
            "device_manufacturer", "Manufacturer", "ManufacturerName", "VendorName"
        ]))
        let parsedVendorID = normalizeIdentifier(value(in: properties, keys: [
            "device_vendorID", "VendorID", "VendorId", "idVendor"
        ]))
        let parsedProductID = normalizeIdentifier(value(in: properties, keys: [
            "device_productID", "ProductID", "ProductId", "idProduct"
        ]))
        let vendorID = parsedVendorID.flatMap { $0 > 0 ? $0 : nil }
        let productID = parsedProductID.flatMap { $0 > 0 ? $0 : nil }
        let manufacturer = cleanString(rawManufacturer) ?? inferredManufacturer(vendorID: vendorID)
        let address = normalizeAddress(stringValue(value(in: properties, keys: [
            "device_address", "DeviceAddress", "BluetoothAddress", "Address"
        ])))
        let rawTransport = stringValue(value(in: properties, keys: [
            "device_transport", "Transport", "TransportType", "DeviceTransport"
        ]))
        let transport = cleanString(rawTransport) ?? (address == nil ? nil : "Bluetooth")

        let batteryValues = batteryComponents(in: properties)
        let batteryPercent = batteryValues.min()
        let explicitConnected = boolValue(value(in: properties, keys: [
            "device_isConnected", "isConnected", "Connected", "connected", "__connectedContext"
        ]))
        let isConnected = explicitConnected ?? defaultConnected
        let mouse = isMouseRecord(properties: properties,
                                  name: name,
                                  sourceIsIORegistry: sourceIsIORegistry)

        guard name != nil || address != nil || vendorID != nil || productID != nil || batteryPercent != nil else {
            return nil
        }
        return AZSBatteryBoiRecord(
            name: name,
            manufacturer: manufacturer,
            transport: transport,
            address: address,
            vendorID: vendorID,
            productID: productID,
            batteryPercent: batteryPercent,
            isMouse: mouse,
            isConnected: isConnected
        )
    }

    private static func batteryComponents(in properties: [String: Any]) -> [Int] {
        let preferredKeys = [
            "device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight",
            "device_batteryLevel", "BatteryPercent", "BatteryLevel", "BatteryCapacity",
            "AppleDeviceBatteryLevel"
        ]
        var result: [Int] = []
        for key in preferredKeys {
            if let percent = normalizeBatteryPercent(value(in: properties, keys: [key])) {
                result.append(percent)
            }
        }

        // Future system_profiler versions may add another battery component.
        // Pick it up while excluding unrelated status/cycle fields.
        for (key, raw) in properties {
            let normalized = key.lowercased()
            guard normalized.contains("battery"),
                  normalized.contains("level") || normalized.contains("percent"),
                  !preferredKeys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                  let percent = normalizeBatteryPercent(raw) else { continue }
            result.append(percent)
        }
        return result
    }

    private static func isMouseRecord(
        properties: [String: Any],
        name: String?,
        sourceIsIORegistry: Bool
    ) -> Bool {
        let minorType = stringValue(value(in: properties, keys: [
            "device_minorType", "MinorType", "DeviceType", "Type"
        ]))?.lowercased() ?? ""
        if minorType.contains("mouse") || minorType.contains("trackpad") || minorType.contains("pointing") {
            return true
        }
        if minorType.contains("keyboard") || minorType.contains("headphone") || minorType.contains("speaker") {
            return false
        }

        let usagePage = normalizeIdentifier(value(in: properties, keys: [
            "PrimaryUsagePage"
        ]))
        let usage = normalizeIdentifier(value(in: properties, keys: [
            "PrimaryUsage"
        ]))
        if let usagePage, let usage {
            if usagePage == 0x01, usage == 0x01 || usage == 0x02 {
                return true
            }
            // A direct PrimaryUsage pair is stronger evidence than nested
            // IOMatchedPersonality dictionaries later in the same ioreg block.
            // This prevents consumer-control/headset services from borrowing
            // a generic mouse usage pair from their matching personality.
            return false
        }

        // Only inspect the actual DeviceUsagePairs property. Searching the
        // entire registry block can accidentally match a mouse pair nested in
        // IOMatchedPersonality for a non-mouse service (for example Headset).
        let usagePairs = stringValue(value(in: properties, keys: ["DeviceUsagePairs"]))?
            .lowercased() ?? ""
        let hasMouseUsagePair = usagePage == nil && usage == nil && usagePairs.range(
            of: #"(?s)(?:deviceusagepage|primaryusagepage)\"?\s*=\s*(?:0x0*1|1).*?(?:deviceusage|primaryusage)\"?\s*=\s*(?:0x0*[12]|[12])"#,
            options: .regularExpression
        ) != nil
        if sourceIsIORegistry && hasMouseUsagePair {
            return true
        }

        let normalizedName = (name ?? "").lowercased()
        let explicitMouseTerms = ["mouse", "trackpad", "pointing device", "touchpad"]
        if explicitMouseTerms.contains(where: normalizedName.contains) {
            return true
        }
        let excludedTerms = [
            "keyboard", "headphone", "headset", "speaker", "gamepad", "controller",
            "receiver", "dongle", "audio", "camera", "microphone"
        ]
        if excludedTerms.contains(where: normalizedName.contains) {
            return false
        }

        // Several well-known mouse families omit the word "mouse" from their
        // product name (MX Master, M650, DeathAdder, Basilisk, Aerox, etc.).
        let familyTerms = [
            "mx master", "mx anywhere", "m650", "m705", "m720", "m750", "lift vertical",
            "deathadder", "basilisk", "viper", "naga", "orochi", "pro click",
            "aerox", "rival", "sensei", "dark core", "harpoon", "model o", "model d"
        ]
        if familyTerms.contains(where: normalizedName.contains) {
            return true
        }
        return false
    }

    private static func mergeRecords(_ records: [AZSBatteryBoiRecord]) -> [AZSBatteryBoiRecord] {
        var merged: [AZSBatteryBoiRecord] = []
        for record in records {
            guard let index = merged.firstIndex(where: { recordsReferToSameDevice($0, record) }) else {
                merged.append(record)
                continue
            }
            let old = merged[index]
            merged[index] = AZSBatteryBoiRecord(
                name: preferName(old.name, record.name),
                manufacturer: old.manufacturer ?? record.manufacturer,
                transport: old.transport ?? record.transport,
                address: old.address ?? record.address,
                vendorID: old.vendorID ?? record.vendorID,
                productID: old.productID ?? record.productID,
                batteryPercent: record.batteryPercent ?? old.batteryPercent,
                isMouse: old.isMouse || record.isMouse,
                isConnected: old.isConnected || record.isConnected
            )
        }
        return merged
    }

    private static func recordsReferToSameDevice(
        _ lhs: AZSBatteryBoiRecord,
        _ rhs: AZSBatteryBoiRecord
    ) -> Bool {
        if let leftAddress = lhs.address, let rightAddress = rhs.address {
            return leftAddress == rightAddress
        }

        let leftName = normalizedName(lhs.name)
        let rightName = normalizedName(rhs.name)
        guard !leftName.isEmpty, leftName == rightName else { return false }
        if let leftVendor = lhs.vendorID, let rightVendor = rhs.vendorID,
           leftVendor != rightVendor { return false }
        if let leftProduct = lhs.productID, let rightProduct = rhs.productID,
           leftProduct != rightProduct { return false }

        // If one source lacks the Bluetooth address, an exact normalized name
        // plus non-conflicting VID/PID is the strongest available join. Never
        // merge two records that carry different concrete addresses.
        return true
    }

    // MARK: - Generic helpers

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        let readGroup = DispatchGroup()
        let dataLock = NSLock()
        var captured = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = output.fileHandleForReading
            while true {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                } catch {
                    break
                }
                if chunk.isEmpty { break }
                dataLock.lock()
                let room = max(0, outputLimit - captured.count)
                if room > 0 {
                    captured.append(chunk.prefix(room))
                }
                dataLock.unlock()
                // Continue draining after the cap so the child process cannot
                // deadlock on a full pipe.
            }
            readGroup.leave()
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 0.5)
            return nil
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = termination.wait(timeout: .now() + 1)
            output.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 1)
            return nil
        }
        guard readGroup.wait(timeout: .now() + 1) == .success,
              process.terminationStatus == 0 else { return nil }

        dataLock.lock()
        let result = captured
        dataLock.unlock()
        return result
    }

    private static func dictionaryWithStringKeys(_ object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] { return dictionary }
        guard let dictionary = object as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if let key = key as? String { result[key] = value }
        }
        return result
    }

    private static func isRelevantMetadataKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.hasPrefix("device_") ||
            normalized.contains("battery") ||
            normalized.contains("usage") ||
            [
                "product", "productname", "manufacturer", "manufacturername", "vendorname",
                "vendorid", "productid", "transport", "transporttype", "deviceaddress",
                "bluetoothaddress", "address", "connected", "isconnected", "_name", "name"
            ].contains(normalized)
    }

    private static func value(in dictionary: [String: Any], keys: [String]) -> Any? {
        for requested in keys {
            if let exact = dictionary[requested] { return exact }
            if let match = dictionary.first(where: {
                $0.key.caseInsensitiveCompare(requested) == .orderedSame
            }) {
                return match.value
            }
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber, !isBoolean(number) { return number.stringValue }
        return nil
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let number = raw as? NSNumber {
            if isBoolean(number) { return number.boolValue }
            if number.intValue == 0 || number.intValue == 1 { return number.boolValue }
        }
        guard let string = raw as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "connected", "1": return true
        case "false", "no", "disconnected", "0": return false
        default: return nil
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func cleanString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanDeviceName(_ raw: String?) -> String? {
        guard let value = cleanString(raw) else { return nil }
        let serviceNames = [
            "AppleDeviceManagementHIDEventService", "AppleUserHIDEventService",
            "IOHIDEventService", "IOHIDInterface", "IOHIDUserDevice"
        ]
        return serviceNames.contains(where: { value.caseInsensitiveCompare($0) == .orderedSame })
            ? nil
            : value
    }

    private static func inferredManufacturer(vendorID: Int?) -> String? {
        switch vendorID {
        case 0x046D: return "Logitech"
        case 0x1532: return "Razer"
        case 0x05AC: return "Apple"
        case 0x045E: return "Microsoft"
        case 0x1038: return "SteelSeries"
        case 0x1B1C: return "Corsair"
        case 0x1E7D: return "ROCCAT"
        default: return nil
        }
    }

    private static func normalizedName(_ name: String?) -> String {
        guard let name else { return "" }
        return name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func preferName(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs.count > lhs.count ? rhs : lhs
    }
}
