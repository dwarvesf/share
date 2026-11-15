import Carbon.HIToolbox
import Foundation

/// A global shortcut as Carbon names it: a virtual key code and modifier flags.
public struct Hotkey: Sendable, Equatable, Hashable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-S (SPEC-009 TASK-4b13).
    public static let controlOptionS = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))

    public var inUseSentence: String { "Control-Option-S is in use by another app" }
}

/// What a registration answered.
public enum HotkeyStatus: Sendable, Equatable {
    case registered
    case inUse

    /// The line under General's Shortcut; nil when the key is ours.
    public var message: String? {
        self == .inUse ? Hotkey.controlOptionS.inUseSentence : nil
    }
}

/// The OS call, behind a seam so a test hands in a fake and the app hands in Carbon.
public protocol HotkeyRegistrar: AnyObject {
    /// Registers `key`; `handler` runs on the main thread each time it is pressed. Nil when the OS refuses.
    func register(_ key: Hotkey, handler: @escaping () -> Void) -> Int?
    func unregister(_ token: Int)
}

/// Holds one registration and reports whether it took (no Accessibility permission: Carbon's
/// `RegisterEventHotKey` needs none).
public final class HotkeyCenter {
    private let registrar: HotkeyRegistrar
    private var token: Int?
    public private(set) var status: HotkeyStatus = .inUse

    public init(registrar: HotkeyRegistrar) { self.registrar = registrar }

    @discardableResult
    public func register(_ key: Hotkey = .controlOptionS, handler: @escaping () -> Void) -> HotkeyStatus {
        if let token { registrar.unregister(token) }
        token = registrar.register(key, handler: handler)
        status = token == nil ? .inUse : .registered
        return status
    }

    public func unregister() {
        if let token { registrar.unregister(token) }
        token = nil
    }

    deinit { unregister() }
}

/// The real registrar: Carbon `RegisterEventHotKey` on the application event target.
public final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private var refs: [Int: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var next = 1
    private var eventHandler: EventHandlerRef?

    public init() {}

    public func register(_ key: Hotkey, handler: @escaping () -> Void) -> Int? {
        installHandlerIfNeeded()
        let id = next
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5342_4B59), id: UInt32(id))
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        next += 1
        refs[id] = ref
        handlers[UInt32(id)] = handler
        return id
    }

    public func unregister(_ token: Int) {
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        handlers[UInt32(token)] = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            registrar.handlers[hotKeyID.id]?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
