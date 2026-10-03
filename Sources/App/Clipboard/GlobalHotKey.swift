//
//  GlobalHotKey.swift
//  mkey
//
//  A self-contained Carbon global hotkey. Deliberately independent from the
//  engine's CGEventTap so the clipboard feature cannot affect the stable
//  typing/switch/convert hotkeys. Carbon hotkeys are consumed system-wide and
//  do not require Accessibility.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {
  private static var nextIdentifier: UInt32 = 1
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private let identifier: UInt32
  var onPressed: (() -> Void)?
  private(set) var registrationError: String?
  private static var owners: [UInt64: UInt32] = [:]
  private var ownedCombination: UInt64?

  init() {
    identifier = Self.nextIdentifier
    Self.nextIdentifier &+= 1
  }

  /// Map the shared hotkey bitfield (see Engine.h) to Carbon modifier flags.
  static func carbonModifiers(from status: Int32) -> UInt32 {
    let v = UInt32(bitPattern: status)
    var m: UInt32 = 0
    if v & 0x100 != 0 { m |= UInt32(controlKey) }
    if v & 0x200 != 0 { m |= UInt32(optionKey) }
    if v & 0x400 != 0 { m |= UInt32(cmdKey) }
    if v & 0x800 != 0 { m |= UInt32(shiftKey) }
    return m
  }

  static func keyCode(from status: Int32) -> UInt32 {
    // HotkeyEditor stores the physical virtual-key code in the low byte.
    // The high byte is only the display character used by the engine.
    UInt32(UInt8(truncatingIfNeeded: status))
  }

  static func engineConflict(for status: Int32, defaults: UserDefaults = .standard) -> String? {
    let code = keyCode(from: status)
    let mods = carbonModifiers(from: status)
    guard code != 0xFE, mods != 0 else { return nil }
    for key in ["SwitchKeyStatus", "convertToolHotKey"] {
      let saved = Int32(truncatingIfNeeded: defaults.integer(forKey: key))
      if saved != 0, keyCode(from: saved) == code, carbonModifiers(from: saved) == mods {
        return "Tổ hợp này trùng với phím bộ gõ hoặc chuyển mã"
      }
    }
    return nil
  }

  /// (Re)register. Requires a real key (low byte != 0xFE) and at least one
  /// modifier — a bare key would hijack normal typing.
  @discardableResult
  func register(status: Int32) -> Bool {
    unregister()
    registrationError = nil
    let code = GlobalHotKey.keyCode(from: status)
    let mods = GlobalHotKey.carbonModifiers(from: status)
    guard code != 0xFE else { return false }
    guard mods != 0 else {
      registrationError = "Cần ít nhất một phím chức năng"
      return false
    }
    let combination = (UInt64(mods) << 32) | UInt64(code)
    if let conflict = Self.engineConflict(for: status) {
      registrationError = conflict
      return false
    }
    guard Self.owners[combination] == nil else {
      registrationError = "Tổ hợp này đang được chức năng khác sử dụng"
      return false
    }

    let hotKeyID = EventHotKeyID(signature: OSType(0x4D4B_4559), id: identifier)  // 'MKEY'
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { (_, event, userData) -> OSStatus in
        guard let event, let userData else { return noErr }
        let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        var received = EventHotKeyID()
        var size = MemoryLayout<EventHotKeyID>.size
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil, size, &size, &received)
        guard status == noErr, received.signature == OSType(0x4D4B_4559),
          received.id == me.identifier
        else {
          return OSStatus(eventNotHandledErr)
        }
        me.onPressed?()
        return noErr
      }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

    let result =
      handlerStatus == noErr
      ? RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
      : handlerStatus
    guard result == noErr else {
      unregister()
      registrationError = "Không đăng ký được phím tắt (\(result)). Hãy chọn tổ hợp khác."
      return false
    }
    Self.owners[combination] = identifier
    ownedCombination = combination
    return true
  }

  func unregister() {
    if let combination = ownedCombination, Self.owners[combination] == identifier {
      Self.owners.removeValue(forKey: combination)
    }
    ownedCombination = nil
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  deinit { unregister() }
}
