//
//  MacroPage.swift
//  mkey
//
//  Shortcut (macro) manager: table + add/edit/delete + import/export.
//

import SwiftUI
import UniformTypeIdentifiers

struct MacroRow: Identifiable, Hashable {
    let id: String
    let text: String
    let content: String
}

struct MacroPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var cloudSync = MacroCloudSync.shared
    @AppStorage("macroCloudSyncEnabled") private var macroCloudSyncEnabled = false

    @State private var rows: [MacroRow] = []
    @State private var selection: MacroRow.ID?
    @State private var newText = ""
    @State private var newContent = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case text, content }

    private var isEditingExisting: Bool {
        rows.contains { $0.text == newText }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Tuỳ chọn") {
                    Toggle("Bật gõ tắt", isOn: $state.useMacro)
                    Toggle("Dùng gõ tắt cả trong chế độ tiếng Anh", isOn: $state.useMacroInEnglishMode)
                        .disabled(!state.useMacro)
                    Toggle("Tự hoa theo từ gốc (btw→by the way, Btw→By the way)", isOn: $state.autoCapsMacro)
                        .disabled(!state.useMacro)
                }

                Section("Đồng bộ") {
                    Toggle("Đồng bộ danh sách gõ tắt qua iCloud Drive", isOn: $macroCloudSyncEnabled)
                        .onChange(of: macroCloudSyncEnabled) { _, enabled in
                            cloudSync.setEnabled(enabled)
                        }

                    HStack(spacing: 8) {
                        Image(systemName: cloudSync.isAvailable ? "checkmark.icloud" : "icloud.slash")
                            .foregroundStyle(cloudSync.isAvailable ? Color.accentColor : .secondary)
                        Text(cloudSync.statusText)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Đồng bộ ngay") {
                            cloudSync.syncNow()
                        }
                        .disabled(!macroCloudSyncEnabled)
                    }
                }

                Section("Thêm / sửa gõ tắt") {
                    HStack(spacing: 8) {
                        TextField("Từ tắt", text: $newText, prompt: Text("Từ tắt"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .focused($focusedField, equals: .text)
                            .onSubmit { focusedField = .content }
                        TextField("Nội dung thay thế", text: $newContent, prompt: Text("Nội dung thay thế"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($focusedField, equals: .content)
                            .onSubmit { addOrEdit() }
                        Button(isEditingExisting ? "Sửa" : "Thêm") {
                            addOrEdit()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Xoá", role: .destructive) {
                            deleteSelected()
                        }
                        .disabled(!isEditingExisting)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Table(rows, selection: $selection) {
                        TableColumn("Từ tắt") { row in
                            Text(row.text)
                        }
                        .width(min: 90, ideal: 130, max: 220)
                        TableColumn("Nội dung thay thế") { row in
                            Text(row.content)
                        }
                    }
                    .frame(minHeight: 220)
                    .alternatingRowBackgrounds()
                    .onChange(of: selection) { _, newValue in
                        if let id = newValue, let row = rows.first(where: { $0.id == id }) {
                            newText = row.text
                            newContent = row.content
                        }
                    }

                    HStack {
                        Button("Nhập từ file…") { importFromFile() }
                        Button("Xuất ra file…") { exportToFile() }
                        Spacer()
                        Text("\(rows.count) mục")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Danh sách gõ tắt")
                }
            }
            .settingsFormStyle()
        }
        .onAppear {
            reload()
            cloudSync.start()
            cloudSync.setEnabled(macroCloudSyncEnabled)
            focusedField = .text
        }
        .onReceive(NotificationCenter.default.publisher(for: .mkMacroCloudSyncDidImport)) { _ in
            reload()
        }
        .alert("Gõ tắt", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        rows = MKBridge.allMacros().map {
            MacroRow(id: $0.text, text: $0.text, content: $0.content)
        }
    }

    private func addOrEdit() {
        guard !newText.isEmpty, !newContent.isEmpty else {
            errorMessage = "Bạn hãy nhập cả từ tắt và nội dung thay thế!"
            return
        }
        MKBridge.addMacro(newText, content: newContent)
        newText = ""
        newContent = ""
        selection = nil
        reload()
        cloudSync.localMacrosDidChange()
        focusedField = .text
    }

    private func deleteSelected() {
        guard !newText.isEmpty else {
            errorMessage = "Bạn hãy chọn từ cần xoá trong danh sách!"
            return
        }
        guard MKBridge.deleteMacro(newText) else {
            errorMessage = "Không tìm thấy từ tắt \"\(newText)\" trong danh sách."
            return
        }
        newText = ""
        newContent = ""
        selection = nil
        reload()
        cloudSync.localMacrosDidChange()
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.message = "Chọn file dữ liệu gõ tắt"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Dữ liệu gõ tắt"
        alert.informativeText = "Bạn có muốn giữ lại các dữ liệu hiện tại không?"
        alert.addButton(withTitle: "Có")
        alert.addButton(withTitle: "Không")
        let keep = alert.runModal() == .alertFirstButtonReturn
        MKBridge.importMacros(fromFile: url.path, append: keep)
        reload()
        cloudSync.localMacrosDidChange()
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.message = "Chọn nơi lưu dữ liệu gõ tắt"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "mkeyMacro"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MKBridge.exportMacros(toFile: url.path)
    }
}

@MainActor
final class MacroCloudSync: ObservableObject {
    static let shared = MacroCloudSync()

    @Published private(set) var statusText = "Sẵn sàng đồng bộ qua iCloud Drive."
    @Published private(set) var isAvailable = true
    @Published private(set) var lastSyncDate: Date?

    private struct FileSignature: Equatable {
        let modifiedAt: Date?
        let size: Int64
    }

    private let defaults = UserDefaults.standard
    private let enabledKey = "macroCloudSyncEnabled"
    private let pollInterval: TimeInterval = 10
    private var timer: Timer?
    private var lastSignature: FileSignature?

    // Opt-in: syncing user data must not start without explicit consent.
    private var isEnabled: Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    private enum CloudItem { case downloaded, notDownloaded, missing }

    /// A not-yet-downloaded iCloud file appears only as a hidden ".name.icloud"
    /// placeholder; treat that as "exists but needs download", never as missing.
    private func cloudItemState() -> CloudItem {
        let fm = FileManager.default
        if fm.fileExists(atPath: syncFileURL.path) { return .downloaded }
        let placeholder = syncFolderURL.appendingPathComponent(".\(syncFileURL.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { return .notDownloaded }
        return .missing
    }

    private func startDownload() {
        try? FileManager.default.startDownloadingUbiquitousItem(at: syncFileURL)
        statusText = "Đang tải dữ liệu gõ tắt từ iCloud Drive…"
    }

    private var iCloudDriveRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private var syncFolderURL: URL {
        iCloudDriveRootURL.appendingPathComponent("mkey", isDirectory: true)
    }

    private var syncFileURL: URL {
        syncFolderURL.appendingPathComponent("mkeyMacroData.bin")
    }

    private init() {}

    func start() {
        guard timer == nil else { return }
        // .common mode so the iCloud poll keeps firing while a modal sheet is presented.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.importIfCloudChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncNow()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            syncNow()
        } else {
            statusText = "Đồng bộ iCloud Drive đang tắt."
            isAvailable = true
        }
    }

    func syncNow() {
        guard isEnabled else {
            statusText = "Đồng bộ iCloud Drive đang tắt."
            return
        }
        guard ensureSyncFolderExists() else { return }

        switch cloudItemState() {
        case .downloaded:   importFromCloud(force: true)
        case .notDownloaded: startDownload()
        case .missing:      exportToCloud() // first run: seed cloud from this machine
        }
    }

    func localMacrosDidChange() {
        guard isEnabled else { return }
        exportToCloud()
    }

    private func importIfCloudChanged() {
        guard isEnabled, ensureSyncFolderExists() else { return }
        switch cloudItemState() {
        case .downloaded:   importFromCloud(force: false)
        case .notDownloaded: startDownload()
        case .missing:      break // don't auto-overwrite cloud; export only on local change
        }
    }

    /// Coordinated read so we never import a half-synced file.
    private func importFromCloud(force: Bool) {
        guard let signature = fileSignature(at: syncFileURL) else {
            statusText = "Chưa có dữ liệu gõ tắt trên iCloud Drive."
            return
        }
        guard force || signature != lastSignature else { return }

        var coordError: NSError?
        var didImport = false
        NSFileCoordinator().coordinate(readingItemAt: syncFileURL, options: [.withoutChanges], error: &coordError) { url in
            MKBridge.importMacros(fromFile: url.path, append: false)
            didImport = true
        }
        guard didImport, coordError == nil else {
            NSLog("mkey: iCloud read coordination failed: \(String(describing: coordError))")
            statusText = "Không đọc được dữ liệu từ iCloud Drive."
            return
        }
        lastSignature = fileSignature(at: syncFileURL) ?? signature
        lastSyncDate = Date()
        isAvailable = true
        statusText = "Đã cập nhật từ iCloud Drive."
        NotificationCenter.default.post(name: .mkMacroCloudSyncDidImport, object: nil)
    }

    /// Coordinated write so another process never reads a half-written file.
    private func exportToCloud() {
        guard ensureSyncFolderExists() else { return }

        var coordError: NSError?
        var didWrite = false
        NSFileCoordinator().coordinate(writingItemAt: syncFileURL, options: [.forReplacing], error: &coordError) { url in
            MKBridge.exportMacros(toFile: url.path)
            didWrite = true
        }
        guard didWrite, coordError == nil else {
            NSLog("mkey: iCloud write coordination failed: \(String(describing: coordError))")
            statusText = "Không lưu được dữ liệu lên iCloud Drive."
            return
        }
        lastSignature = fileSignature(at: syncFileURL)
        lastSyncDate = Date()
        isAvailable = true
        statusText = "Đã lưu danh sách gõ tắt lên iCloud Drive."
    }

    private func ensureSyncFolderExists() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: iCloudDriveRootURL.path) else {
            isAvailable = false
            statusText = "Không tìm thấy iCloud Drive trên máy này."
            return false
        }

        do {
            try manager.createDirectory(at: syncFolderURL, withIntermediateDirectories: true)
            isAvailable = true
            return true
        } catch {
            isAvailable = false
            statusText = "Không thể tạo thư mục đồng bộ trong iCloud Drive."
            NSLog("mkey: cannot create macro sync folder: \(error)")
            return false
        }
    }

    private func fileSignature(at url: URL) -> FileSignature? {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return FileSignature(modifiedAt: values.contentModificationDate, size: Int64(values.fileSize ?? 0))
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    static let mkMacroCloudSyncDidImport = Notification.Name("MKMacroCloudSyncDidImport")
}
