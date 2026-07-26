# AZS Tools — Bộ gõ Tiếng Việt cho macOS 26

**mkey** là bộ gõ tiếng Việt cho macOS, xây dựng lại từ engine của dự án mã nguồn mở
[OpenKey](https://github.com/tuyenvm/OpenKey) (© Tuyen Mai, GPL v3) với giao diện
hoàn toàn mới của Mkey , tối ưu cho macOS 26 (Tahoe trở lên, yêu cầu tối thiểu macOS 14).

## Có gì mới so với MKey

1. Core Bộ gõ (Thừa hưởng từ OpenKey & MKey Maclife)​
Engine C++ gốc của OpenKey + cấu trúc từ MKey Maclife: gõ cực kỳ chuẩn và nhẹ (Telex, VNI, gõ tắt, smart switch...).
UI mình giữ nguyên bản của Mkey của Maclife

2. Vài tính năng tiện ích nhỏ thêm vào cho tiện nhu cầu:​
Chỉnh màn hình ngoài (DDC/CI): Kéo thanh độ sáng/âm lượng trực tiếp cho màn phụ qua cổng HDMI/Type-C. Có gán phím tắt chỉnh độ sáng toàn hệ thống.
Chỉnh quạt (Fan Control): Đọc RPM thực tế từ AppleSMC, thích chỉnh tay hay trả về Tự động cho máy tự lo đều được.
Đảo chiều cuộn & Remap chuột: Đảo hướng cuộn chuột ngoài độc lập với Trackpad. Remap phím phụ (Button 3 -> Button 10) để mở nhanh Spotlight, Cửa sổ ứng dụng,...

## Cấu trúc

```
mkey/
├── project.yml              # đặc tả XcodeGen
├── scripts/make_icon.swift  # sinh app icon bằng CoreGraphics
└── Sources/
    ├── Engine/              # engine C++ nguyên gốc từ OpenKey (GPL v3)
    ├── Platform/            # glue ObjC++: event tap, bridge engine ↔ Swift
    │   ├── MKGlobals.h      # khai báo biến cấu hình cho Swift
    │   ├── MKBridge.h/.mm   # facade: tap lifecycle, macro, chuyển mã
    │   └── MKEngineHook.mm  # CGEventTap callback + key synthesis
    ├── App/                 # SwiftUI: MenuBarExtra, Settings, AppState
    └── Support/             # Info.plist, entitlements, bridging header, assets
```

## Build

Yêu cầu: macOS 14+, Xcode 16+ (đã kiểm thử với Xcode 26.5 trên macOS 26.5), [XcodeGen](https://github.com/yonaskolb/XcodeGen).



## Giấy phép

Engine và phần glue kế thừa từ OpenKey và Mkey, phát hành theo **GPL v3**.
Toàn bộ mã mkey (UI SwiftUI, bridge) cũng theo GPL v3.
