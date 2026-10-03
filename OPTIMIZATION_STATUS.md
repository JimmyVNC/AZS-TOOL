# Kết quả triển khai tối ưu AZS Tools

Ngày: 03/10/2026. Project chuẩn: `AZSTools.xcodeproj`, scheme `AZSTools`.

Đã triển khai phần thay đổi mã nguồn chính của kế hoạch. Chưa nghiệm thu phát
hành hoặc chứng minh các mục tiêu CPU/độ trễ/bộ nhớ; cần chạy checklist thực tế
bên dưới. Không thay engine C++ gõ tiếng Việt và không tự động thay app đã cài.

## Đã triển khai

| Nhóm | Thay đổi |
| --- | --- |
| Giao diện | Tổng quan, trang tiện ích tách riêng, tìm kiếm cài đặt, nhớ trang cuối, nhãn slider/selection hỗ trợ VoiceOver |
| Quyền | Mở cài đặt và Clipboard độc lập với quyền bộ gõ; trạng thái Trợ năng/Input Monitoring/event tap riêng; hướng dẫn ad-hoc mở rộng |
| Thao tác nhanh | Công tắc Clipboard, cuộn, zoom, âm thanh, độ sáng; lối vào màn hình trực tiếp từ menu |
| Phản hồi | Kết quả chuyển mã bằng HUD không kích hoạt cửa sổ hoặc thông báo nội tuyến; cập nhật mới hiển thị trong menu thay vì hộp thoại modal |
| Cấu hình module | Lưu riêng từng thay đổi; debounce 80 ms cho cấu hình cuộn/zoom; batch reset/preset/import; gán nút chuột không cấu hình lại cuộn/zoom |
| Màn hình | Một scan đang chạy; queue sở hữu DDC services; giữ một giá trị chờ mới nhất/điều khiển; debounce 60 ms và flush khi thả slider; tối đa một batch đang ghi |
| Retry/kết nối | Retry một lần sau refresh; bỏ retry đã bị input mới thay thế; token phiên bỏ kết quả cũ khi sleep/đổi kết nối; lựa chọn màn hình theo UUID |
| Bật/tắt | Tắt module hủy công việc chờ tương ứng; tắt cả hai dừng scan riêng; phím media được trả về xử lý mặc định; giữ điều chỉnh chờ của nhóm còn bật |
| Quạt | Đọc/lệnh/helper ở queue nền; timeout socket 2,5 giây; xác thực qua process riêng, tối đa 60 giây; chờ helper khởi động có deadline; UI sở hữu timer; sleep vô hiệu job cũ |
| Clipboard | Truy cập pasteboard ở main actor; mã hóa/ghi PNG và lưu JSON ở queue riêng; gộp lưu 80 ms; token chặn kết quả sau tắt/xóa/sleep; giữ mục ghim |
| Shortcut | Đăng ký tăng dần; lỗi Carbon/xung đột xuất hiện trong UI; kiểm tra lại khi phím bộ gõ đổi; giữ trạng thái tạm ngưng khi ghi tổ hợp phím |
| Vòng đời | Start idempotent; bỏ quét DDC wake trùng; health check 5 giây với backoff tối đa 30 giây; kiểm tra quyền khi app active không restart tap đang khỏe |
| Hoàn thiện | Preset Êm/Cân bằng/Nhanh; reset từng nhóm; JSON schema v1 có validation trước mutation; chẩn đoán chủ động xuất không chứa nội dung gõ/Clipboard |
| Build | README/CONTRIBUTING thống nhất project chính; shared scheme; loại source Swift trùng khỏi build; script kiểm tra và regression checks |

Lệnh phần cứng đã bắt đầu chạy không thể được thu hồi giữa system call. Token
hủy các lệnh chưa bắt đầu và bỏ kết quả cũ; cần kiểm chứng tình huống hot-plug
và thiết bị không phản hồi trên phần cứng thực tế.

## Nâng cấp và dữ liệu

- Schema mới không xóa UserDefaults cũ. Trang `utilities` được chuyển sang `mouse`.
- Giữ migration nút chuột/brightness shortcut đã có. Mos v3 vẫn dùng bộ tuning
  tương thích với engine hiện tại; tuning trước migration được sao lưu trong
  `AZSLegacyScrollTuningBackup`, và giá trị mới được lưu nhất quán qua lần mở sau.
- Import JSON giới hạn 1 MB, kiểm tra version, key cho phép, số hữu hạn/range,
  button/slot và đường dẫn `.app` trước khi đổi thiết lập.
- File cấu hình không chứa lịch sử Clipboard, nội dung macro, chế độ quạt,
  quyền macOS, login item hoặc lựa chọn iCloud. Đường dẫn app vẫn có thể chứa
  tên tài khoản; kiểm tra trước khi chia sẻ file cấu hình.
- Reset Clipboard/toàn bộ đưa cap về 30 mục; mục chưa ghim vượt cap có thể bị
  loại bỏ. UI có thông báo về tác dụng này; không xóa mục ghim hoặc dữ liệu macro.

## Kiểm chứng tự động

Môi trường build: Xcode 27.0, SDK macOS 27.0, deployment target macOS 14.

- Full Swift typecheck cho `arm64` và `x86_64`.
- Biên dịch Swift Release `-O -whole-module-optimization`.
- Build đầy đủ Debug và Release bằng project/scheme chính; Release universal
  `arm64 + x86_64`, gồm helper SMC.
- Chữ ký ad-hoc app/helper kiểm tra bằng `codesign --verify --deep --strict`.
- 23 assertion hồi quy dùng mock transport, không yêu cầu TCC hoặc gửi lệnh
  tới màn hình/quạt. Bao gồm gộp 101 slider events, độc lập điều khiển,
  bật/tắt từng nhóm/cả hai, NaN/Infinity, sleep, retry giới hạn, input mới thay
  retry cũ, JSON round-trip và validation, migration idempotent, xung đột
  shortcut và token vòng đời.

Chạy lại:

```bash
bash scripts/verify.sh --tests
bash scripts/verify.sh --typecheck
AZS_VERIFY_ARCH=x86_64 bash scripts/verify.sh --typecheck
bash scripts/verify.sh --release
```

Script giữ artifact trong thư mục tạm và in đường dẫn. Build đầy đủ xem README.
Các cảnh báo deprecation từ IOKit/AppKit nguồn cũ vẫn còn; không phải bằng
chứng về khả năng tương thích runtime trên macOS 14 hoặc máy Intel thực tế.

## Checklist nghiệm thu còn lại

- [ ] Chạy bản mới từ Applications, chỉ một instance; xác nhận không crash khi
  mở menu/cài đặt và nhập/chuyển trang ở kích thước tối thiểu.
- [ ] Kiểm thử Light/Dark, Tab/Shift-Tab và VoiceOver; rà soát HUD lỗi dài,
  trợ giúp quyền và trạng thái đang áp dụng/không hỗ trợ.
- [ ] Thiếu/tắt lại từng quyền: cài đặt/Clipboard vẫn dùng được; bộ gõ không
  báo sẵn sàng sai; cấp quyền rồi quay lại không restart tap đang khỏe.
- [ ] Hồi quy Telex/VNI, bảng mã, macro, Việt/Anh, chuyển mã; Safari, Chromium,
  Finder, editor và ứng dụng dùng Accessibility.
- [ ] Chuột USB/Bluetooth, trackpad, cuộn native khi chưa có quyền, preset,
  zoom, giữ/capture shortcut và thay nút chuột trong lúc cuộn.
- [ ] Màn hình tích hợp/ngoài/nhiều màn hình/chỉ ghi được/không DDC; kéo nhanh,
  rút-cắm, đổi màn hình chính, bật/tắt trong lúc ghi và khôi phục lựa chọn UUID.
- [ ] Helper quạt timeout hoặc từ chối xác thực không treo UI; đóng trang/menu
  dừng đọc nhưng không đổi fan mode; trả auto khi người dùng chọn.
- [ ] Clipboard văn bản/ảnh/file/dữ liệu lớn; mục ghim, xóa/tắt trong lúc tạo
  thumbnail, không lưu nguồn nhạy cảm, thoát/mở lại giữ đúng thứ tự.
- [ ] Export/import toàn bộ thiết lập thật, config lỗi không gây mutation;
  reset từng nhóm không ảnh hưởng nhóm khác và không làm mất dữ liệu ngoài cap.
- [ ] 20 vòng sleep/wake, 100 lần mở/đóng picker và menu: timer không tăng,
  không mất bộ gõ/cuộn; module tắt không phát sinh công việc riêng.
- [ ] macOS 14 và macOS mới; máy Apple silicon và máy Intel thực tế.

## Đo hiệu suất trước phát hành

So sánh cùng máy, cùng quyền/thiết bị, cùng nội dung Clipboard và cấu hình.
Ghi bản cũ/bản mới, dùng Instruments Time Profiler/Allocations và Energy Log
nếu có trong bộ công cụ; không suy ra mức giảm CPU từ số dòng code đã thay.

| Chỉ tiêu | Cách ghi nhận | Trạng thái |
| --- | --- | --- |
| Startup | `startup.toInputReady` trong chẩn đoán; ghi rõ có bao gồm thời gian người dùng cấp quyền | Chưa đo thực tế |
| Callback | `input.utilityCallback.sampled`: một mẫu/64 callback, tối đa 256 mẫu; chỉ phần utility Swift, không toàn engine | Chưa đo thực tế |
| Menu/cài đặt/picker | Đo 30 lần mở sau warmup, p95; mục tiêu ban đầu <200 ms | Chưa đo thực tế |
| CPU idle/wakeup | 5 phút idle, cùng module/thiết bị; mục tiêu CPU trung bình <1% | Chưa đo thực tế |
| Bộ nhớ | So sánh RSS/allocations với cùng dataset, sau 100 lần mở/đóng picker | Chưa đo thực tế |
| Device queues | Chẩn đoán scan/write/configure/pending/in-flight và polling; đối chiếu với thao tác thực tế | Mock đã kiểm chứng, cần phần cứng |

Những việc chưa làm: benchmark baseline/post-change, QA toàn ma trận, mục tiêu
âm thanh/độ sáng tách riêng (kế hoạch đặt điều kiện theo nhu cầu), kiểm thử
runtime Intel/macOS 14 và ký Developer ID/notarize/đóng gói bản phân phối.
