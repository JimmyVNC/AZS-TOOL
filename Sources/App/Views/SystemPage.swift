//
//  SystemPage.swift
//  mkey
//
//  System integration: login item, dock/menu-bar icon, smart switching.
//

import SwiftUI

struct SystemPage: View {
  @EnvironmentObject private var state: AppState
  @ObservedObject private var updater = UpdateChecker.shared
  @State private var confirmReset = false
  @State private var configurationMessage = ""
  @State private var diagnostics = ""

  var body: some View {
    Form {
      Section("Khởi động") {
        Toggle("Khởi động cùng macOS", isOn: $state.runOnStartup)
        Toggle("Hiện bảng điều khiển khi khởi động", isOn: $state.showUIOnStartup)
      }

      Section("Cập nhật") {
        Toggle(
          "Tự động kiểm tra cập nhật khi khởi động",
          isOn: Binding(
            get: { updater.autoCheckEnabled },
            set: { updater.autoCheckEnabled = $0 }))

        HStack(spacing: 8) {
          Image(systemName: updateIcon)
            .foregroundStyle(updateIconColor)
          Text(updateStatusText)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Spacer()
          if case .checking = updater.status {
            ProgressView().controlSize(.small)
          } else {
            Button("Kiểm tra ngay") {
              Task { await updater.check(manual: true) }
            }
          }
        }

        if case .available(let info) = updater.status {
          HStack {
            Text("Phiên bản \(info.version) đã sẵn sàng.")
            Spacer()
            Button("Xem bản mới") { updater.openReleasePage(info) }
              .buttonStyle(.borderedProminent)
          }
        }
      }

      Section("Biểu tượng") {
        Toggle("Biểu tượng đơn sắc trên thanh menu", isOn: $state.grayIcon)
        Toggle("Hiện biểu tượng ở Dock", isOn: $state.showIconOnDock)
      }

      Section("Chuyển chế độ thông minh") {
        Toggle("Tự nhớ chế độ gõ theo từng ứng dụng", isOn: $state.useSmartSwitchKey)
        Toggle("Tự nhớ bảng mã theo từng ứng dụng", isOn: $state.rememberCode)
      }

      Section("Tương thích nâng cao") {
        Toggle("Gửi phím từng bước (chậm nhưng tương thích cao)", isOn: $state.sendKeyStepByStep)
        Toggle("Tương thích bố cục bàn phím khác QWERTY", isOn: $state.performLayoutCompat)
      }

      Section {
        HStack {
          Button("Xuất cấu hình…") {
            performConfiguration("Đã xuất cấu hình") { try AZSConfigurationFile.exportSettings() }
          }
          Button("Nhập cấu hình…") {
            performConfiguration("Đã áp dụng cấu hình") {
              try AZSConfigurationFile.importSettings()
            }
          }
        }
        Text(
          "Chỉ gồm thiết lập. Lịch sử Clipboard, dữ liệu gõ tắt, quyền hệ thống và tốc độ quạt không nằm trong file cấu hình."
        )
        .font(.footnote).foregroundStyle(.secondary)
        if !configurationMessage.isEmpty {
          Text(configurationMessage).font(.footnote).textSelection(.enabled)
        }
      } header: {
        Text("Sao lưu cấu hình")
      }

      Section {
        HStack {
          Button("Đọc trạng thái") { diagnostics = AZSConfigurationFile.diagnosticReport() }
          Button("Xuất chẩn đoán…") {
            performConfiguration("Đã xuất chẩn đoán") {
              try AZSConfigurationFile.exportDiagnostics()
            }
          }
        }
        if !diagnostics.isEmpty {
          Text(diagnostics).font(.caption.monospaced()).textSelection(.enabled)
        }
        Text(
          "Báo cáo chỉ gồm trạng thái và số liệu hoạt động; không chứa nội dung phím gõ hoặc Clipboard."
        )
        .font(.footnote).foregroundStyle(.secondary)
      } header: {
        Text("Chẩn đoán")
      }

      Section {
        HStack {
          Text("Khôi phục toàn bộ cài đặt về mặc định.")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Cài đặt mặc định", role: .destructive) {
            confirmReset = true
          }
        }
      }
    }
    .settingsFormStyle()
    .confirmationDialog(
      "Bạn có chắc chắn muốn thiết lập lại cấu hình mặc định?",
      isPresented: $confirmReset, titleVisibility: .visible
    ) {
      Button("Khôi phục mặc định", role: .destructive) {
        state.resetToDefaults()
      }
      Button("Huỷ", role: .cancel) {}
    } message: {
      Text(
        "Thiết lập Clipboard trở về giới hạn 30 mục; mục chưa ghim vượt giới hạn có thể bị loại bỏ. Không xóa dữ liệu gõ tắt hoặc đổi chế độ quạt."
      )
    }
  }

  private func performConfiguration(_ success: String, action: () throws -> Bool) {
    do { if try action() { configurationMessage = success } } catch {
      configurationMessage = error.localizedDescription
    }
  }

  private var updateStatusText: String {
    switch updater.status {
    case .idle: return "Phiên bản hiện tại \(updater.currentVersion)."
    case .checking: return "Đang kiểm tra cập nhật…"
    case .upToDate: return "Bạn đang dùng bản mới nhất (\(updater.currentVersion))."
    case .available(let info): return "Đã có bản \(info.version)."
    case .failed(let msg): return msg
    }
  }

  private var updateIcon: String {
    switch updater.status {
    case .available: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle"
    case .upToDate: return "checkmark.circle"
    default: return "arrow.triangle.2.circlepath"
    }
  }

  private var updateIconColor: Color {
    switch updater.status {
    case .available: return .accentColor
    case .failed: return .orange
    default: return .secondary
    }
  }
}
