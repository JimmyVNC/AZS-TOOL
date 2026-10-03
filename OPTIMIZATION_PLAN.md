# Kế hoạch tối ưu AZS Tools

Ngày lập: 03/10/2026. Phạm vi: trải nghiệm sử dụng, độ ổn định và hiệu suất của app macOS hiện tại.

Cập nhật triển khai: xem `OPTIMIZATION_STATUS.md` để biết các thay đổi đã có,
kiểm thử đã chạy và những mục nghiệm thu còn cần thiết bị thực tế. Phần phân
tích dưới đây mô tả baseline mã nguồn trước khi triển khai, không phải lỗi còn
tồn tại của bản mới.

Đây là kế hoạch dựa trên việc đọc mã nguồn; chưa đo hiệu suất thực tế. Các chỉ tiêu dưới đây là mục tiêu cần kiểm chứng, không phải kết quả đã đạt. Các nút bật/tắt âm thanh và độ sáng đã được bổ sung ở lượt trước; cần kiểm thử tích hợp trước khi phát hành.

## 1. Mục tiêu và nguyên tắc

- Người dùng tìm được chức năng thường dùng trong tối đa hai thao tác từ menu thanh trạng thái.
- Gõ tiếng Việt và cuộn chuột phản hồi ổn định khi mở cài đặt, xử lý Clipboard và điều khiển thiết bị.
- Chỉ chạy tác vụ nền cần thiết; tắt tính năng phải dừng công việc riêng của tính năng đó.
- Hiển thị riêng trạng thái cấu hình, quyền truy cập, kết nối thiết bị và hoạt động thực tế.
- Giữ thiết lập cũ qua nâng cấp; mỗi đợt thay đổi có thể kiểm thử và quay lại độc lập.

## 2. Những điểm đã xác định trong mã nguồn

| Điểm hiện tại | Hệ quả cần xử lý | Vị trí |
| --- | --- | --- |
| `UtilitiesPage` gom shortcut, ứng dụng, màn hình, quạt, pin chuột, cuộn và zoom | Trang dài; chức năng hay dùng khó tìm | `Sources/App/Views/UtilitiesPage.swift` |
| `MenuContent` và `openSettingsWindow()` phụ thuộc `engineReady` | Khi bộ gõ chưa đủ quyền, nhiều tiện ích độc lập không được hiển thị/truy cập từ luồng mở cài đặt | `Sources/App/MkeyApp.swift` |
| Nhiều thuộc tính gọi chung `saveAndRestart()` | Một thay đổi gán nút chuột cũng lưu và cấu hình lại cả nhóm cuộn/zoom | `Sources/App/AZSUtilityController.swift` |
| Mỗi thay đổi slider đưa một lệnh DDC vào queue; lỗi ghi tạo refresh và retry theo thời gian cố định | Có thể tồn đọng giá trị cũ, quét lặp và cập nhật UI sai thứ tự | `Sources/App/DDC/AZSDisplayController.swift` |
| Wake được xử lý ở cả delegate và display controller | Có thể quét màn hình nhiều lần cho cùng một sự kiện | `Sources/App/MkeyApp.swift`, `Sources/App/DDC/AZSDisplayController.swift` |
| Đọc quạt đã chạy ở queue riêng nhưng một số thao tác ghi/helper còn đồng bộ; event tap ở main run loop | Có nguy cơ làm chậm giao diện và xử lý đầu vào khi helper/thiết bị chậm | `Sources/App/AZSFanController.swift`, `Sources/Platform/MKBridge.mm` |
| Fan timer 2 giây có cả `start/stop` từ UI và khởi động từ delegate | Quyền sở hữu vòng đời chưa rõ; cần thống nhất khi đóng trang và mở menu | `Sources/App/AZSFanController.swift`, `Sources/App/MkeyApp.swift` |
| Clipboard polling 0,25 giây; có ghi PNG và mã hóa danh sách trên main actor | Cần đo và tách xử lý nặng khi copy ảnh hoặc nhiều nội dung | `Sources/App/Clipboard/ClipboardManager.swift` |
| Kết quả `RegisterEventHotKey` chưa được đưa ra UI | Shortcut có thể nhìn như đã lưu nhưng đăng ký thất bại | `Sources/App/Clipboard/GlobalHotKey.swift` |
| Có nhiều Xcode project và README vẫn hướng dẫn mkey | Dễ build nhầm target hoặc dùng sai hướng dẫn cài đặt | `project.yml`, `README.md`, các `.xcodeproj` |

Cuộn mượt đã dừng display link khi không có cử chỉ; quét pin chuột đã chuyển khỏi main thread và không chạy định kỳ. Giữ các tối ưu này và đo trước khi thay đổi tiếp.

## 3. Lộ trình triển khai

### Đợt 0 — Thiết lập số liệu nền và build chuẩn

1. Xác định một project/scheme chính dựa trên `project.yml`; đồng bộ README với AZS Tools và phiên bản hỗ trợ.
2. Hoàn tất thiết lập Xcode, build Debug và Release, chạy thử bản hiện tại. Lượt trước `xcodebuild` bị chặn bởi yêu cầu chấp nhận license; cần kiểm tra lại trạng thái trước khi build.
3. Đo startup đến khi bộ gõ sẵn sàng, thời gian mở menu/cài đặt/Clipboard, CPU idle, bộ nhớ và số lần wakeup.
4. Đo độ trễ xử lý đầu vào, số lần cấu hình lại cuộn/zoom, lệnh DDC, scan HID và timer đang hoạt động.
5. Chẩn đoán chỉ ghi thời gian, mã lỗi và trạng thái module; không ghi nội dung phím gõ hoặc Clipboard.

Đầu ra: số liệu nền, danh sách lỗi tái hiện được và đường build ổn định. Không đổi engine gõ trước khi có bài kiểm tra hồi quy.

### Đợt 1 — Thao tác dễ tìm và trạng thái dễ hiểu

1. Bổ sung trang Tổng quan: chế độ Việt/Anh, module đang bật, quyền còn thiếu, thiết bị kết nối và lối vào chức năng chính.
2. Tách Tiện ích thành Chuột & cuộn, Âm thanh & màn hình, Phím tắt và Quạt; giữ các trang Bộ gõ, Clipboard, Gõ tắt, Chuyển mã và Hệ thống.
3. Menu thanh trạng thái có nhóm điều khiển nhanh: Việt/Anh, Clipboard, cuộn mượt, âm thanh, độ sáng. Nhớ trang cài đặt cuối cùng.
4. Cho phép mở cài đặt và dùng chức năng độc lập khi bộ gõ thiếu quyền. Chỉ khóa phần cần quyền; mỗi phần nêu lý do và nút mở đúng mục cài đặt.
5. Hướng dẫn cấp quyền theo từng bước; trạng thái chờ đổi đúng theo quyền còn thiếu hoặc event tap chưa chạy. Nội dung xử lý bản ad-hoc nằm trong phần trợ giúp mở rộng.
6. Giữ toggle và thanh chỉnh gần nhau. Phân biệt “Đã tắt”, “Chưa cấp quyền”, “Không hỗ trợ”, “Mất kết nối”, “Đang áp dụng”, “Áp dụng thất bại”.
7. Thêm tìm kiếm cài đặt; gom tùy chọn kỹ thuật vào phần Nâng cao; hỗ trợ điều hướng bàn phím và nhãn VoiceOver.
8. Thay thông báo cập nhật/chuyển mã thành phản hồi nhẹ khi phù hợp, giảm hộp thoại làm gián đoạn công việc.

Nghiệm thu: tìm và bật/tắt chức năng thường dùng trong hai thao tác từ menu; vẫn mở cài đặt và Clipboard khi bộ gõ thiếu quyền; không có trạng thái “sẵn sàng” sai.

### Đợt 2 — Giảm độ trễ và công việc lặp

1. Tách lưu cấu hình chuột, cuộn, zoom và shortcut. Chỉ áp dụng module có giá trị thay đổi; gom thao tác đặt nhiều giá trị mặc định thành một lần cập nhật.
2. Khi kéo slider, cập nhật hiển thị ngay; gom lệnh thiết bị theo màn hình và loại lệnh, luôn giữ giá trị mới nhất. Bắt đầu thử với khoảng 50–100 ms, điều chỉnh theo số đo và thiết bị; gửi giá trị cuối khi thả slider.
3. Mỗi module thiết bị chỉ có một scan đang chạy; gom yêu cầu trùng, gắn phiên kết nối để bỏ kết quả cũ sau disconnect/sleep.
4. DDC service chỉ được đọc/ghi trên queue sở hữu; kết quả UI về main actor. Retry có giới hạn, bỏ lệnh cũ đã bị thay thế và tránh refresh cho từng lỗi ghi.
5. Đưa lệnh SMC/helper và việc chờ phản hồi ra khỏi main thread; thêm timeout, trạng thái đang thực hiện và khả năng phục hồi khi helper không trả lời.
6. Giữ truy cập pasteboard trên main actor; chuyển mã hóa/ghi ảnh/lưu lịch sử sang queue riêng. Bảo đảm thứ tự bản lưu, không hồi sinh mục đã xóa và không ghi kết quả sau khi Clipboard bị tắt.
7. Shortcut chỉ đăng ký lại những mục thay đổi; trả lỗi đăng ký về UI, kiểm tra trùng trong app và giữ trạng thái tạm ngưng khi đang ghi tổ hợp phím.

Nghiệm thu: đổi gán nút chuột không cấu hình lại cuộn/zoom; kéo slider nhanh kết thúc ở giá trị cuối, không tiếp tục chạy các giá trị cũ; helper timeout không treo UI; copy ảnh không làm gián đoạn gõ.

### Đợt 3 — Vòng đời ổn định và tiết kiệm tài nguyên

1. Mỗi module có vòng đời rõ: tắt, thiếu quyền, đang khởi động, đang chạy, tạm dừng, lỗi. Gọi start/stop nhiều lần không tạo timer hoặc observer dư.
2. Thống nhất xử lý sleep/wake và thay đổi màn hình: một nơi điều phối, mỗi module phục hồi một lần, retry theo trạng thái kết nối.
3. Tạm dừng polling khi sleep. Tần suất đọc quạt tùy nhu cầu: nhanh khi hiển thị, chậm khi cần theo dõi nền; dừng phần đọc không cần thiết. Không đổi chế độ điều khiển quạt chỉ vì đóng UI.
4. Khi tắt cả âm thanh và độ sáng, bỏ scan/read/write riêng của nhóm này; hủy lệnh chưa chạy và giữ lựa chọn thiết bị để bật lại thuận tiện.
5. Kiểm tra quyền khi app hoạt động trở lại và khi có tín hiệu lỗi; điều chỉnh health timer với backoff khi liên tục không phục hồi được. Duy trì đường phát hiện event tap hỏng âm thầm.
6. Lưu màn hình theo định danh ổn định phù hợp, có fallback khi rút màn hình; lựa chọn mục tiêu âm thanh và độ sáng riêng nếu nhu cầu thực tế yêu cầu.
7. Khởi tạo phần đọc thiết bị phụ sau đường khởi động bộ gõ, tùy module được bật; không trì hoãn bộ gõ để chờ HID/DDC/SMC.

Nghiệm thu: sleep/wake hoặc mở/đóng trang nhiều lần không tăng số timer; tắt module dừng công việc riêng; giữ hành vi cuộn native khi đường thay thế không sẵn sàng.

### Đợt 4 — Hoàn thiện và kiểm thử phát hành

1. Preset cuộn dễ hiểu như Êm, Cân bằng, Nhanh; giữ cấu hình tự chỉnh. Đặt tên tùy chọn theo tác dụng thay vì thông số engine.
2. Khôi phục từng nhóm và xuất/nhập cấu hình có phiên bản; không đưa lịch sử Clipboard vào bản xuất cấu hình mặc định.
3. Trang chẩn đoán hiển thị module, quyền, thiết bị và lỗi gần nhất; báo cáo được người dùng chủ động xuất.
4. Di chuyển cấu hình có phiên bản và test nâng cấp từ bản cũ; kiểm tra reset bao phủ các thuộc tính mới.
5. Giữ hỗ trợ màn hình DDC chỉ ghi được; báo rõ giá trị đã yêu cầu so với giá trị thiết bị xác nhận khi không đọc được.

Nghiệm thu: config cũ không mất sau nâng cấp; reset theo nhóm không ảnh hưởng nhóm khác; lỗi thiết bị có hành động khắc phục cụ thể.

## 4. Chỉ tiêu đề xuất

| Chỉ tiêu | Mục tiêu ban đầu |
| --- | --- |
| Mở menu/cài đặt đã khởi tạo | Phản hồi ở phân vị 95 dưới 200 ms trên máy kiểm thử |
| Xử lý callback đầu vào | Đo p95/p99; mục tiêu p95 dưới 2 ms, không chạy disk I/O hoặc chờ process trong callback |
| CPU idle | Mục tiêu dưới 1% trung bình trong 5 phút ở cấu hình mặc định; ghi rõ máy và cách đo |
| Điều khiển thiết bị | Queue không tăng theo số sự kiện slider; giá trị cuối không bị lệnh cũ ghi đè |
| Tính năng bị tắt | Không còn scan/write/timer riêng, trừ công việc dùng chung cần cho module còn bật |
| Hồi phục vòng đời | Qua 20 chu kỳ sleep/wake và mở/đóng trang, không rò timer/observer và không mất bộ gõ/cuộn |
| Bộ nhớ | So sánh trước/sau với cùng dữ liệu Clipboard; không tăng liên tục qua 100 lần mở/đóng picker |

Đặt mục tiêu thời gian startup và mức giảm wakeup sau khi đo baseline. Không áp một mức bộ nhớ chung cho Clipboard văn bản và Clipboard chứa ảnh.

## 5. Ma trận kiểm thử

- Nền tảng: macOS tối thiểu được hỗ trợ và bản mới; Apple silicon và Intel nếu tiếp tục hỗ trợ.
- Đầu vào: Telex/VNI, chuyển Việt/Anh, gõ tắt, Safari/Chromium, Finder, editor và ô nhập dùng Accessibility; trackpad và chuột USB/Bluetooth.
- Thiết bị: màn hình tích hợp, DDC ngoài, màn hình không DDC, chỉ ghi được, nhiều màn hình, rút/cắm và đổi màn hình chính.
- Trạng thái: thiếu/tắt lại quyền, helper không trả lời, wake, thoát/mở lại app, bật/tắt nhanh module, ghi shortcut trong khi bộ gõ hoạt động.
- Clipboard: văn bản/ảnh/file, nguồn nhạy cảm, ghim, xóa, dữ liệu lớn, bật/tắt trong lúc tạo thumbnail.
- UX: Light/Dark Mode, bàn phím/VoiceOver, cửa sổ ở kích thước tối thiểu, thông báo lỗi dài.

## 6. Thứ tự đề xuất

Đo và chuẩn hóa build → mở cài đặt độc lập với quyền bộ gõ + tổ chức lại Tiện ích → tách cấu hình module + gom lệnh DDC → xử lý helper/Clipboard ngoài main thread → thống nhất lifecycle → preset, chẩn đoán, import/export → kiểm thử phát hành.

Ước lượng ban đầu: 8–12 ngày làm việc, tùy số lỗi tái hiện và thiết bị kiểm thử. Triển khai thành các đợt nhỏ; chốt lại thời gian sau Đợt 0. Đợt đầu nên hoàn thành build chuẩn, đo baseline, luồng cài đặt độc lập và nhóm Âm thanh & màn hình trước.
