# AZS Tools — Bộ gõ tiếng Việt & tiện ích macOS

AZS Tools kết hợp bộ gõ Telex/VNI (engine OpenKey), Clipboard, điều khiển chuột/cuộn/zoom, âm thanh, màn hình và quạt. Yêu cầu macOS 14 trở lên; giao diện SwiftUI hỗ trợ Light/Dark Mode.

## Trải nghiệm mới

- Tổng quan hiển thị quyền, trạng thái bộ gõ, thiết bị và công tắc điều khiển nhanh.
- Cài đặt tách riêng Chuột & cuộn, Âm thanh & màn hình, Phím tắt và Quạt; có tìm kiếm và nhớ trang cuối.
- Clipboard và cài đặt vẫn truy cập được khi bộ gõ chưa đủ quyền.
- Bật/tắt âm thanh và độ sáng độc lập. Khi tắt cả hai, app dừng công việc DDC riêng.
- Slider màn hình cập nhật UI ngay, gộp giá trị chờ theo từng điều khiển và giới hạn retry.
- Preset cuộn Êm/Cân bằng/Nhanh, khôi phục từng nhóm, nhập/xuất cấu hình JSON có phiên bản.
- Chẩn đoán chủ động xuất tại Hệ thống, không chứa văn bản gõ hoặc lịch sử Clipboard.

Xem [kế hoạch](OPTIMIZATION_PLAN.md) và [kết quả triển khai, checklist kiểm thử](OPTIMIZATION_STATUS.md). Các mục tiêu hiệu suất chưa được coi là đạt nếu chưa đo trên thiết bị thực tế.

## Build chuẩn

Project chính là `AZSTools.xcodeproj`, scheme `AZSTools`; sản phẩm `AZS Tools.app`.
Các project `mkey.xcodeproj` và `AZSTools 2/3/4.xcodeproj` là bản cũ, không dùng để build thay đổi này.

Yêu cầu Xcode đã hoàn tất thiết lập ban đầu và license. Có thể build trực tiếp project đã lưu:

```bash
xcodebuild -project AZSTools.xcodeproj -scheme AZSTools -configuration Debug -derivedDataPath build/Debug build
xcodebuild -project AZSTools.xcodeproj -scheme AZSTools -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/Release build
open "build/Release/Build/Products/Release/AZS Tools.app"
```

Khi thay đổi danh sách nguồn, dùng XcodeGen để sinh lại từ `project.yml`:

```bash
xcodegen generate
open AZSTools.xcodeproj
```

File trùng `Sources/App/AZSScrollToZoomEngine 2.swift` được giữ nguyên nhưng loại khỏi build. Helper SMC được build/ký trước khi app được ký. Cấu hình hiện tại dùng chữ ký ad-hoc, chưa phải bản notarized để phân phối.

## Kiểm tra không điều khiển phần cứng

```bash
bash scripts/verify.sh --typecheck
bash scripts/verify.sh --release
bash scripts/verify.sh --tests
AZS_VERIFY_ARCH=x86_64 bash scripts/verify.sh --typecheck
```

Các kiểm thử dùng transport màn hình giả; không bật event tap, không gửi lệnh SMC/DDC, không yêu cầu quyền hệ thống. Các tùy chọn `--release` và `--typecheck` kiểm tra compiler, không thay thế build app đầy đủ bằng Xcode. SDK/toolchain có thể đổi qua `DEVELOPER_DIR`, `AZS_VERIFY_SDK`, `AZS_VERIFY_ARCH`.

## Cài đặt & cấp quyền

1. Kéo `AZS Tools.app` vào Applications và chỉ chạy một bản app.
2. Mở Tổng quan, cấp Trợ năng và Giám sát đầu vào cho đúng app trong System Settings → Privacy & Security.
3. Quay lại app hoặc bấm Kiểm tra lại bộ gõ. Trạng thái chỉ sẵn sàng khi đủ hai quyền và event tap chạy.
4. Chuyển Việt/Anh mặc định bằng **⌥Z**; chỉnh tại Bộ gõ.

Bản ad-hoc sau khi rebuild có thể cần xóa mục quyền cũ và thêm đúng app mới. Không tự động cấp quyền điều khiển quạt; thao tác này do người dùng chủ động thực hiện. Đóng trang quạt chỉ dừng đọc dữ liệu, không đổi chế độ quạt đang áp dụng.

## Cấu hình & dữ liệu

Xuất/nhập tại Hệ thống. File JSON không bao gồm lịch sử Clipboard, nội dung gõ tắt, quyền macOS, login item, iCloud hoặc tốc độ quạt. Các đường dẫn ứng dụng và danh sách app Trợ năng có thể có trong file cấu hình, nên kiểm tra trước khi chia sẻ.

Nâng cấp giữ thiết lập hiện có. Migration Mos v3 có sẵn vẫn đổi tuning của engine cũ về bộ giá trị tương thích; tuning cũ được sao lưu tại key `AZSLegacyScrollTuningBackup`. Khôi phục nhóm Clipboard đặt giới hạn về 30 mục: mục chưa ghim vượt giới hạn có thể bị loại bỏ; mục ghim được giữ lại.

## Cấu trúc

- `Sources/Engine`: engine C++ OpenKey.
- `Sources/Platform`: bridge ObjC++, event tap, SMC, ScrollToZoom.
- `Sources/App`: SwiftUI, controller và cấu hình/chẩn đoán.
- `Sources/Support`: Info.plist, entitlements và assets.
- `Tests/OptimizationChecks.swift`: kiểm thử hồi quy không dùng phần cứng.
- `project.yml`: đặc tả project/scheme chính.

## Giấy phép

Engine và phần glue kế thừa từ OpenKey, phát hành theo **GPL v3**.
Toàn bộ mã mkey (UI SwiftUI, bridge) cũng theo GPL v3.

Phần định tuyến sự kiện và lượng tử delta của **Smooth Scrolling** được triển
khai lại với tham khảo từ [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
(© Noah Nuebling, MMF License); đường cong chuyển động tham khảo
[Mos](https://github.com/Caldis/Mos) của Caldis.

**Scroll to Zoom** dùng trực tiếp cấu trúc module của
[ScrollToZoom](https://github.com/alphaArgon/ScrollToZoom): hard/soft event taps,
state manager, settings, process manager và Magic Mouse support. Swift chỉ đưa
thiết lập của giao diện AZS vào adapter, không tự mô phỏng state machine.
