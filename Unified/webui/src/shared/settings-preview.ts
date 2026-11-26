// In-memory preview of the Settings redesign RPCs (used ONLY outside
// Chromium WebUI, by bridge.ts previewRpc). Mirrors open_settings_ui.cc
// validation and reply shapes so the page behaves the same in a plain browser.

import type { AdBlockState, PreviewState, ProfileSummary, RoutingDestination, RoutingRule, SyncDevice } from './bridge';
import { BUILTIN_SEARCH_ENGINES } from './catalog';
import type {
  AboutInfo,
  AtcState,
  ImportKind,
  ImportReceiptInfo,
  ImportSource,
  RoutingDecisionInfo,
  RoutingTrace,
  SettingsRpcRequestMap,
  SettingsRpcResponseMap,
  SettingsSpace,
  SettingsTheme,
  ShortcutEntry,
  ShortcutsState,
  SyncDetailedStatus,
  SyncMutationResult,
} from './settings-api';

export interface PreviewContext {
  st: PreviewState;
  defaults: Record<string, unknown>;
  buildAdBlockState: (st: PreviewState, profileId: string) => AdBlockState;
  matchHostPattern: (pattern: string, host: string) => boolean;
  emit: (event: string, payload: unknown) => void;
}

// Preference keys stored in a Profile's settings (open_settings_ui.cc kProfileKeys).
const PROFILE_KEYS: Record<string, keyof ProfileSummary['settings']> = {
  'tabs.archiveAfter': 'auto_archive_after',
  'tabs.littleOpenArchiveAfter': 'little_open_auto_archive_after',
  'tabs.sleepMode': 'sleep_mode',
  'search.engine': 'search_engine_id',
  'search.suggestions': 'search_suggest_enabled',
  'downloads.location': 'download_directory',
  'downloads.askEachTime': 'ask_where_to_save_each_file',
  'profiles.newDocuments': 'default_document_app',
};

export function previewPreferences(
  st: PreviewState,
  defaults: Record<string, unknown>,
  profileId: string,
): Record<string, unknown> {
  const values: Record<string, unknown> = { ...defaults, ...st.preferences };
  const profile = st.profiles.find((p) => p.id === profileId) ?? st.profiles[0];
  if (profile) {
    for (const [key, field] of Object.entries(PROFILE_KEYS)) {
      const v = profile.settings[field];
      values[key] = v ?? defaults[key];
    }
  }
  return values;
}

/** Returns an error message, or null when the value was stored. */
export function setPreviewPreference(
  st: PreviewState,
  defaults: Record<string, unknown>,
  key: string,
  value: unknown,
  profileId: string,
  allProfiles: boolean,
): string | null {
  if (!(key in defaults)) return `unknown preference ${key}`;
  const def = defaults[key];
  if (Array.isArray(def) ? !Array.isArray(value) : typeof def !== typeof value) return `wrong type for ${key}`;
  const field = PROFILE_KEYS[key];
  if (field) {
    const targets = allProfiles ? st.profiles : st.profiles.filter((p) => p.id === profileId);
    for (const p of targets) (p.settings as unknown as Record<string, unknown>)[field] = value;
    return null;
  }
  st.preferences[key] = value;
  if (key === 'shortcuts.priority' && (value === 'open' || value === 'website')) st.shortcutPriority = value;
  return null;
}

// --- Extra preview state ----------------------------------------------------------

interface ExtraState {
  shortcuts: ShortcutEntry[];
  routingLog: RoutingDecisionInfo[];
  receipts: ImportReceiptInfo[];
  sync: SyncDetailedStatus;
  customRules: Record<string, string>;
  updating: boolean;
}

let extra: ExtraState | null = null;

const SHORTCUT_SEED: readonly [string, string, string, string, boolean?][] = [
  ['new-tab', 'New Tab…', 'Tabs', 'Mod+T'],
  ['close-tab', 'Close Tab', 'Tabs', 'Mod+W'],
  ['reopen-closed-tab', 'Reopen Closed Tab', 'Tabs', 'Mod+Shift+T'],
  ['pin-tab', 'Pin / Unpin Tab', 'Tabs', 'Mod+D'],
  ['duplicate-tab', 'Duplicate Tab', 'Tabs', ''],
  ['next-tab', 'Next Tab', 'Tabs', 'Mod+Alt+Down'],
  ['previous-tab', 'Previous Tab', 'Tabs', 'Mod+Alt+Up'],
  ['go-to-tab-1', 'Go to Tab 1', 'Tabs', 'Mod+1'],
  ['go-to-tab-9', 'Go to Tab 9', 'Tabs', 'Mod+9'],
  ['copy-url', 'Copy URL', 'Navigation', 'Mod+Shift+C'],
  ['copy-url-markdown', 'Copy URL as Markdown', 'Navigation', 'Mod+Shift+Alt+C'],
  ['go-back', 'Back', 'Navigation', 'Mod+['],
  ['go-forward', 'Forward', 'Navigation', 'Mod+]'],
  ['reload', 'Reload Page', 'Navigation', 'Mod+R'],
  ['view-history', 'Show History', 'Navigation', 'Mod+Y'],
  ['next-space', 'Next Space', 'Spaces', 'Mod+Alt+Right'],
  ['previous-space', 'Previous Space', 'Spaces', 'Mod+Alt+Left'],
  ['new-space', 'New Space', 'Spaces', ''],
  ['go-to-space-1', 'Go to Space 1', 'Spaces', 'Ctrl+1'],
  ['toggle-sidebar', 'Toggle Sidebar', 'View', 'Mod+S'],
  ['add-split-view', 'Add Split View', 'View', 'Ctrl+Shift+='],
  ['next-split-pane', 'Next Split Pane', 'View', 'Ctrl+Shift+]'],
  ['toggle-toolbar', 'Toggle Toolbar', 'View', 'Mod+Shift+D'],
  ['zoom-in', 'Zoom In', 'View', 'Mod+='],
  ['zoom-out', 'Zoom Out', 'View', 'Mod+-'],
  ['open-command-bar', 'Open Command Bar', 'Tools', 'Mod+L'],
  ['open-library', 'Show Library', 'Tools', 'Mod+Shift+Y'],
  ['new-easel', 'New Easel', 'Tools', ''],
  ['new-note', 'New Note', 'Tools', 'Mod+Alt+N'],
  ['find', 'Find on Page', 'Tools', 'Mod+F'],
  ['open-extensions', 'Open Extensions', 'Tools', 'Mod+E'],
  ['capture', 'Capture Screenshot', 'Tools', 'Mod+Shift+2'],
  ['settings', 'Settings', 'Tools', 'Mod+,'],
  ['new-window', 'New Window', 'Window', 'Mod+N'],
  ['new-incognito-window', 'New Incognito Window', 'Window', 'Mod+Shift+N'],
  ['new-little-open', 'New Little Open Window', 'Window', 'Mod+Alt+N'],
  ['little-open-global', 'Show Little Open (Global)', 'Window', 'Mod+Alt+N', true],
  ['minimize-window', 'Minimize Window', 'Window', 'Mod+M'],
];

function extraState(st: PreviewState): ExtraState {
  if (extra) return extra;
  const shortcuts: ShortcutEntry[] = SHORTCUT_SEED.map(([id, title, category, keys, global]) => ({
    id,
    title,
    menu_title: title,
    category,
    menu: category,
    keys,
    all_keys: keys ? [keys] : [],
    default_keys: keys,
    modified: false,
    customizable: true,
    global: global === true,
    priority: 'browser',
    default_priority: 'browser',
    aliases: id === 'little-open-global' ? ['Little Arc', 'Little Open'] : [],
  }));
  const now = Date.now() / 1000;
  extra = {
    shortcuts,
    routingLog: [
      decision(st, 'https://github.com/SergeSerb2/open/pull/412', 'com.tinyspeck.slackmacgap', now - 120),
      decision(st, 'https://docs.google.com/document/d/1x', 'com.apple.mail', now - 900),
      decision(st, 'https://arxiv.org/abs/2411.00001', undefined, now - 3600),
    ],
    receipts: [],
    sync: signedOutSync(st),
    customRules: {},
    updating: false,
  };
  return extra;
}

function signedOutSync(st: PreviewState): SyncDetailedStatus {
  return {
    signed_in: false,
    state: 'signedOut',
    status_message: '',
    email: '',
    display_name: '',
    server_url: st.sync.server_url || 'http://127.0.0.1:8787',
    device_id: '',
    device_name: 'This Mac',
    last_pulled_revision: 0,
    pending_push_count: 0,
    ws_connected: false,
    initial_sync_required: false,
    devices: [],
    categories: {
      workspace: true,
      todayTabs: true,
      archive: true,
      settingsAndShortcuts: true,
      adBlocking: true,
      boostsEaselsNotes: true,
      history: false,
      extensions: true,
      credentialsAndPermissions: false,
    },
    pending_extensions: [],
    warnings: [],
    is_busy: false,
  };
}

// --- Theme ---------------------------------------------------------------------------

function hex(c: { r: number; g: number; b: number }): string {
  const b = (v: number) =>
    Math.round(Math.min(1, Math.max(0, v)) * 255)
      .toString(16)
      .padStart(2, '0');
  return `#${b(c.r)}${b(c.g)}${b(c.b)}`;
}

function lum(c: { r: number; g: number; b: number }): number {
  const ch = (v: number) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

function contrast(a: { r: number; g: number; b: number }, b: { r: number; g: number; b: number }): number {
  const la = lum(a);
  const lb = lum(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function mix(a: { r: number; g: number; b: number }, b: { r: number; g: number; b: number }, t: number) {
  return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t };
}

/** Same math as open_settings_ui.cc ThemeValue(): AA accent for the focused Space. */
export function previewTheme(st: PreviewState): SettingsTheme {
  const pref = String(st.preferences['appearance.websiteAppearance'] ?? 'automatic');
  const systemDark = typeof window !== 'undefined' && window.matchMedia?.('(prefers-color-scheme: dark)').matches;
  const dark = pref === 'dark' || (pref !== 'light' && systemDark === true);
  const surface = dark ? { r: 0.114, g: 0.114, b: 0.149 } : { r: 1, g: 1, b: 1 };
  const spaceId = typeof location !== 'undefined' ? new URLSearchParams(location.search).get('space') : null;
  const space = st.spaces.find((s) => s.id === spaceId);
  const key = space ? space.style.key_color : dark ? { r: 0.541, g: 0.541, b: 0.933 } : { r: 0.357, g: 0.357, b: 0.812 };
  const target = dark ? { r: 1, g: 1, b: 1 } : { r: 0, g: 0, b: 0 };
  let accent = { r: key.r, g: key.g, b: key.b };
  for (let step = 0; step < 20 && contrast(accent, surface) < 4.5; step += 1) accent = mix(key, target, (step + 1) * 0.05);
  const white = { r: 1, g: 1, b: 1 };
  const ink = { r: 0.08, g: 0.08, b: 0.11 };
  const theme: SettingsTheme = {
    mode: dark ? 'dark' : 'light',
    preference: pref,
    accent: hex(accent),
    accent_hover: hex(mix(accent, dark ? white : { r: 0, g: 0, b: 0 }, 0.12)),
    accent_soft: `rgba(${Math.round(accent.r * 255)}, ${Math.round(accent.g * 255)}, ${Math.round(accent.b * 255)}, ${dark ? 0.24 : 0.14})`,
    on_accent: contrast(white, accent) >= contrast(ink, accent) ? hex(white) : hex(ink),
    space_bg: `rgba(${Math.round(key.r * 255)}, ${Math.round(key.g * 255)}, ${Math.round(key.b * 255)}, ${dark ? 0.16 : 0.1})`,
    contrast: Math.round(contrast(accent, surface) * 100) / 100,
  };
  if (space) {
    theme.space_id = space.id;
    theme.space_title = space.title;
  }
  return theme;
}

// --- Air Traffic Control --------------------------------------------------------------

function destinationLabel(st: PreviewState, d: RoutingDestination): string {
  if (d.kind === 'little_open') return 'Little Open';
  if (d.kind === 'most_recent_space') return 'Most recent Space';
  return st.spaces.find((s) => s.id === d.space_id)?.title ?? 'A deleted Space';
}

function decision(st: PreviewState, url: string, sourceApp: string | undefined, at: number): RoutingDecisionInfo {
  let host = '';
  let path = '/';
  try {
    const u = new URL(url);
    host = u.hostname.replace(/^www\./, '');
    path = u.pathname;
  } catch {
    // Kept empty; the caller validated the URL.
  }
  const traces: RoutingTrace[] = [];
  let matched: RoutingRule | undefined;
  st.routingRules.forEach((rule, index) => {
    if (matched) return;
    let outcome: RoutingTrace['outcome'] = 'matched';
    if (!rule.enabled) outcome = 'disabled';
    else if (rule.source_app_id && !sourceApp) outcome = 'source_unknown';
    else if (rule.source_app_id && rule.source_app_id !== sourceApp) outcome = 'source_mismatch';
    else if (!hostMatches(rule.host_pattern, host)) outcome = 'host_mismatch';
    else if (rule.path_prefix && !path.startsWith(rule.path_prefix)) outcome = 'path_mismatch';
    else if (rule.destination.kind === 'space' && !st.spaces.some((s) => s.id === rule.destination.space_id))
      outcome = 'space_missing';
    traces.push({ index, rule_id: rule.id, rule_name: rule.name || rule.host_pattern, outcome });
    if (outcome === 'matched') matched = rule;
  });
  const destination = matched ? matched.destination : st.defaultRoutingDestination;
  const info: RoutingDecisionInfo = {
    url,
    host,
    at,
    via: matched ? 'rule' : 'default',
    explanation: matched ? 'Matched a rule.' : 'No rule matched; the default destination applies.',
    destination,
    destination_label: destinationLabel(st, destination),
    traces,
  };
  if (sourceApp) info.source_app_id = sourceApp;
  if (matched) {
    info.matched_rule_id = matched.id;
    info.matched_rule_name = matched.name || matched.host_pattern;
  }
  return info;
}

function hostMatches(pattern: string, host: string): boolean {
  const p = pattern.trim().toLowerCase();
  if (p.startsWith('*') && p.endsWith('*') && p.length > 2) return host.includes(p.slice(1, -1));
  if (p.startsWith('*.')) return host === p.slice(2) || host.endsWith(`.${p.slice(2)}`);
  return host === p || host.endsWith(`.${p}`);
}

function atcState(st: PreviewState): AtcState {
  return {
    rules: st.routingRules.map((r) => ({ ...r, destination: { ...r.destination } })),
    default_destination: { ...st.defaultRoutingDestination },
    default_destination_label: destinationLabel(st, st.defaultRoutingDestination),
    external_links_little_open: st.preferences['links.externalLinksLittleOpen'] !== false,
    source_apps_supported: true,
  };
}

function validateRule(st: PreviewState, rule: RoutingRule): string | null {
  const pattern = rule.host_pattern.trim().toLowerCase();
  if (!pattern || pattern.length > 253 || /[\s/]/.test(pattern)) {
    return 'Enter a site such as github.com, *.google.com or *docs*.';
  }
  if (rule.destination.kind === 'space' && !st.spaces.some((s) => s.id === rule.destination.space_id)) {
    return 'The destination Space does not exist.';
  }
  return null;
}

// --- Shortcuts -----------------------------------------------------------------------

function shortcutsState(st: PreviewState, x: ExtraState, conflict?: string): ShortcutsState {
  const byKeys = new Map<string, string[]>();
  for (const s of x.shortcuts) {
    for (const k of s.all_keys) {
      const list = byKeys.get(k) ?? [];
      list.push(s.id);
      byKeys.set(k, list);
    }
  }
  const shortcuts = x.shortcuts.map((s) => {
    const entry: ShortcutEntry = { ...s, all_keys: [...s.all_keys], aliases: [...s.aliases] };
    delete entry.conflict_with;
    for (const k of s.all_keys) {
      const owners = byKeys.get(k) ?? [];
      // Arc ships ⌥⌘N twice (Little Open and the global hotkey).
      const other = owners.find((o) => o !== s.id);
      if (other && !(k === 'Mod+Alt+N')) entry.conflict_with = other;
    }
    return entry;
  });
  const state: ShortcutsState = {
    shortcuts,
    priority: st.shortcutPriority,
    counts: {
      modified: shortcuts.filter((s) => s.modified).length,
      unassigned: shortcuts.filter((s) => !s.keys).length,
      conflicts: shortcuts.filter((s) => s.conflict_with).length,
    },
  };
  if (conflict) state.conflict = conflict;
  return state;
}

// --- Sync ----------------------------------------------------------------------------

function syncResult(x: ExtraState, extraFields: Partial<SyncMutationResult> = {}): SyncMutationResult {
  return { status: cloneSync(x.sync), needs_initial_choice: x.sync.initial_sync_required, ...extraFields };
}

function cloneSync(s: SyncDetailedStatus): SyncDetailedStatus {
  return {
    ...s,
    devices: s.devices.map((d) => ({ ...d })),
    categories: { ...s.categories },
    pending_extensions: [...s.pending_extensions],
    warnings: [...s.warnings],
  };
}

function signedInDevices(): SyncDevice[] {
  const now = Date.now() / 1000;
  return [
    { id: 'device-this', name: 'This Mac', platform: 'macOS', is_current: true, last_seen_at: now },
    { id: 'device-studio', name: 'Studio Desktop', platform: 'Windows', is_current: false, last_seen_at: now - 7200 },
    { id: 'device-laptop', name: 'ThinkPad', platform: 'Linux', is_current: false, last_seen_at: now - 86400 * 3 },
  ];
}

function validServer(url: string): boolean {
  try {
    const u = new URL(url.trim());
    return (u.protocol === 'http:' || u.protocol === 'https:') && !u.search && !u.hash && !u.username;
  } catch {
    return false;
  }
}

// --- Import --------------------------------------------------------------------------

const IMPORT_SOURCES: ImportSource[] = [
  { id: 'open-legacy/OpenLegacy', kind: 'open_legacy', browser_id: 'open-legacy', browser_name: 'Open (Legacy)', profile_name: 'Open (Legacy)', is_default: true, bookmarks_count: 214, history_count: 18320, access_denied: false, read_only: true },
  { id: 'arc/Arc', kind: 'arc', browser_id: 'arc', browser_name: 'Arc', profile_name: 'Arc', is_default: true, bookmarks_count: 162, history_count: 22410, access_denied: false, read_only: false },
  { id: 'safari/Safari', kind: 'safari', browser_id: 'safari', browser_name: 'Safari', profile_name: 'Safari', is_default: true, bookmarks_count: 0, history_count: 0, access_denied: true, access_error: 'Full Disk Access required to read Safari data', read_only: false },
  { id: 'chrome/Default', kind: 'chromium', browser_id: 'chrome', browser_name: 'Google Chrome', profile_name: 'Person 1', is_default: true, bookmarks_count: 88, history_count: 1205, access_denied: false, read_only: false },
  { id: 'brave/Default', kind: 'chromium', browser_id: 'brave', browser_name: 'Brave', profile_name: 'Default', is_default: true, bookmarks_count: 31, history_count: 402, access_denied: false, read_only: false },
  { id: 'firefox/default-release', kind: 'firefox', browser_id: 'firefox', browser_name: 'Firefox', profile_name: 'default-release', is_default: true, bookmarks_count: 19, history_count: 310, access_denied: false, read_only: false },
];

function receiptCounts(source: ImportSource | undefined, kinds: ImportKind[]): Record<string, number> {
  const has = (k: ImportKind) => kinds.includes(k);
  const bulk = source?.kind === 'arc' || source?.kind === 'open_legacy';
  return {
    bookmarks: has('bookmarks') ? (bulk ? 0 : source?.bookmarks_count ?? 12) : 0,
    spaces: bulk && has('spaces') ? 4 : 0,
    tabs: bulk && has('spaces') ? source?.bookmarks_count ?? 0 : 0,
    boosts: bulk && has('boosts') ? 3 : 0,
    documents: bulk && has('documents') ? 5 : 0,
    archive: bulk && has('archive') ? 120 : 0,
    history: has('history') ? Math.min(source?.history_count ?? 0, 50000) : 0,
    preferences: source?.kind === 'open_legacy' && has('settings') ? 14 : 0,
    shortcuts: source?.kind === 'open_legacy' && has('settings') ? 6 : 0,
  };
}

// --- Spaces ----------------------------------------------------------------------------

function settingsSpaces(st: PreviewState): SettingsSpace[] {
  return st.spaces.map((s) => ({
    ...s,
    accent: hex(s.style.key_color),
    bg: hex(mix(s.style.key_color, { r: 1, g: 1, b: 1 }, 0.84)),
    display_title: s.title || 'Space',
  }));
}

function profileCopy(p: ProfileSummary): ProfileSummary {
  return { ...p, icon: { ...p.icon }, settings: { ...p.settings, custom_search_engines: [...p.settings.custom_search_engines] } };
}

function needProfile(st: PreviewState, id: string): ProfileSummary {
  const p = st.profiles.find((x) => x.id === id);
  if (!p) throw new Error('no such profile');
  return p;
}

function recountSpaces(st: PreviewState): void {
  for (const p of st.profiles) p.space_count = st.spaces.filter((s) => s.profile_id === p.id).length;
}

// --- Dispatcher ------------------------------------------------------------------------

export async function previewSettingsRpc<M extends keyof SettingsRpcRequestMap>(
  ctx: PreviewContext,
  method: M,
  payload: SettingsRpcRequestMap[M],
): Promise<SettingsRpcResponseMap[M]> {
  const { st } = ctx;
  const x = extraState(st);
  const out = <K extends keyof SettingsRpcResponseMap>(value: SettingsRpcResponseMap[K]) =>
    value as unknown as SettingsRpcResponseMap[M];
  const p = payload as Record<string, unknown>;
  const str = (k: string) => (typeof p[k] === 'string' ? (p[k] as string) : '');

  switch (method as keyof SettingsRpcRequestMap) {
    case 'settings.getTheme':
      return out<'settings.getTheme'>(previewTheme(st));
    case 'settings.openChromeUrl': {
      const url = str('url');
      if (!/^chrome:\/\/(settings|password-manager|extensions|history|downloads|credits)\b/.test(url) && !url.startsWith('https://chromewebstore.google.com')) {
        throw new Error('that page cannot be opened from Settings');
      }
      window.open(url, '_blank', 'noopener');
      return out<'settings.openChromeUrl'>({ ok: true });
    }
    case 'settings.pickFolder': {
      const path = window.prompt('Folder path (native folder picker in Open)', str('default_path') || '~/Downloads');
      return out<'settings.pickFolder'>(path ? { canceled: false, path } : { canceled: true });
    }
    case 'settings.pickDownloadFolder': {
      const profile = needProfile(st, str('profile_id'));
      const path = window.prompt('Download folder (native folder picker in Open)', profile.settings.download_directory);
      if (!path) return out<'settings.pickDownloadFolder'>({ canceled: true, preferences: previewPreferences(st, ctx.defaults, profile.id) });
      profile.settings.download_directory = path;
      return out<'settings.pickDownloadFolder'>({ canceled: false, path, preferences: previewPreferences(st, ctx.defaults, profile.id) });
    }
    case 'settings.exportSnapshot': {
      const d = new Date();
      const stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      return out<'settings.exportSnapshot'>({ ok: true, path: `~/Downloads/Open-Snapshot-${stamp}.json` });
    }

    // Profiles
    case 'settings.profiles.list':
      return out<'settings.profiles.list'>({
        profiles: st.profiles.map(profileCopy),
        active_profile_id: st.profiles[0]?.id ?? '',
        page_profile_id: st.profiles[0]?.id ?? '',
      });
    case 'settings.profiles.switch': {
      const profile = needProfile(st, str('profile_id'));
      return out<'settings.profiles.switch'>({
        profile_id: profile.id,
        profile: profileCopy(profile),
        preferences: previewPreferences(st, ctx.defaults, profile.id),
        adblock: ctx.buildAdBlockState(st, profile.id),
        extensions: st.extensions.map((e) => ({ ...e, has_options: e.name !== 'Dark Reader', is_adblocker: /ublock|adblock|adguard|ghostery|privacy badger/i.test(e.name) })),
      });
    }
    case 'settings.profiles.create': {
      const name = str('name').trim();
      if (!name || name.length > 64) throw new Error('a profile name of 1-64 characters is needed');
      if (st.profiles.some((x2) => x2.name.toLowerCase() === name.toLowerCase())) throw new Error('that profile name is not available');
      const req = payload as SettingsRpcRequestMap['settings.profiles.create'];
      const profile: ProfileSummary = {
        id: `profile-${Math.random().toString(16).slice(2, 10)}`,
        name,
        icon: req.icon ?? { kind: 'named', value: 'person' },
        data_directory_name: `Profile_${name.replace(/\W+/g, '_')}`,
        is_default: false,
        space_count: 0,
        favorites_count: 0,
        settings: {
          auto_archive_after: '12h',
          little_open_auto_archive_after: '6h',
          search_suggest_enabled: true,
          download_directory: '~/Downloads',
          ask_where_to_save_each_file: false,
          search_engine_id: 'google',
          custom_search_engines: [],
          sleep_mode: 'balanced',
          keep_alive_sites: [],
          default_document_app: 'note',
        },
      };
      st.profiles.push(profile);
      return out<'settings.profiles.create'>({ profile: profileCopy(profile) });
    }
    case 'settings.profiles.rename': {
      const profile = needProfile(st, str('profile_id'));
      const name = str('name').trim();
      if (!name || name.length > 64) throw new Error('cannot rename profile');
      if (st.profiles.some((x2) => x2.id !== profile.id && x2.name.toLowerCase() === name.toLowerCase())) throw new Error('cannot rename profile');
      profile.name = name;
      const req = payload as SettingsRpcRequestMap['settings.profiles.rename'];
      if (req.icon) profile.icon = req.icon;
      return out<'settings.profiles.rename'>({ profile: profileCopy(profile) });
    }
    case 'settings.profiles.setIcon': {
      const profile = needProfile(st, str('profile_id'));
      profile.icon = (payload as SettingsRpcRequestMap['settings.profiles.setIcon']).icon;
      return out<'settings.profiles.setIcon'>({ profile: profileCopy(profile) });
    }
    case 'settings.profiles.setSearchEngine': {
      const profile = needProfile(st, str('profile_id'));
      const id = str('engine_id');
      if (!BUILTIN_SEARCH_ENGINES.some((e) => e.id === id) && !profile.settings.custom_search_engines.some((e) => e.id === id)) {
        throw new Error('unknown search engine');
      }
      profile.settings.search_engine_id = id;
      return out<'settings.profiles.setSearchEngine'>({ profile: profileCopy(profile) });
    }
    case 'settings.profiles.setCustomSearchEngines': {
      const profile = needProfile(st, str('profile_id'));
      const req = payload as SettingsRpcRequestMap['settings.profiles.setCustomSearchEngines'];
      const keywords = new Set<string>();
      const engines = req.engines.map((e) => {
        const keyword = e.keyword.trim().toLowerCase();
        let ok = false;
        try {
          const u = new URL(e.url_template.trim());
          ok = (u.protocol === 'https:' || u.protocol === 'http:') && e.url_template.includes('%s');
        } catch {
          ok = false;
        }
        if (!e.name.trim() || !keyword || /\s/.test(keyword) || !ok) {
          throw new Error('Each engine needs a name, a one-word keyword, and an http(s) URL with %s where the search goes.');
        }
        if (keywords.has(keyword)) throw new Error(`The keyword "${keyword}" is used twice.`);
        keywords.add(keyword);
        return { id: e.id || `engine-${Math.random().toString(16).slice(2, 10)}`, name: e.name.trim(), keyword, url_template: e.url_template.trim() };
      });
      profile.settings.custom_search_engines = engines;
      if (!BUILTIN_SEARCH_ENGINES.some((e) => e.id === profile.settings.search_engine_id) && !engines.some((e) => e.id === profile.settings.search_engine_id)) {
        profile.settings.search_engine_id = 'google';
      }
      return out<'settings.profiles.setCustomSearchEngines'>({ profile: profileCopy(profile) });
    }
    case 'settings.profiles.delete': {
      const profile = needProfile(st, str('profile_id'));
      if (str('confirm_name') !== profile.name) throw new Error('the confirmation does not match the name');
      if (profile.is_default || st.profiles[0]?.id === profile.id) throw new Error('the default profile cannot be deleted');
      const moveTo = str('move_spaces_to');
      if (moveTo && moveTo !== profile.id && st.profiles.some((x2) => x2.id === moveTo)) {
        for (const s of st.spaces) if (s.profile_id === profile.id) s.profile_id = moveTo;
      }
      if (st.spaces.some((s) => s.profile_id === profile.id)) throw new Error("move or delete this profile's spaces first");
      st.profiles = st.profiles.filter((x2) => x2.id !== profile.id);
      recountSpaces(st);
      return out<'settings.profiles.delete'>({ ok: true });
    }
    case 'settings.profiles.cleanupUnused': {
      const unused = st.profiles.filter((x2, i) => i > 0 && !st.spaces.some((s) => s.profile_id === x2.id));
      const dryRun = p.dry_run !== false;
      if (!dryRun) st.profiles = st.profiles.filter((x2) => !unused.includes(x2));
      return out<'settings.profiles.cleanupUnused'>({
        profiles: unused.map((x2) => ({ id: x2.id, name: x2.name })),
        orphan_directories: dryRun ? ['Profile_Old_Test'] : [],
        deleted: !dryRun,
      });
    }

    // Spaces
    case 'settings.spaces.list':
      return out<'settings.spaces.list'>({ spaces: settingsSpaces(st) });
    case 'settings.spaces.create': {
      const profile = needProfile(st, str('profile_id'));
      const title = str('title').trim();
      if (title.length > 64) throw new Error('cannot create that space');
      const base = st.spaces[0]?.style;
      if (!base) throw new Error('cannot create that space');
      st.spaces.push({
        id: `space-${Math.random().toString(16).slice(2, 10)}`,
        title: title || 'New Space',
        icon: { kind: 'named', value: 'circle' },
        profile_id: profile.id,
        style: { ...base, key_color: { r: 0.55, g: 0.36, b: 0.96, a: 1 } },
        pinned_count: 0,
        today_count: 0,
      });
      recountSpaces(st);
      return out<'settings.spaces.create'>({ spaces: settingsSpaces(st) });
    }
    case 'settings.spaces.rename': {
      const space = st.spaces.find((s) => s.id === str('space_id'));
      const title = str('title').trim();
      if (!space || !title || title.length > 64) throw new Error('cannot rename that space');
      space.title = title;
      return out<'settings.spaces.rename'>({ spaces: settingsSpaces(st) });
    }
    case 'settings.spaces.setProfile': {
      const space = st.spaces.find((s) => s.id === str('space_id'));
      const profile = needProfile(st, str('profile_id'));
      if (!space) throw new Error('cannot move that space');
      space.profile_id = profile.id;
      recountSpaces(st);
      return out<'settings.spaces.setProfile'>({ spaces: settingsSpaces(st) });
    }

    // Air Traffic Control
    case 'settings.atc.get':
      return out<'settings.atc.get'>(atcState(st));
    case 'settings.atc.setDefaultDestination': {
      const dest = (payload as SettingsRpcRequestMap['settings.atc.setDefaultDestination']).destination;
      if (dest.kind === 'space' && !st.spaces.some((s) => s.id === dest.space_id)) throw new Error('choose an existing Space or Little Open');
      st.defaultRoutingDestination = { ...dest };
      return out<'settings.atc.setDefaultDestination'>(atcState(st));
    }
    case 'settings.atc.addRule':
    case 'settings.atc.updateRule': {
      const rule = { ...(payload as SettingsRpcRequestMap['settings.atc.addRule']).rule };
      rule.host_pattern = rule.host_pattern.trim().toLowerCase();
      const error = validateRule(st, rule);
      if (error) throw new Error(error);
      if (!rule.name) rule.name = rule.host_pattern;
      if (method === 'settings.atc.addRule') {
        rule.id = `rule-${Math.random().toString(16).slice(2, 10)}`;
        st.routingRules.push(rule);
        return out<'settings.atc.addRule'>({ ...atcState(st), rule_id: rule.id });
      }
      const idx = st.routingRules.findIndex((r) => r.id === rule.id);
      if (idx < 0) throw new Error('no such rule');
      st.routingRules[idx] = rule;
      return out<'settings.atc.updateRule'>(atcState(st));
    }
    case 'settings.atc.deleteRule': {
      const before = st.routingRules.length;
      st.routingRules = st.routingRules.filter((r) => r.id !== str('id'));
      if (st.routingRules.length === before) throw new Error('no such rule');
      return out<'settings.atc.deleteRule'>(atcState(st));
    }
    case 'settings.atc.reorderRules': {
      const ids = (payload as SettingsRpcRequestMap['settings.atc.reorderRules']).ids;
      if (ids.length !== st.routingRules.length) throw new Error('the rule order does not match the rules');
      const ordered = ids.map((id) => st.routingRules.find((r) => r.id === id));
      if (ordered.some((r) => !r) || new Set(ids).size !== ids.length) throw new Error('the rule order does not match the rules');
      st.routingRules = ordered as RoutingRule[];
      return out<'settings.atc.reorderRules'>(atcState(st));
    }
    case 'settings.atc.listRunningApps':
      return out<'settings.atc.listRunningApps'>({
        supported: true,
        apps: [
          { id: 'com.apple.mail', name: 'Mail' },
          { id: 'com.apple.MobileSMS', name: 'Messages' },
          { id: 'com.apple.Notes', name: 'Notes' },
          { id: 'com.linear', name: 'Linear' },
          { id: 'notion.id', name: 'Notion' },
          { id: 'com.tinyspeck.slackmacgap', name: 'Slack' },
          { id: 'us.zoom.xos', name: 'zoom.us' },
        ],
      });
    case 'settings.atc.testUrl': {
      let url = str('url').trim();
      if (url && !url.includes('://')) url = `https://${url}`;
      try {
        new URL(url);
      } catch {
        throw new Error('Enter a full link, such as https://example.com.');
      }
      const info = decision(st, url, str('source_app_id') || undefined, Date.now() / 1000);
      return out<'settings.atc.testUrl'>(info);
    }
    case 'settings.atc.recentDecisions':
      return out<'settings.atc.recentDecisions'>({ decisions: x.routingLog.map((d) => ({ ...d, traces: [...d.traces] })) });

    // Shortcuts
    case 'settings.shortcuts.list':
      return out<'settings.shortcuts.list'>(shortcutsState(st, x));
    case 'settings.shortcuts.set':
    case 'settings.shortcuts.clear': {
      const entry = x.shortcuts.find((s) => s.id === str('id'));
      if (!entry) throw new Error('unknown command or shortcut');
      const keys = method === 'settings.shortcuts.clear' ? '' : str('keys');
      entry.keys = keys;
      entry.all_keys = keys ? [keys] : [];
      entry.modified = keys !== entry.default_keys;
      const other = keys ? x.shortcuts.find((s) => s.id !== entry.id && s.all_keys.includes(keys)) : undefined;
      return out<'settings.shortcuts.set'>(shortcutsState(st, x, other?.id));
    }
    case 'settings.shortcuts.reset': {
      const entry = x.shortcuts.find((s) => s.id === str('id'));
      if (!entry) throw new Error('unknown command');
      entry.keys = entry.default_keys;
      entry.all_keys = entry.default_keys ? [entry.default_keys] : [];
      entry.modified = false;
      entry.priority = entry.default_priority;
      return out<'settings.shortcuts.reset'>(shortcutsState(st, x));
    }
    case 'settings.shortcuts.resetAll':
      for (const entry of x.shortcuts) {
        entry.keys = entry.default_keys;
        entry.all_keys = entry.default_keys ? [entry.default_keys] : [];
        entry.modified = false;
        entry.priority = entry.default_priority;
      }
      return out<'settings.shortcuts.resetAll'>(shortcutsState(st, x));
    case 'settings.shortcuts.setPriority': {
      const priority = str('priority');
      const id = str('id');
      if (!id) {
        if (priority !== 'open' && priority !== 'website') throw new Error('unknown priority');
        st.shortcutPriority = priority;
        st.preferences['shortcuts.priority'] = priority;
      } else {
        const entry = x.shortcuts.find((s) => s.id === id);
        if (!entry || !['browser', 'site', 'site-then-browser'].includes(priority)) throw new Error('unknown command or priority');
        entry.priority = priority as ShortcutEntry['priority'];
        entry.modified = true;
      }
      return out<'settings.shortcuts.setPriority'>(shortcutsState(st, x));
    }
    case 'settings.shortcuts.exportJson':
      return out<'settings.shortcuts.exportJson'>({ ok: true, path: '~/Downloads/Open-Shortcuts.json' });
    case 'settings.shortcuts.importJson': {
      const text = str('json');
      if (!text) return out<'settings.shortcuts.importJson'>({ ...shortcutsState(st, x), ok: false, canceled: true });
      let root: { version?: number; bindings?: Record<string, { shortcuts?: { key: string; modifiers: string[] }[] }> };
      try {
        root = JSON.parse(text) as typeof root;
      } catch {
        throw new Error('That file is not valid JSON.');
      }
      if (root.version !== 1 || !root.bindings) throw new Error('This is not an Open shortcuts file (unsupported version).');
      let applied = 0;
      let skipped = 0;
      for (const [id, binding] of Object.entries(root.bindings)) {
        const entry = x.shortcuts.find((s) => s.id === id);
        if (!entry) {
          skipped += 1;
          continue;
        }
        const first = binding.shortcuts?.[0];
        const mods = (first?.modifiers ?? []).map((m) => (m === 'command' || m === 'cmd' ? 'Mod' : m.charAt(0).toUpperCase() + m.slice(1)));
        entry.keys = first ? [...mods, first.key.toUpperCase()].join('+') : '';
        entry.all_keys = entry.keys ? [entry.keys] : [];
        entry.modified = true;
        applied += 1;
      }
      return out<'settings.shortcuts.importJson'>({ ...shortcutsState(st, x), ok: true, applied, skipped });
    }

    // Ad blocking
    case 'settings.adblock.get':
      return out<'settings.adblock.get'>(adblockState(ctx, x, str('profile_id')));
    case 'settings.adblock.updateNow':
    case 'settings.adblock.resetLists': {
      const profileId = str('profile_id');
      if (method === 'settings.adblock.resetLists') {
        st.adBlockEnabledListsByProfile[profileId] = new Set(
          ctx.buildAdBlockState(st, profileId).lists.filter((l) => l.default_enabled).map((l) => l.id),
        );
      }
      await new Promise((r) => setTimeout(r, 900));
      st.adBlockGeneration += 1;
      const state = { ...adblockState(ctx, x, profileId), update_ok: true };
      ctx.emit('open.adBlockUpdated', state);
      return out<'settings.adblock.updateNow'>(state);
    }
    case 'settings.adblock.setCustomRules': {
      const rules = str('rules');
      if (rules.length > 256 * 1024) throw new Error('custom rules must be under 256 KB');
      x.customRules[str('profile_id')] = rules;
      return out<'settings.adblock.setCustomRules'>({ ...adblockState(ctx, x, str('profile_id')), update_ok: true });
    }
    case 'settings.adblock.copyDebugInfo': {
      const s = adblockState(ctx, x, str('profile_id'));
      const text = [
        'Open Ad Blocking debug info',
        'Open 0.2.0, Chromium 156.0.8078.48',
        `Enabled: ${s.global_enabled ? 'yes' : 'no'}`,
        `Generation: ${s.generation}`,
        `Enabled lists: ${s.lists.filter((l) => l.enabled).map((l) => l.id).join(', ')}`,
        `Allowed sites: ${s.exclusions.length}`,
      ].join('\n');
      return out<'settings.adblock.copyDebugInfo'>({ ok: true, text });
    }
    case 'settings.adblock.detectConflictingExtensions':
      return out<'settings.adblock.detectConflictingExtensions'>({
        conflicts: st.extensions
          .filter((e) => /ublock|adblock|adguard|ghostery|privacy badger/i.test(e.name))
          .map((e) => ({ id: e.id, name: e.name, enabled: e.enabled })),
      });

    // Extensions
    case 'settings.extensions.remove': {
      const before = st.extensions.length;
      st.extensions = st.extensions.filter((e) => e.id !== str('id'));
      if (before === st.extensions.length) throw new Error('no such extension');
      return out<'settings.extensions.remove'>({ profile_id: str('profile_id'), extensions: st.extensions.map((e) => ({ ...e })) });
    }
    case 'settings.extensions.openOptions':
      return out<'settings.extensions.openOptions'>({ ok: true });

    // Account & Sync
    case 'settings.sync.getStatus':
      return out<'settings.sync.getStatus'>(cloneSync(x.sync));
    case 'settings.sync.signIn':
    case 'settings.sync.signUp':
    case 'settings.sync.recover': {
      if (!validServer(str('server_url'))) throw new Error('Enter your server address, email, and password.');
      if (!str('email').includes('@')) throw new Error('Enter a valid email.');
      if (method !== 'settings.sync.signIn' && str('password').length < 8 && str('new_password').length < 8) {
        throw new Error('Enter a server address, an email, and a password of at least 8 characters.');
      }
      if (method === 'settings.sync.signIn' && str('password') === 'wrong-password') throw new Error('The email or password is not correct.');
      await new Promise((r) => setTimeout(r, 500));
      const signUp = method === 'settings.sync.signUp';
      x.sync = {
        ...x.sync,
        signed_in: true,
        state: signUp ? 'idle' : 'awaitingInitialChoice',
        email: str('email'),
        display_name: str('display_name') || str('email').split('@')[0] || '',
        server_url: str('server_url').trim(),
        device_id: 'device-this',
        devices: signedInDevices(),
        ws_connected: signUp,
        initial_sync_required: !signUp,
        last_sync_at_ms: signUp ? Date.now() : undefined,
      } as SyncDetailedStatus;
      if (!signUp) {
        x.sync.cloud_summary = { server_revision: 42, has_cloud_data: true, collection_counts: { 'workspace.space': 6, 'workspace.today': 38, 'boost.item': 4 } };
      }
      return out<'settings.sync.signIn'>(
        syncResult(x, signUp ? { recovery_key: 'OPEN-7K2Q-M4XD-91TF-PL0Z-HV3C-WN8E' } : {}),
      );
    }
    case 'settings.sync.completeInitialSync': {
      x.sync = { ...x.sync, state: 'idle', initial_sync_required: false, ws_connected: true, last_sync_at_ms: Date.now() };
      delete x.sync.cloud_summary;
      return out<'settings.sync.completeInitialSync'>(syncResult(x));
    }
    case 'settings.sync.syncNow':
      if (!x.sync.signed_in) throw new Error('Sign in to sync.');
      await new Promise((r) => setTimeout(r, 600));
      x.sync = { ...x.sync, last_sync_at_ms: Date.now(), pending_push_count: 0, ws_connected: true, last_pulled_revision: x.sync.last_pulled_revision + 1 };
      return out<'settings.sync.syncNow'>(syncResult(x));
    case 'settings.sync.signOut':
      x.sync = signedOutSync(st);
      return out<'settings.sync.signOut'>(syncResult(x));
    case 'settings.sync.changePassword':
      if (str('new_password').length < 8) throw new Error('Enter your current password and a new one of at least 8 characters.');
      return out<'settings.sync.changePassword'>(syncResult(x));
    case 'settings.sync.updateDisplayName':
      x.sync = { ...x.sync, display_name: str('display_name').trim() };
      return out<'settings.sync.updateDisplayName'>(syncResult(x));
    case 'settings.sync.deleteAccount':
      if (!str('password')) throw new Error('Enter your password to delete the account.');
      x.sync = signedOutSync(st);
      return out<'settings.sync.deleteAccount'>(syncResult(x));
    case 'settings.sync.revokeDevice':
      x.sync = { ...x.sync, devices: x.sync.devices.filter((d) => d.id !== str('device_id') || d.is_current) };
      return out<'settings.sync.revokeDevice'>(syncResult(x));
    case 'settings.sync.setServerUrl':
      if (x.sync.signed_in) throw new Error('Sign out before you change the server.');
      if (!validServer(str('server_url'))) throw new Error('Enter a server address such as https://sync.example.com.');
      x.sync = { ...x.sync, server_url: str('server_url').trim() };
      return out<'settings.sync.setServerUrl'>(cloneSync(x.sync));
    case 'settings.sync.setCategory':
      if (!(str('category') in x.sync.categories)) throw new Error('unknown sync category');
      x.sync = { ...x.sync, categories: { ...x.sync.categories, [str('category')]: p.enabled === true } };
      return out<'settings.sync.setCategory'>(cloneSync(x.sync));

    // Import
    case 'settings.import.detect':
      return out<'settings.import.detect'>({ sources: IMPORT_SOURCES.map((s) => ({ ...s })) });
    case 'settings.import.pickHtml':
      return out<'settings.import.pickHtml'>({ canceled: false, path: '~/Downloads/bookmarks_11_26_26.html', name: 'bookmarks_11_26_26.html' });
    case 'settings.import.run': {
      const req = payload as SettingsRpcRequestMap['settings.import.run'];
      const source = IMPORT_SOURCES.find((s) => s.id === req.source_id);
      if (!source && req.source_id !== 'html') throw new Error('That browser profile was not found.');
      if (source?.access_denied) {
        return out<'settings.import.run'>({ ok: false, access_denied: true, error: 'Open needs Full Disk Access to read Safari.' });
      }
      ctx.emit('open.importProgress', { source_id: req.source_id, phase: 'reading' });
      await new Promise((r) => setTimeout(r, 800));
      const receipt: ImportReceiptInfo = {
        receipt_id: `receipt-${Math.random().toString(16).slice(2, 10)}`,
        source_name: source?.browser_name ?? 'Bookmarks File',
        source_kind: source?.kind ?? 'html',
        imported_at: Date.now() / 1000,
        counts: req.source_id === 'html' ? { bookmarks: 57 } : receiptCounts(source, req.kinds),
        undone: false,
      };
      x.receipts.unshift(receipt);
      ctx.emit('open.importProgress', { source_id: req.source_id, phase: 'done' });
      return out<'settings.import.run'>({ ok: true, receipt });
    }
    case 'settings.import.undo': {
      const receipt = x.receipts.find((r) => r.receipt_id === str('receipt_id'));
      if (!receipt || receipt.undone) throw new Error('That import cannot be undone.');
      receipt.undone = true;
      return out<'settings.import.undo'>({ ok: true, receipt: { ...receipt } });
    }
    case 'settings.import.receipts':
      return out<'settings.import.receipts'>({ receipts: x.receipts.map((r) => ({ ...r })) });

    // About
    case 'settings.about.get': {
      const info: AboutInfo = {
        app_version: '0.2.0',
        chromium_version: '156.0.8078.48',
        platform: navigator.platform.toLowerCase().includes('mac') ? 'macOS' : navigator.platform.toLowerCase().includes('win') ? 'Windows' : 'Linux',
        os_version: navigator.userAgent.replace(/^.*?\(([^)]*)\).*$/, '$1'),
        architecture: 'arm64',
        data_folder: '~/Library/Application Support/Open Unified',
        widevine: {
          session_enabled: false,
          preference: st.preferences['advanced.widevine'] === true,
          restart_required: st.preferences['advanced.widevine'] === true,
        },
      };
      return out<'settings.about.get'>(info);
    }
    case 'settings.about.showDataFolder':
      return out<'settings.about.showDataFolder'>({ ok: true });
    case 'settings.about.copySystemInfo': {
      const text = `Open Unified 0.2.0\nChromium 156.0.8078.48\nOS: ${navigator.userAgent}\nProfiles: ${st.profiles.length}, Spaces: ${st.spaces.length}\n`;
      return out<'settings.about.copySystemInfo'>({ ok: true, text });
    }
    case 'settings.about.checkForUpdates':
      return out<'settings.about.checkForUpdates'>({
        status: 'unavailable',
        current_version: '0.2.0',
        message: 'This build of Open cannot check for updates by itself. New versions are published as downloads.',
      });
    case 'settings.about.replayOnboarding':
      return out<'settings.about.replayOnboarding'>({ ok: true });
  }
  throw new Error(`unknown method ${String(method)}`);
}

function adblockState(ctx: PreviewContext, x: ExtraState, profileId: string): AdBlockState {
  const base = ctx.buildAdBlockState(ctx.st, profileId || ctx.st.profiles[0]?.id || '');
  const lists = base.lists.map((l) => {
    const item = { ...l };
    if (l.bundled) {
      item.source = ctx.st.adBlockGeneration > 3 ? 'downloaded' : 'bundled';
      item.bytes = l.id === 'EasyList' ? 1_912_330 : 1_204_882;
    }
    if (l.id === 'IDN-0') item.error = 'HTTP 404 from the list server';
    return item;
  });
  const enabled = lists.filter((l) => l.enabled);
  return {
    ...base,
    lists,
    is_updating: x.updating,
    engine_loaded: base.global_enabled,
    engine_list_count: enabled.length,
    active_rules: enabled.reduce((n, l) => n + (l.rule_count ?? 0), 0),
    last_updated_at: Math.max(0, ...enabled.map((l) => l.last_updated_at ?? 0)) || Date.now() / 1000 - 1800,
    custom_rules: x.customRules[profileId] ?? '',
  };
}
