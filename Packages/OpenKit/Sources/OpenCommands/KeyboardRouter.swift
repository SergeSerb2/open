import AppKit
import Foundation

/// Focus facts the router needs. The app fills one value per key event.
public struct RoutingContext: Sendable {
    /// False when another app is frontmost (only global commands may fire).
    public var isAppActive: Bool
    public var isCommandBarOpen: Bool
    public var isSidebarFocused: Bool
    /// True when a text field, the find field, or editable web text holds focus.
    public var isTextFocused: Bool
    /// True when web page content holds focus (page shortcuts may apply).
    public var isWebContentFocused: Bool

    public init(
        isAppActive: Bool = true,
        isCommandBarOpen: Bool = false,
        isSidebarFocused: Bool = false,
        isTextFocused: Bool = false,
        isWebContentFocused: Bool = false
    ) {
        self.isAppActive = isAppActive
        self.isCommandBarOpen = isCommandBarOpen
        self.isSidebarFocused = isSidebarFocused
        self.isTextFocused = isTextFocused
        self.isWebContentFocused = isWebContentFocused
    }

    /// The narrowest scope that matches the current focus.
    public var focusScope: CommandScope {
        if isCommandBarOpen { return .commandBar }
        if isSidebarFocused { return .sidebarFocused }
        if isWebContentFocused || isTextFocused { return .webContent }
        return .window
    }
}

/// Where one key event must go.
public enum RoutingDecision: Sendable, Equatable {
    /// Run this browser command. The page and the system do not see the keys.
    case browserCommand(String)
    /// Send the keys to the web page (its own shortcut or normal input).
    case webContent
    /// Let AppKit run its normal responder chain (text editing, menu keys).
    case system
    /// Swallow the keys. Used for the first press of a double-press binding.
    case swallowed
}

/// Decides browser key versus web page key for each event.
/// The app calls `route` from `NSApplication.sendEvent` or the key window's
/// `keyDown` path before the web view sees the event.
///
/// Rules, in order:
/// 1. Another app frontmost: only `global` commands fire (Little Open).
/// 2. Command bar open: command-bar scope wins; Escape closes; other window
///    commands stay off so typing keeps working.
/// 3. Text focus: edit commands (Undo, Copy, font keys) go to the system.
///    Window commands still win unless their priority says the site wins.
/// 4. Sidebar focus: sidebar commands (New Folder) beat the window command
///    that shares their keys (New Incognito Window).
/// 5. Priority: `browserFirst` runs the browser command. `siteFirst` sends
///    the keys to the page. `siteThenBrowserOnDoublePress` sends the first
///    press to the page and runs the command on a quick second press.
public final class KeyboardRouter: @unchecked Sendable {
    /// Max gap between the two presses of a double-press binding.
    public static let doublePressInterval: TimeInterval = 0.4

    private var lastSitePress: (shortcut: KeyboardShortcut, at: Date)?

    public init() {}

    public func route(
        shortcut: KeyboardShortcut,
        context: RoutingContext,
        overrides: KeyBindingStore = .empty,
        now: Date = Date()
    ) -> RoutingDecision {
        // Rule 1: global scope.
        if !context.isAppActive {
            if let command = command(for: shortcut, overrides: overrides, scope: .global) {
                return .browserCommand(command.id)
            }
            return .system
        }

        // Rule 2: command bar.
        if context.isCommandBarOpen {
            if shortcut == KeyboardShortcut(key: "escape") { return .browserCommand("exit-modal") }
            if let command = command(for: shortcut, overrides: overrides, scope: .commandBar) {
                return .browserCommand(command.id)
            }
            return .system
        }

        guard let command = command(for: shortcut, overrides: overrides, scope: nil) else {
            return context.isWebContentFocused ? .webContent : .system
        }

        // Global twin (Little Open) also fires while Open is active.
        if command.scope == .global { return .browserCommand(command.id) }

        // Rule 4: sidebar focus picks the sidebar command over its window twin.
        if context.isSidebarFocused, command.scope != .sidebarFocused {
            if let sidebarCommand = CommandRegistry.active.first(where: {
                $0.scope == .sidebarFocused && overrides.effectiveShortcuts(for: $0).contains(shortcut)
            }) {
                return .browserCommand(sidebarCommand.id)
            }
        }
        if !context.isSidebarFocused, command.scope == .sidebarFocused,
           let windowCommand = CommandRegistry.active.first(where: {
               $0.scope == .window && overrides.effectiveShortcuts(for: $0).contains(shortcut)
           }) {
            return .browserCommand(windowCommand.id)
        }

        // Rule 3: text edit commands belong to the responder chain.
        if context.isTextFocused, command.scope == .webContent {
            return .system
        }

        // Rule 5: site versus browser priority, only over web content.
        if context.isWebContentFocused {
            switch overrides.effectivePriority(for: command) {
            case .browserFirst:
                return .browserCommand(command.id)
            case .siteFirst:
                return .webContent
            case .siteThenBrowserOnDoublePress:
                if let last = lastSitePress, last.shortcut == shortcut,
                   now.timeIntervalSince(last.at) <= Self.doublePressInterval {
                    lastSitePress = nil
                    return .browserCommand(command.id)
                }
                lastSitePress = (shortcut, now)
                return .webContent
            }
        }

        return .browserCommand(command.id)
    }

    /// Convenience for the app's event path: builds the shortcut from the event.
    public func route(event: NSEvent, context: RoutingContext, overrides: KeyBindingStore = .empty) -> RoutingDecision? {
        guard let shortcut = KeyboardShortcut.from(event: event) else { return nil }
        return route(shortcut: shortcut, context: context, overrides: overrides)
    }

    private func command(for shortcut: KeyboardShortcut, overrides: KeyBindingStore, scope: CommandScope?) -> CommandDefinition? {
        CommandRegistry.active.first { candidate in
            overrides.effectiveShortcuts(for: candidate).contains(shortcut)
                && (scope == nil || candidate.scope == scope)
        }
    }
}
