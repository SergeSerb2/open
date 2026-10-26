import Carbon
import Foundation

/// System-wide Little Arc hotkey through Carbon `RegisterEventHotKey`.
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
    private var action: (@Sendable () -> Void)?

    public private(set) var registeredShortcut: KeyboardShortcut?

    public var isRegistered: Bool { hotKeyRef != nil }

    public init() {}

    deinit { unregister() }

    /// Registers `shortcut` system-wide. Replaces any current registration.
    public func register(shortcut: KeyboardShortcut, action: @escaping @Sendable () -> Void) throws {
        unregister()
        guard let keyCode = shortcut.carbonKeyCode else {
            throw ServiceError.unsupportedKey(shortcut.key)
        }
        self.action = action

        var handlerRef: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                service.action?()
                return noErr
            }, 1, &eventType, selfPointer, &handlerRef
        )
        guard installStatus == noErr else { throw ServiceError.handlerInstallFailed(installStatus) }
        self.handlerRef = handlerRef

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F50_454E), id: 1) // 'OPEN'
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
