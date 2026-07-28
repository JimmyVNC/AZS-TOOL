//
//  WelcomePage.swift
//  mkey
//

import SwiftUI

struct WelcomePage: View {
    @EnvironmentObject private var state: AppState
    @State private var isPulsing = false
    @State private var didCompleteOnboarding = false

    private var runningFromApplications: Bool {
        let path = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return path.hasPrefix("/Applications/")
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App Icon with a soft shadow and glow
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)
                    .blur(radius: 10)
                
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 66, height: 66)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                } else {
                    Image(systemName: "keyboard")
                    .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Welcome Text
            VStack(spacing: 6) {
                Text("Chào mừng đến với AZS Tools")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Bộ gõ Tiếng Việt hiện đại, an toàn và siêu nhẹ cho macOS.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            // Permissions Instruction Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cần bật hai quyền hệ thống")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        permissionRow("Trợ năng (Accessibility)", granted: state.accessibilityGranted)
                        permissionRow("Giám sát đầu vào (Input Monitoring)", granted: state.inputMonitoringGranted)

                        Text("Bộ gõ cần các quyền này để nhận phím; truy vấn pin Logitech/Razer cần Input Monitoring.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                }

                Divider()

                Text("Sau mỗi bản ad-hoc mới: trong từng mục quyền, dùng dấu “–” xóa AZS Tools cũ, nhấn “+”, chọn đúng /Applications/AZS Tools.app rồi bật lại.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !runningFromApplications {
                    Label {
                        Text("App đang chạy ngoài /Applications. Hãy thoát app, kéo vào Applications rồi mở lại trước khi cấp quyền.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)

                    Text(Bundle.main.bundlePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 32)

            // CTA and Status
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        openAccessibilitySettings()
                    } label: {
                        Label("Trợ năng", systemImage: "figure.wave")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        openInputMonitoringSettings()
                    } label: {
                        Label("Input Monitoring", systemImage: "keyboard")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                Button("Đã thêm lại cả hai quyền — kiểm tra") {
                    refreshPermissionState()
                    NotificationCenter.default.post(name: .mkRecheckAccessibility, object: nil)
                }
                .buttonStyle(.bordered)

                // Pulsing Status Indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .opacity(isPulsing ? 0.3 : 1.0)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                    
                    Text("Đang chờ đủ Accessibility và Input Monitoring...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
            }

            Spacer()
        }
        .frame(width: 480)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBlur(material: .sidebar))
        .ignoresSafeArea()
        .onAppear {
            refreshPermissionState()
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("welcome") == true }) {
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.isMovableByWindowBackground = true
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .onReceive(state.$accessibilityGranted) { _ in
            completeOnboardingIfReady()
        }
        .onReceive(state.$inputMonitoringGranted) { _ in
            completeOnboardingIfReady()
        }
        .onReceive(state.$eventTapRunning) { _ in
            completeOnboardingIfReady()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState()
            NotificationCenter.default.post(name: .mkRecheckAccessibility, object: nil)
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(granted ? Color.green : Color.orange)
    }

    private func refreshPermissionState() {
        state.accessibilityGranted = AXIsProcessTrusted()
        state.inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    private func completeOnboardingIfReady() {
        guard !didCompleteOnboarding,
              state.engineReady else { return }
        didCompleteOnboarding = true
        if let welcomeWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" }) {
            welcomeWindow.close()
        }
        NotificationCenter.default.post(name: .mkOpenSettingsWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAccessibilitySettings() {
        NotificationCenter.default.post(name: .mkRequestAccessibility, object: nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInputMonitoringSettings() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
