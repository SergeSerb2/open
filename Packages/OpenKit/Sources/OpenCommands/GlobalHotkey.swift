import Carbon
import Foundation

/// System-wide Little Open hotkey through Carbon `RegisterEventHotKey`.
/// Opt-in: the app registers only while the setting is on, and must call
/// `unregister()` when the setting turns off or the shortcut changes.
/// Mirrors Arc `GlobalHotkeyManager` / `registerLittleBrowserShortcut`.
public final class GlobalHotkeyService: @unchecked Sendable {
    public enum ServiceError: Error, Sendable {
        case unsupportedKey(String)
        case registerFailed(OSStatus)
        case handlerInstallFailed(OSStatus)
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (@Sendable (TimeInterval) -> Void)?

    public private(set) var registeredShortcut: KeyboardShortcut?
    /// Carbon hotkey ID (signature 'OPEN'). Several services can be registered at once (Little Open = 1, global
    /// extension commands from 100); each handler answers only for its own ID and passes other hotkeys on.
    public let hotKeyIdentifier: UInt32

    public var isRegistered: Bool { hotKeyRef != nil }

    public init(identifier: UInt32 = 1) { hotKeyIdentifier = identifier }

    deinit { unregister() }

    /// Registers `shortcut` system-wide. Replaces any current registration.
    public func register(shortcut: KeyboardShortcut, action: @escaping @Sendable () -> Void) throws {
        try register(shortcut: shortcut, actionWithTimestamp: { _ in action() })
    }

    /// Carbon and NSEvent use the same monotonic key-down clock.
    public func register(shortcut: KeyboardShortcut, actionWithTimestamp: @escaping @Sendable (TimeInterval) -> Void) throws {
        unregister()
        guard let keyCode = shortcut.carbonKeyCode else {
            throw ServiceError.unsupportedKey(shortcut.key)
        }
        self.action = actionWithTimestamp

        var handlerRef: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, pressed.signature == GlobalHotkeyService.signature,
                      pressed.id == service.hotKeyIdentifier else { return OSStatus(eventNotHandledErr) }
                service.action?(GetEventTime(event))
                return noErr
            }, 1, &eventType, selfPointer, &handlerRef
        )
        guard installStatus == noErr else { throw ServiceError.handlerInstallFailed(installStatus) }
        self.handlerRef = handlerRef

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKeyIdentifier)
        let status = RegisterEventHotKey(
            keyCode, shortcut.modifiers.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            throw ServiceError.registerFailed(status)
        }
        self.hotKeyRef = hotKeyRef
        registeredShortcut = shortcut
    }

    static let signature = OSType(0x4F50_454E) // 'OPEN'

    /// Removes the system registration. Safe to call when nothing is registered.
    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        registeredShortcut = nil
        action = nil
    }
}
