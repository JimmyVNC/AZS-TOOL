# AZS Tools — Mouse Jitter & MOS Stability Fix

## Tổng quan

Bản cập nhật này tập trung xử lý hiện tượng chuột bị giật nhẹ hoặc phản hồi không đều sau khi AZS Tools chạy lâu, đặc biệt khi bật đồng thời MOS, Scroll to Zoom, Fan Control và các tiện ích chuột.

## Các lỗi đã sửa

- MOS không còn chạy `CVDisplayLink` liên tục khi đang idle.
- MOS chỉ khởi động bộ dựng frame khi nhận wheel event thật và dừng sau khi gesture kết thúc.
- Tái sử dụng poster giữa các gesture theo cấu trúc của source Mos, giảm việc tạo lại display link.
- Đưa các lệnh đọc AppleSMC/Fan Control ra khỏi main thread để không chặn event tap của chuột.
- Bỏ tác vụ quét Bluetooth/HID định kỳ 30 giây vốn có thể làm gián đoạn chuột không dây.
- Vẫn giữ nút quét thiết bị thủ công trong giao diện Utilities.
- Giữ nguyên cơ chế fail-open: nếu không thể tạo event thay thế, event wheel gốc được chuyển tiếp thay vì bị nuốt.
- MOS tạo `CGEvent` cuộn mới cho từng frame, không sao chép IOHID payload hoặc mouse delta ẩn từ wheel event vật lý.
- Queue phát frame dùng QoS `userInitiated` và mailbox giới hạn 4 frame; frame motion chỉ được gộp/bỏ khi consumer bị nghẽn.
- Frame motion cũ quá 50 ms và phase frame cũ quá 150 ms được loại bỏ để không phát lại backlog trễ.
- `gestureSerial` ngăn callback kết thúc cũ reset gesture vừa bắt đầu.
- Event tap chung không còn bắt `leftMouseDragged`/`rightMouseDragged`, giảm tải khi kéo thả.
- Có diagnostics nội bộ cho frame phát/gộp/bỏ, queue depth, thời gian post và số lần display link start/stop.
- Callback `CVDisplayLink` chỉ đánh tín hiệu; state machine và render chạy trên worker `userInitiated` có cơ chế single-flight.
- MOS chỉ start khi có wheel event thật. Di chuyển chuột bình thường không start, reset hoặc đi qua MOS.
- Frame momentum dùng `CGEvent` mới hoàn toàn và post ở session boundary tương thích trình duyệt; không mang IOHID payload hoặc mouse delta ẩn.
- Khi giữ modifier zoom, MOS nhường wheel vật lý cho Scroll to Zoom; thả modifier sẽ quay lại cuộn MOS.
- Nội suy và curve filter được chuẩn hóa theo elapsed time để giữ cảm giác tương đương trên màn hình 60 Hz và 120 Hz.
- Thời gian gesture: theo dõi wheel 180 ms, xác nhận momentum-end 130 ms và dừng an toàn sau 250 ms không có output.
- Synthetic scroll không ép lại `event.location` cũ; mỗi frame dùng vị trí con trỏ hiện tại để tránh kéo con trỏ về điểm bắt đầu gesture.
- Scroll to Zoom bỏ qua synthetic MOS frame ở soft tap khi không giữ modifier, giảm callback main-thread trong momentum.

## Tương thích

- macOS 14 trở lên
- Apple Silicon arm64
- Chuột Bluetooth, chuột receiver USB và chuột có HID++
- Ứng dụng cuộn trong app AZS và các ứng dụng khác

## Tải bản cài đặt

Tải file DMG trong phần **Releases** của repository:

```text
AZS-Tools-MOS-Pointer-Smooth-v4.dmg
```

## Cài đặt

1. Thoát hoàn toàn AZS Tools đang chạy.
2. Mở file DMG.
3. Kéo `AZS Tools.app` vào thư mục `Applications` và chọn **Replace**.
4. Mở lại ứng dụng.
5. Nếu macOS yêu cầu, cấp lại quyền tại:
   **System Settings → Privacy & Security → Accessibility**
   và **Input Monitoring**.

> Bản build ad-hoc có thể được macOS coi là một ứng dụng mới sau mỗi lần build. Khi đó cần xoá mục AZS Tools cũ trong Accessibility/Input Monitoring rồi thêm lại bản mới.

## Kiểm tra checksum

SHA-256 của file DMG:

```text
940a4b77e7142681848018ec3e4146b1f70bb041cb705ec4a177830acf58894a
```

Kiểm tra trên macOS:

```bash
shasum -a 256 AZS-Tools-MOS-Pointer-Smooth-v4.dmg
```

## Kiểm tra build

- Debug build: thành công
- Release build: thành công
- DMG: checksum hợp lệ
- App bundle: code signature hợp lệ
- Bundle version: `1.5.6 (21)`

## Ghi chú kỹ thuật

Luồng MOS được đối chiếu với [Mos](https://github.com/Caldis/Mos). Phần Scroll to Zoom tiếp tục sử dụng cấu trúc event tap/state manager của [ScrollToZoom](https://github.com/alphaArgon/ScrollToZoom). Bản hiện tại giữ callback display-link tối thiểu, worker single-flight, nội suy theo thời gian, session post tương thích và location hiện tại của con trỏ để tránh jitter.

## License

Xem [README.md](README.md) và [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) để biết thông tin giấy phép và các dự án tham khảo.
