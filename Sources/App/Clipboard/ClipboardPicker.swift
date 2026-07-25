//
//  ClipboardPicker.swift
//  mkey
//
//  Floating panel that lists clipboard history and pastes the chosen entry
//  back into the app that was focused when the hotkey fired.
//
//  Keyboard navigation is driven by a local NSEvent monitor rather than
//  SwiftUI focus, which is unreliable inside a non-activating panel.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Loads small, cached thumbnails for clipboard images so the picker never
/// decodes full-resolution bitmaps into memory just to draw a 52×38 cell.
enum ClipThumbnail {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL, maxPixel: CGFloat = 120) -> NSImage? {
        let key = "\(url.path)|\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

/// NSPanel that can become key so it receives key events.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


/// Display + selection state shared between the controller's key monitor and
/// the SwiftUI list.
@MainActor
final class ClipboardPickerModel: ObservableObject {
    @Published var items: [ClipItem] = []   // full history
    @Published var query: String = ""
    @Published var selection: Int = 0
    @Published var pinOnTop: Bool = true
    @Published var autoHide: Bool = true
    // hover preview state (rendered as an in-panel overlay; a separate
    // child NSPanel refused to show on macOS 27 for a non-activating app)
    @Published var previewImage: NSImage?
    @Published var previewCaption: String = ""

    /// Items after applying the search query (selection indexes into this).
    /// Case- and diacritic-insensitive so "khong" finds "không".
    var filtered: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@MainActor
final class ClipboardPicker {
    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var resizeObserver: Any?
    private var resignObserver: Any?
    private var moveObserver: Any?
    private var pasting = false
    private let model = ClipboardPickerModel()
    private weak var manager: ClipboardManager?

    var isOpen: Bool { panel != nil }

    func toggle(manager: ClipboardManager) {
        isOpen ? close() : show(manager: manager)
    }

    func updatePinOnTop(_ pin: Bool) {
        model.pinOnTop = pin
        panel?.level = pin ? .floating : .normal
    }

    func updateAutoHide(_ hide: Bool) {
        model.autoHide = hide
    }

    func updateItems(_ newItems: [ClipItem]) {
        model.items = newItems
        if model.selection >= model.filtered.count {
            model.selection = max(0, model.filtered.count - 1)
        }
    }

    func resetLayout() {
        guard let panel else { return }
        let defaultWidth: CGFloat = 480.0
        let defaultHeight: CGFloat = 640.0
        if let frame = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let x = frame.midX - defaultWidth / 2
            let y = frame.midY - defaultHeight / 2
            panel.setFrame(NSRect(x: x, y: y, width: defaultWidth, height: defaultHeight), display: true, animate: true)
        }
    }

    func show(manager: ClipboardManager) {
        self.manager = manager
        previousApp = NSWorkspace.shared.frontmostApplication

        model.items = manager.items
        model.query = ""
        model.selection = 0
        model.pinOnTop = manager.pinOnTop
        model.autoHide = manager.autoHide
        model.previewImage = nil
        model.previewCaption = ""

        let root = ClipboardPickerView(
            model: model,
            imageURL: { [weak manager] item in manager?.imageURL(for: item) },
            onPick: { [weak self] item in self?.pick(item) },
            onRemove: { [weak self] item in
                guard let self else { return }
                self.manager?.remove(item)
                self.model.items = self.manager?.items ?? []
                if self.model.selection >= self.model.filtered.count {
                    self.model.selection = max(0, self.model.filtered.count - 1)
                }
            },
            onStrip: { [weak self] item in
                guard let self else { return }
                self.manager?.stripFormatting(of: item)
                self.model.items = self.manager?.items ?? []
            },
            onTogglePin: { [weak self] item in
                guard let self else { return }
                self.manager?.togglePin(item)
                self.model.items = self.manager?.items ?? []
            },
            onClear: { [weak self] in
                self?.manager?.clear()
                self?.model.items = self?.manager?.items ?? []
            },
            onPinOnTopToggle: { [weak self] pin in
                guard let self else { return }
                self.manager?.pinOnTop = pin
            },
            onAutoHideToggle: { [weak self] autoHide in
                guard let self else { return }
                self.manager?.autoHide = autoHide
            },
            onPreview: { [weak self] item in self?.showPreview(for: item) },
            onPreviewEnd: { [weak self] in self?.hidePreview() },
            onClose: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: root)

        // Spotlight-style: a non-activating panel that still becomes key (see
        // KeyablePanel.canBecomeKey) so the search field receives keystrokes
        // WITHOUT activating the app — on macOS 26 NSApp.activate() no longer
        // brings an accessory app forward, so a plain borderless window never
        // became key and typing leaked to the previously-focused app.
        let width = UserDefaults.standard.double(forKey: "clipboardPickerWidth")
        let actualWidth = (width == 0.0 || width == 460.0 || width == 600.0) ? 480.0 : (width >= 380.0 ? CGFloat(width) : 480.0)
        let height = UserDefaults.standard.double(forKey: "clipboardPickerHeight")
        let actualHeight = (height == 0.0 || height == 420.0 || height == 500.0 || height == 1000.0) ? 640.0 : (height >= 300.0 ? CGFloat(height) : 640.0)

        let x = UserDefaults.standard.double(forKey: "clipboardPickerX")
        let y = UserDefaults.standard.double(forKey: "clipboardPickerY")

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: actualWidth, height: actualHeight),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = manager.pinOnTop ? .floating : .normal
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.contentViewController = hosting

        var origin = NSPoint.zero
        if x != 0.0 || y != 0.0 {
            let proposedRect = NSRect(x: CGFloat(x), y: CGFloat(y), width: actualWidth, height: actualHeight)
            let isVisible = NSScreen.screens.contains { screen in
                screen.frame.intersects(proposedRect)
            }
            if isVisible {
                origin = proposedRect.origin
            }
        }

        if origin == .zero {
            if let frame = (panel.screen ?? NSScreen.main)?.visibleFrame {
                origin = NSPoint(x: frame.midX - actualWidth / 2, y: frame.midY - actualHeight / 2)
            }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: actualWidth, height: actualHeight)), display: true)

        self.panel = panel
        MKBridge.setEngineSuspended(true) // raw keys into the search field
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)

        installKeyMonitor()

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak panel, weak self] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                let size = panel.frame.size
                UserDefaults.standard.set(Double(size.width), forKey: "clipboardPickerWidth")
                UserDefaults.standard.set(Double(size.height), forKey: "clipboardPickerHeight")
                self?.manager?.updateCustomLayoutStatus()
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak panel, weak self] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                let origin = panel.frame.origin
                UserDefaults.standard.set(Double(origin.x), forKey: "clipboardPickerX")
                UserDefaults.standard.set(Double(origin.y), forKey: "clipboardPickerY")
                self?.manager?.updateCustomLayoutStatus()
            }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.autoHide {
                    self.close()
                }
            }
        }
    }

    // MARK: Hover image preview (Maccy-style)

    /// Source for the large preview. Always the PNG stored in the app's own
    /// Application Support dir — NEVER the original file: reading files in
    /// Documents/Desktop/Downloads triggers a TCC permission prompt, which
    /// fights the non-activating key panel and hangs the app.
    static func previewImageURL(for item: ClipItem, manager: ClipboardManager?) -> URL? {
        guard item.imageFile != nil else { return nil }
        if !item.isImage {
            // copied files: only preview actual images (extension check is a
            // pure string operation, no disk access)
            guard let path = item.filePath,
                  let type = UTType(filenameExtension: (path as NSString).pathExtension),
                  type.conforms(to: .image) else { return nil }
        }
        return manager?.imageURL(for: item)
    }

    /// Shows a large preview of an image item as an overlay inside the picker
    /// panel. The overlay doesn't hit-test, so hover/clicks/keys are unaffected.
    func showPreview(for item: ClipItem) {
        guard isOpen,
              let url = ClipboardPicker.previewImageURL(for: item, manager: manager),
              let image = ClipThumbnail.image(for: url, maxPixel: 512) else { return }
        model.previewImage = image
        model.previewCaption = item.text
    }

    func hidePreview() {
        model.previewImage = nil
        model.previewCaption = ""
    }

    func close() {
        hidePreview()
        MKBridge.setEngineSuspended(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver); self.resizeObserver = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver); self.moveObserver = nil }
        let wasOpen = panel != nil
        if let frame = panel?.frame {
            UserDefaults.standard.set(Double(frame.size.width), forKey: "clipboardPickerWidth")
            UserDefaults.standard.set(Double(frame.size.height), forKey: "clipboardPickerHeight")
            UserDefaults.standard.set(Double(frame.origin.x), forKey: "clipboardPickerX")
            UserDefaults.standard.set(Double(frame.origin.y), forKey: "clipboardPickerY")
            manager?.updateCustomLayoutStatus()
        }
        panel?.orderOut(nil)
        panel = nil
        if wasOpen, !pasting { previousApp?.activate(options: .activateIgnoringOtherApps) }
    }

    private func pick(_ item: ClipItem) {
        let prev = previousApp
        pasting = true
        close()
        pasting = false
        manager?.paste(item, into: prev)
    }

    private func installKeyMonitor() {
        // Navigation keys are intercepted here BEFORE they reach the search
        // field; everything else falls through so typing filters the list.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            let list = self.model.filtered
            let count = list.count
            if event.keyCode == 35, event.modifierFlags.contains(.command) { // ⌘P: pin/unpin
                if list.indices.contains(self.model.selection) {
                    self.manager?.togglePin(list[self.model.selection])
                    self.model.items = self.manager?.items ?? []
                }
                return nil
            }
            switch event.keyCode {
            case 125: // down
                if count > 0 { self.model.selection = min(count - 1, self.model.selection + 1) }
                return nil
            case 126: // up
                if count > 0 { self.model.selection = max(0, self.model.selection - 1) }
                return nil
            case 48, 36, 76: // tab (primary) / return / enter → paste
                if list.indices.contains(self.model.selection) {
                    self.pick(list[self.model.selection])
                }
                return nil
            case 53: // escape: clear the search first, then close
                if !self.model.query.isEmpty {
                    self.model.query = ""
                    self.model.selection = 0
                } else {
                    self.close()
                }
                return nil
            case 18...23, 25, 26, 28, 29: // number row 1-9 → quick pick (only when not searching)
                if self.model.query.isEmpty,
                   let n = Int(event.charactersIgnoringModifiers ?? ""), n >= 1, n <= count {
                    self.pick(list[n - 1])
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }
}

private struct ClipboardPickerView: View {
    @ObservedObject var model: ClipboardPickerModel
    let imageURL: (ClipItem) -> URL?
    let onPick: (ClipItem) -> Void
    let onRemove: (ClipItem) -> Void
    let onStrip: (ClipItem) -> Void
    let onTogglePin: (ClipItem) -> Void
    let onClear: () -> Void
    let onPinOnTopToggle: (Bool) -> Void
    let onAutoHideToggle: (Bool) -> Void
    let onPreview: (ClipItem) -> Void
    let onPreviewEnd: () -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(Color.accentColor)
                    .font(.headline)
                Text("Lịch sử Clipboard")
                    .font(.headline)
                Spacer()

                if !model.items.isEmpty {
                    Text("\(model.items.count) mục")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Pin Button
                Button {
                    model.pinOnTop.toggle()
                    onPinOnTopToggle(model.pinOnTop)
                } label: {
                    Image(systemName: model.pinOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(model.pinOnTop ? Color.accentColor : .secondary)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(model.pinOnTop ? "Bỏ ghim trên cùng" : "Ghim trên cùng")

                // Auto-Hide Button
                Button {
                    model.autoHide.toggle()
                    onAutoHideToggle(model.autoHide)
                } label: {
                    Image(systemName: model.autoHide ? "eye.slash.fill" : "eye")
                        .foregroundStyle(model.autoHide ? Color.accentColor : .secondary)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(model.autoHide ? "Tắt tự động ẩn" : "Bật tự động ẩn")

                if !model.items.isEmpty {
                    Button(role: .destructive) {
                        onClear()
                    } label: {
                        Text("Xoá tất cả")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Xoá toàn bộ lịch sử (giữ lại các mục đã ghim)")
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Đóng (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider()

            if !model.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Tìm trong lịch sử…", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onChange(of: model.query) { _, _ in model.selection = 0 }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            listContent

            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "Chọn")
                hint("⇥", "Dán")
                hint("⌘P", "Ghim")
                if model.query.isEmpty { hint("1–9", "Chọn nhanh") }
                hint("esc", "Đóng")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        // Light behind-window blur softens the content underneath (so it isn't
        // a busy, sharp see-through) while a low tint keeps text readable.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.45))
        .background(VisualEffectBlur(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .overlay {
            // hover preview for image items — floats over the list, never
            // intercepts the mouse so hover/keys keep working underneath
            if let image = model.previewImage {
                ClipPreviewView(image: image, caption: model.previewCaption)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                    .allowsHitTesting(false)
                    .padding(24)
            }
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var listContent: some View {
        let items = model.filtered
        if model.items.isEmpty {
            emptyState(icon: "clipboard",
                       title: "Chưa có gì trong Clipboard",
                       subtitle: "Sao chép văn bản hoặc hình ảnh để bắt đầu lưu lịch sử.")
        } else if items.isEmpty {
            emptyState(icon: "magnifyingglass",
                       title: "Không tìm thấy",
                       subtitle: "Không có mục nào khớp với “\(model.query)”.")
        } else {
            let firstUnpinned = items.firstIndex(where: { !$0.pinned }) ?? items.count
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0, item.pinned {
                                sectionLabel("Đã ghim", icon: "pin.fill")
                            }
                            if index == firstUnpinned, firstUnpinned > 0 {
                                sectionLabel("Lịch sử", icon: "clock")
                            }
                            PickerRow(index: index, item: item,
                                      isSelected: index == model.selection,
                                      imageURL: imageURL,
                                      onPick: { onPick(item) },
                                      onRemove: { onRemove(item) },
                                      onStrip: { onStrip(item) },
                                      onTogglePin: { onTogglePin(item) },
                                      onPreview: { onPreview(item) },
                                      onPreviewEnd: onPreviewEnd)
                                .id(item.id) // stable identity so filtering shows correct rows
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { _, newValue in
                    guard items.indices.contains(newValue) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(items[newValue].id, anchor: .center) }
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Floating card with a large image preview, shown while hovering an image row.
private struct ClipPreviewView: View {
    let image: NSImage
    let caption: String

    var body: some View {
        // natural size capped at 380pt — never upscale small thumbnails
        let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
        let scale = min(1, min(380 / iw, 380 / ih))
        let w = iw * scale, h = ih * scale

        VStack(spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: max(w, 140))
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
        .background(VisualEffectBlur(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private struct PickerRow: View {
    let index: Int
    let item: ClipItem
    let isSelected: Bool
    let imageURL: (ClipItem) -> URL?
    let onPick: () -> Void
    let onRemove: () -> Void
    let onStrip: () -> Void
    let onTogglePin: () -> Void
    let onPreview: () -> Void
    let onPreviewEnd: () -> Void
    @State private var hovering = false
    @State private var previewTask: DispatchWorkItem?

    private var subtitle: String {
        let app = item.sourceApp ?? "Khác"
        return "\(app) • \(PickerRow.relativeTime(item.date))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospaced())
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                .frame(width: 18, alignment: .trailing)

            if let filePaths = item.filePaths, filePaths.count > 1 {
                ZStack {
                    // Bottom card (Layer 3) - offset up-right
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isSelected
                            ? Color.white.opacity(0.12)
                            : Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    isSelected
                                    ? Color.white.opacity(0.25)
                                    : Color.secondary.opacity(0.15),
                                    lineWidth: 0.5
                                )
                        )
                        .frame(width: 48, height: 34)
                        .offset(x: 2, y: -2)

                    // Middle card (Layer 2) - centered
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isSelected
                            ? Color.white.opacity(0.16)
                            : Color(nsColor: .quaternaryLabelColor).opacity(0.45)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    isSelected
                                    ? Color.white.opacity(0.3)
                                    : Color.secondary.opacity(0.2),
                                    lineWidth: 0.5
                                )
                        )
                        .frame(width: 48, height: 34)
                        .offset(x: 0, y: 0)

                    // Top card (Layer 1 - Main) - offset down-left
                    ZStack {
                        if let url = imageURL(item), let nsImage = ClipThumbnail.image(for: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    isSelected
                                    ? Color.white.opacity(0.2)
                                    : Color(nsColor: .quaternaryLabelColor).opacity(0.5)
                                )
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                        }
                    }
                    .frame(width: 48, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isSelected
                                ? Color.white.opacity(0.4)
                                : Color.secondary.opacity(0.25),
                                lineWidth: 0.5
                            )
                    )
                    .offset(x: -2, y: 2)

                    // File count badge in the bottom-right corner of the stack container
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(filePaths.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(
                                            isSelected
                                            ? Color.orange
                                            : Color.black.opacity(0.75)
                                        )
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
                }
                .frame(width: 52, height: 38)
            } else if let url = imageURL(item), let nsImage = ClipThumbnail.image(for: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            } else {
                ZStack {
                    if item.htmlText != nil {
                        // Soft, elegant lavender/blue glassmorphic card for rich text
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                isSelected 
                                ? LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [Color.blue.opacity(0.06), Color.purple.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(
                                isSelected 
                                ? LinearGradient(colors: [.white, .white.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    } else {
                        // Minimalist, neutral gray card for plain text
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                isSelected
                                ? Color.white.opacity(0.08)
                                : Color(nsColor: .quaternaryLabelColor).opacity(0.3)
                            )
                        
                        Image(systemName: "doc.text")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    }
                }
                .frame(width: 52, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSelected
                            ? Color.white.opacity(0.25)
                            : (item.htmlText != nil ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.15)),
                            lineWidth: 0.5
                        )
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.isImage ? item.text : item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(2)
                    .font(.body)
                    .foregroundStyle(isSelected ? .white : .primary)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.orange)
                            .rotationEffect(.degrees(45))
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                HStack(spacing: 8) {
                    Button(action: onTogglePin) {
                        Image(systemName: item.pinned ? "pin.slash" : "pin")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : (item.pinned ? Color.secondary : Color.orange))
                    }
                    .buttonStyle(.plain)
                    .help(item.pinned ? "Bỏ ghim" : "Ghim lên đầu — không bị trôi, không bị xoá khi dọn lịch sử")

                    if item.htmlText != nil {
                        Button(action: onStrip) {
                            Image(systemName: "eraser")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Bỏ định dạng Rich Text & Markdown")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Xoá mục này khỏi lịch sử")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear)),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { onPick() }
        .onHover { h in
            hovering = h
            previewTask?.cancel()
            previewTask = nil
            if h, item.isImage || item.filePath != nil { // showPreview ignores non-image files
                // slight delay so skimming the list doesn't flash previews
                let task = DispatchWorkItem { onPreview() }
                previewTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
            } else {
                onPreviewEnd()
            }
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            if hovering { onPreviewEnd() }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Vietnamese relative time: "Vừa xong", "5 phút trước", "2 giờ trước", …
    static func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "Vừa xong" }
        if s < 60 { return "\(s) giây trước" }
        let m = s / 60
        if m < 60 { return "\(m) phút trước" }
        let h = m / 60
        if h < 24 { return "\(h) giờ trước" }
        let d = h / 24
        if d < 7 { return "\(d) ngày trước" }
        let w = d / 7
        return "\(w) tuần trước"
    }
}