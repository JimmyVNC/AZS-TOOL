# AZS Tools

**AZS Tools** là bộ tiện ích all-in-one cho macOS, đặc biệt tối ưu cho người dùng **Mac mini**. Tích hợp bộ gõ tiếng Việt, điều khiển màn hình DDC/CI, quạt tản nhiệt và quản lý chuột Bluetooth trong một ứng dụng duy nhất.

> Yêu cầu: macOS 26 (Tahoe) trở lên · Apple Silicon

---

## Tính năng

### 🖥️ Điều khiển màn hình ngoài (DDC/CI)
- Chỉnh **âm lượng** và **độ sáng** màn hình ngoài trực tiếp từ app
- Hỗ trợ màn hình có DDC/CI — không cần chạm vào nút vật lý
- Phím tắt tùy chỉnh để tăng/giảm nhanh

### 🌀 Fan Control
- Xem tốc độ quạt hệ thống realtime (RPM)
- Điều chỉnh thủ công hoặc để chế độ tự động theo AppleSMC

### 🖱️ Quản lý chuột Bluetooth
- Xem thiết bị chuột đang kết nối và mức pin
- Tùy chỉnh nút chuột (Button 3, Button 4...)
- Đảo chiều cuộn toàn hệ thống

### ⌨️ Bộ gõ tiếng Việt (tích hợp từ mkey / OpenKey)
- Hỗ trợ Telex, VNI và nhiều bảng mã
- Gõ tắt, chuyển mã, smart switch
- MenuBarExtra hiển thị trạng thái VI/EN
- Khởi động cùng macOS

---

## Cài đặt

1. Tải bản mới nhất tại [Releases](https://github.com/JimmyVNC/AZS-TOOL/releases)
2. Kéo `AZSTools.app` vào thư mục **Applications**
3. Mở app — cấp quyền **Trợ năng (Accessibility)** khi được yêu cầu:
   `System Settings → Privacy & Security → Accessibility → bật AZS Tools`

> **Lưu ý:** App được ký ad-hoc (không có Apple Developer ID). Nếu macOS chặn, vào `System Settings → Privacy & Security` và bấm **Open Anyway**.

---

## Build từ source

Yêu cầu: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)


```

---

## Tại sao cần AZS Tools?

Mac mini không có nút âm lượng hay độ sáng vật lý. Thông thường bạn phải:
- Vào System Settings để chỉnh màn hình
- Cài riêng **MonitorControl** cho DDC/CI
- Cài riêng **Macs Fan Control** cho quạt
- Cài riêng app bộ gõ tiếng Việt

**AZS Tools gộp tất cả vào một chỗ** — tiết kiệm RAM, gọn hơn, ít icon menu bar hơn.

---

## Credit

- Bộ gõ tiếng Việt sử dụng engine từ [OpenKey](https://github.com/tuyenvm/OpenKey) © Tuyen Mai (GPL v3)
- UI bộ gõ tham khảo từ [mkey](https://github.com/JimmyVNC/AZS-TOOL) — xây dựng lại bằng SwiftUI

---

## Giấy phép

Phát hành theo **GPL v3** — xem [LICENSE](LICENSE) để biết thêm chi tiết.
