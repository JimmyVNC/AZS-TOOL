import SwiftUI
import UniformTypeIdentifiers

struct UtilitiesPage: View {
    @ObservedObject private var utilities = AZSUtilityController.shared
    @ObservedObject private var displays = AZSDisplayController.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AZSBrandMark()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AZS Tools").font(.headline)
                        Text("Bảng điều khiển tiện ích macOS").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { displays.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Quét lại màn hình ngoài")
                }
            }

            Section {
                if displays.targets.isEmpty {
                    Label("Chưa tìm thấy màn hình ngoài có hỗ trợ DDC/CI.", systemImage: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Màn hình", selection: $displays.selectedID) {
                        ForEach(displays.targets) { target in Text(target.name).tag(Optional(target.id)) }
                    }
                    if let id = displays.selectedID, let target = displays.targets.first(where: { $0.id == id }) {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                            Slider(value: Binding(get: { target.volume }, set: { displays.setVolume($0, for: id) }), in: 0...1)
                                .disabled(!target.available)
                            Text("\(Int(target.volume * 100))%")
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                            Slider(value: Binding(get: { target.brightness }, set: { displays.setBrightness($0, for: id) }), in: 0...1)
                                .disabled(!target.brightnessAvailable)
                            Text("\(Int(target.brightness * 100))%")
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Text(target.available ? "Kết nối DDC/CI: sẵn sàng" : "Không tìm thấy kết nối DDC/CI tới màn hình")
                            .font(.footnote).foregroundStyle(target.available ? Color.secondary : Color.orange)
                    }
                }
            } header: { Label("Âm lượng màn hình ngoài", systemImage: "display.and.arrow.down") } footer: {
                Text("Phím âm lượng và phím tăng/giảm độ sáng mặc định của Mac sẽ điều khiển màn hình đang chọn. Màn hình cần bật DDC/CI trong menu OSD.")
                    .font(.footnote)
            }

            Section {
                HotkeyEditor(status: $utilities.brightnessUpHotKey,
                             label: "Tăng độ sáng",
                             allowsModifierOnly: false)
                HotkeyEditor(status: $utilities.brightnessDownHotKey,
                             label: "Giảm độ sáng",
                             allowsModifierOnly: false)
            } header: {
                Label("Phím tắt độ sáng tùy chỉnh", systemImage: "sun.max")
            } footer: {
                Text("Bấm vào từng ô rồi nhấn tổ hợp phím bạn muốn. Phím tắt hoạt động toàn hệ thống và điều khiển màn hình DDC/CI đang chọn.")
                    .font(.footnote)
            }

            AZSFanControlSection()

            Section {
                if utilities.mouseDevices.isEmpty {
                    Label("Chưa tìm thấy chuột đang kết nối", systemImage: "computermouse")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(utilities.mouseDevices) { mouse in
                        HStack(spacing: 10) {
                            Image(systemName: "computermouse.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mouse.displayName)
                                if let transport = mouse.transport, !transport.isEmpty {
                                    Text(transport).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let battery = mouse.batteryPercent {
                                Label("\(battery)%", systemImage: batteryIcon(battery))
                                    .monospacedDigit()
                                    .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                            } else {
                                Text("Không có thông tin pin")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AZS Tools đang chạy ngoài thư mục Applications")
                                .font(.footnote)
                            Text("Hãy kéo app vào Applications rồi mở bản đó. Quyền macOS có thể không khớp nếu chạy trực tiếp từ DMG.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !appState.accessibilityGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Bộ gõ chưa có quyền Trợ năng")
                                .font(.footnote)
                            Text("Bật quyền cho đúng ứng dụng AZS Tools trong Cài đặt hệ thống, rồi thoát và mở lại app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mở quyền…") { openAccessibilitySettings() }
                            .buttonStyle(.borderless)
                    }
                }
                if !appState.inputMonitoringGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "keyboard.badge.ellipsis").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Bộ gõ và pin chuột chưa có quyền Input Monitoring")
                                .font(.footnote)
                            Text("Nếu công tắc đã bật nhưng vẫn báo thiếu, dùng dấu “–” xóa mục AZS Tools cũ, rồi dấu “+” thêm đúng app trong Applications.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mở quyền…") { openInputMonitoringSettings() }
                            .buttonStyle(.borderless)
                    }
                } else if appState.accessibilityGranted && !appState.eventTapRunning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "keyboard.badge.exclamationmark").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Đã có quyền nhưng bộ gõ chưa khởi động")
                                .font(.footnote)
                            Text("Xóa rồi thêm lại AZS Tools trong cả hai danh sách quyền, sau đó thoát và mở lại app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if utilities.mouseDevices.contains(where: {
                    ($0.vendorID == 0x046D || $0.vendorID == 0x1532) && $0.batteryPercent == nil
                }) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appState.inputMonitoringGranted
                                 ? "Input Monitoring đã bật nhưng chuột chưa trả lời truy vấn pin"
                                 : "Muốn đọc pin Logitech/Razer, cần quyền Input Monitoring")
                                .font(.footnote)
                            Text(appState.inputMonitoringGranted
                                 ? "Thoát AZS Tools, xóa mục AZS Tools cũ trong cả hai danh sách quyền rồi thêm lại đúng bản /Applications. Mở lại, bấm Quét lại; nếu cần hãy thoát Logi Options+."
                                 : "Sau khi cấp quyền, thoát và mở lại AZS Tools rồi bấm Quét lại chuột.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(appState.inputMonitoringGranted ? "Mở lại cài đặt…" : "Cấp quyền…") {
                            openInputMonitoringSettings()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Quét lại chuột") { utilities.refreshMouseDevices() }
                    .buttonStyle(.borderless)
            } header: { Label("Chuột đang sử dụng", systemImage: "computermouse.and.cursorarrow") }

            Section {
                Toggle("Đảo chiều cuộn toàn hệ thống", isOn: $utilities.reverseScrolling)
                Text("Áp dụng cho chuột, trackpad và mọi ứng dụng. macOS sẽ yêu cầu quyền Trợ năng nếu chưa cấp.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Label("Cuộn chuột", systemImage: "arrow.up.arrow.down") }

            Section {
                ForEach(2...9, id: \.self) { button in
                    VStack(alignment: .leading, spacing: 6) {
                        ActionPicker(title: mouseButtonTitle(button),
                                     action: Binding(get: {
                                         utilities.buttonActions[button] ?? .none
                                     }, set: { newValue in
                                         utilities.buttonActions[button] = newValue
                                         if newValue != .openApplication { utilities.buttonApplications[button] = nil }
                                     }))
                        if utilities.buttonActions[button] == .openApplication {
                            HStack(spacing: 8) {
                                Image(systemName: "app.fill").foregroundStyle(.secondary)
                                if let path = utilities.buttonApplications[button] {
                                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                } else {
                                    Text("Chưa chọn ứng dụng").foregroundStyle(.orange)
                                }
                                Spacer()
                                Button("Chọn…") { chooseApplication(for: button) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
                HStack {
                    if let button = utilities.lastDetectedButton {
                        Label("Vừa nhận Button \(button + 1)", systemImage: "computermouse.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Bấm một nút chuột để xác định số Button.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Mặc định") {
                        utilities.buttonActions = [2: .none, 3: .back, 4: .forward]
                        utilities.buttonApplications = [:]
                    }
                    .buttonStyle(.borderless)
                }
                Text("Có thể gán Button 3–10 cho điều hướng, phím tắt, âm lượng, hệ thống hoặc mở ứng dụng bất kỳ. Thay đổi có hiệu lực ngay lập tức.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Label("Tùy chỉnh phím chuột", systemImage: "computermouse") }

        }
        .settingsFormStyle()
    }

    private func mouseButtonTitle(_ button: Int) -> String {
        switch button {
        case 2: return "Button 3 — Nút giữa"
        case 3: return "Button 4 — Nút Back"
        case 4: return "Button 5 — Nút Forward"
        default: return "Button \(button + 1)"
        }
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ...10: return "battery.0percent"
        case ...35: return "battery.25percent"
        case ...65: return "battery.50percent"
        case ...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInputMonitoringSettings() {
        _ = utilities.requestMouseInputMonitoringAccess()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseApplication(for button: Int) {
        let panel = NSOpenPanel()
        panel.title = "Chọn ứng dụng để mở"
        panel.message = "Ứng dụng sẽ được mở khi bấm nút chuột này."
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            utilities.buttonApplications[button] = url.path
        }
    }
}

private struct AZSBrandMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.cyan, Color.blue, Color.indigo],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                .padding(4)
            Text("A")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: 1)
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
                .offset(x: 11, y: -11)
        }
        .frame(width: 42, height: 42)
        .shadow(color: .blue.opacity(0.3), radius: 6, y: 2)
    }
}

private struct ActionPicker: View {
    let title: String
    @Binding var action: AZSMouseAction
    var body: some View {
        Picker(title, selection: $action) {
            ForEach(AZSMouseAction.allCases) { Text($0.title).tag($0) }
        }
    }
}
