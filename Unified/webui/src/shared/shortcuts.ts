// Shortcut strings shared with C++ (open_settings_ui.cc ParseShortcut /
// FormatShortcut): "Mod+Shift+T" style, where "Mod" is the platform's
// primary modifier (Command on macOS, Control on Windows and Linux).
// Display follows the platform: "⇧⌘T" on macOS, "Ctrl+Shift+T" elsewhere.

export type ShortcutPlatform = 'mac' | 'windows' | 'linux';

let cachedPlatform: ShortcutPlatform | null = null;

/** The platform shortcuts are shown for. `?platform=mac|windows|linux` overrides it (previews). */
export function shortcutPlatform(): ShortcutPlatform {
  if (cachedPlatform) return cachedPlatform;
  let platform: ShortcutPlatform = 'linux';
  if (typeof window !== 'undefined') {
    const override = new URLSearchParams(window.location.search).get('platform');
    if (override === 'mac' || override === 'windows' || override === 'linux') {
      platform = override;
    } else {
      const nav = window.navigator as Navigator & { userAgentData?: { platform?: string } };
      const raw = `${nav.userAgentData?.platform ?? ''} ${nav.platform ?? ''} ${nav.userAgent ?? ''}`.toLowerCase();
      if (raw.includes('mac')) platform = 'mac';
      else if (raw.includes('win')) platform = 'windows';
    }
  }
  cachedPlatform = platform;
  return platform;
}

export function isMacPlatform(): boolean {
  return shortcutPlatform() === 'mac';
}

type Modifier = 'ctrl' | 'alt' | 'shift' | 'meta';

const MAC_SYMBOLS: Record<Modifier, string> = { ctrl: '⌃', alt: '⌥', shift: '⇧', meta: '⌘' };
const MAC_ORDER: Modifier[] = ['ctrl', 'alt', 'shift', 'meta'];
const PC_ORDER: Modifier[] = ['ctrl', 'alt', 'shift', 'meta'];

const MAC_KEYS: Record<string, string> = {
  tab: '⇥',
  return: '↩',
  enter: '↩',
  escape: '⎋',
  esc: '⎋',
  left: '←',
  right: '→',
  up: '↑',
  down: '↓',
  backspace: '⌫',
  delete: '⌦',
  space: 'Space',
  pageup: '⇞',
  pagedown: '⇟',
  home: '↖',
  end: '↘',
};

const PC_KEYS: Record<string, string> = {
  return: 'Enter',
  enter: 'Enter',
  escape: 'Esc',
  esc: 'Esc',
  backspace: 'Backspace',
  delete: 'Delete',
  pageup: 'PageUp',
  pagedown: 'PageDown',
};

function keyLabel(rawKey: string, mac: boolean): string {
  const lower = rawKey.toLowerCase();
  const mapped = (mac ? MAC_KEYS : PC_KEYS)[lower];
  if (mapped) return mapped;
  if (lower.length === 1) return lower.toUpperCase();
  if (/^f\d{1,2}$/.test(lower)) return lower.toUpperCase();
  return lower.charAt(0).toUpperCase() + lower.slice(1);
}

/** Splits "Mod+Shift+T" into resolved modifiers and the key, for `platform`. */
export function parseShortcut(
  keys: string,
  platform: ShortcutPlatform = shortcutPlatform(),
): { modifiers: Set<Modifier>; key: string } | null {
  const parts = keys
    .split('+')
    .map((p) => p.trim())
    .filter(Boolean);
  // "Mod++" (the plus key) leaves an empty last part.
  if (keys.trim().endsWith('++')) parts.push('+');
  if (parts.length === 0) return null;
  const key = parts.pop()!;
  const modifiers = new Set<Modifier>();
  for (const raw of parts) {
    switch (raw.toLowerCase()) {
      case 'mod':
        modifiers.add(platform === 'mac' ? 'meta' : 'ctrl');
        break;
      case 'ctrl':
      case 'control':
        modifiers.add('ctrl');
        break;
      case 'alt':
      case 'option':
      case 'opt':
        modifiers.add('alt');
        break;
      case 'shift':
        modifiers.add('shift');
        break;
      case 'cmd':
      case 'command':
      case 'meta':
      case 'super':
      case 'win':
        modifiers.add('meta');
        break;
      default:
        return null;
    }
  }
  return { modifiers, key };
}

/** "Mod+Shift+T" -> "⇧⌘T" (macOS) or "Ctrl+Shift+T" (Windows, Linux). Unparseable text is returned as is. */
export function formatShortcut(keys: string, platform: ShortcutPlatform = shortcutPlatform()): string {
  if (!keys) return '';
  const parsed = parseShortcut(keys, platform);
  if (!parsed) return keys;
  const mac = platform === 'mac';
  if (mac) {
    const mods = MAC_ORDER.filter((m) => parsed.modifiers.has(m))
      .map((m) => MAC_SYMBOLS[m])
      .join('');
    return `${mods}${keyLabel(parsed.key, true)}`;
  }
  const names: Record<Modifier, string> = {
    ctrl: 'Ctrl',
    alt: 'Alt',
    shift: 'Shift',
    meta: platform === 'windows' ? 'Win' : 'Super',
  };
  const mods = PC_ORDER.filter((m) => parsed.modifiers.has(m)).map((m) => names[m]);
  return [...mods, keyLabel(parsed.key, false)].join('+');
}

/** The primary modifier's display name: "⌘" on macOS, "Ctrl" elsewhere. */
export function primaryModifierLabel(platform: ShortcutPlatform = shortcutPlatform()): string {
  return platform === 'mac' ? '⌘' : 'Ctrl';
}

const CODE_KEYS: Record<string, string> = {
  Space: 'Space',
  Tab: 'Tab',
  Enter: 'Return',
  NumpadEnter: 'Return',
  Backspace: 'Backspace',
  Delete: 'Delete',
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowUp: 'Up',
  ArrowDown: 'Down',
  Home: 'Home',
  End: 'End',
  PageUp: 'PageUp',
  PageDown: 'PageDown',
  BracketLeft: '[',
  BracketRight: ']',
  Comma: ',',
  Period: '.',
  Slash: '/',
  Minus: '-',
  Equal: '=',
  Semicolon: ';',
  Quote: "'",
  Backslash: '\\',
  Backquote: '`',
};

/**
 * A key press as a canonical "Mod+Shift+T" string, or null for a bare
 * modifier press. Uses the physical key (KeyboardEvent.code), so Option+N on
 * macOS records "N", not "˜", and Shift+1 records "1".
 */
export function shortcutFromKeyboardEvent(
  e: KeyboardEvent,
  platform: ShortcutPlatform = shortcutPlatform(),
): string | null {
  let key: string | undefined;
  if (/^Key[A-Z]$/.test(e.code)) key = e.code.slice(3);
  else if (/^Digit\d$/.test(e.code)) key = e.code.slice(5);
  else if (/^Numpad\d$/.test(e.code)) key = e.code.slice(6);
  else if (/^F\d{1,2}$/.test(e.code)) key = e.code;
  else key = CODE_KEYS[e.code];
  if (!key) {
    // Unknown physical key: fall back to the produced character.
    if (e.key.length === 1 && e.key !== ' ') key = e.key.toUpperCase();
    else return null;
  }
  const mac = platform === 'mac';
  const parts: string[] = [];
  // "Mod" is Command on macOS and Control elsewhere; the other one keeps
  // its own name so both can be bound.
  if (mac ? e.metaKey : e.ctrlKey) parts.push('Mod');
  if (mac && e.ctrlKey) parts.push('Ctrl');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');
  if (!mac && e.metaKey) parts.push('Meta');
  parts.push(key);
  return parts.join('+');
}

/** Keycaps for a shortcut: ["⇧", "⌘", "T"] on macOS, ["Ctrl", "Shift", "T"] elsewhere. */
export function shortcutKeycaps(keys: string, platform: ShortcutPlatform = shortcutPlatform()): string[] {
  const parsed = parseShortcut(keys, platform);
  if (!parsed) return keys ? [keys] : [];
  if (platform === 'mac') {
    return [
      ...MAC_ORDER.filter((m) => parsed.modifiers.has(m)).map((m) => MAC_SYMBOLS[m]),
      keyLabel(parsed.key, true),
    ];
  }
  return formatShortcut(keys, platform).split(/\+(?!$)/);
}
