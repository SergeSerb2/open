// Typed RPC bridge matching Unified/src/open_unified/ui/webui/open_ipc_contract.h verbatim.
// Uses Chromium WebUI chrome.send("open.rpc", [id, method, payload]) when available,
// and falls back to an interactive in-memory preview adapter when running outside Chromium.

import { ADBLOCK_CATALOG, type AdBlockCatalogEntry, type AdBlockListCategory } from './catalog';

export const OPEN_SCHEME = 'open' as const;

export const OPEN_HOSTS = {
  settings: 'settings',
  library: 'library',
  boosts: 'boosts',
  easel: 'easel',
  note: 'note',
  onboarding: 'onboarding',
  welcome: 'welcome',
} as const;

export const RPC_MESSAGE_NAME = 'open.rpc' as const;

export const RPC_METHODS = {
  // Settings
  settingsGetAll: 'settings.getAll',
  settingsSetPreference: 'settings.setPreference',
  settingsResetPreference: 'settings.resetPreference',
  settingsListProfiles: 'settings.listProfiles',
  settingsCreateProfile: 'settings.createProfile',
  settingsRenameProfile: 'settings.renameProfile',
  settingsDeleteProfile: 'settings.deleteProfile',
  settingsGetShortcuts: 'settings.getShortcuts',
  settingsSetShortcut: 'settings.setShortcut',
  settingsResetShortcut: 'settings.resetShortcut',
  settingsGetRoutingRules: 'settings.getRoutingRules',
  settingsSaveRoutingRule: 'settings.saveRoutingRule',
  settingsDeleteRoutingRule: 'settings.deleteRoutingRule',
  settingsTestRoutingUrl: 'settings.testRoutingUrl',
  settingsGetAdBlockState: 'settings.getAdBlockState',
  settingsSetAdBlockEnabled: 'settings.setAdBlockEnabled',
  settingsToggleAdBlockList: 'settings.toggleAdBlockList',
  settingsAddAdBlockExclusion: 'settings.addAdBlockExclusion',
  settingsRemoveAdBlockExclusion: 'settings.removeAdBlockExclusion',
  settingsClearBrowsingData: 'settings.clearBrowsingData',
  settingsSetDefaultBrowser: 'settings.setDefaultBrowser',
  settingsGetExtensions: 'settings.getExtensions',
  settingsToggleExtension: 'settings.toggleExtension',

  // Account & Sync
  syncGetStatus: 'sync.getStatus',
  syncConfigureServer: 'sync.configureServer',
  syncRegister: 'sync.register',
  syncLogin: 'sync.login',
  syncLogout: 'sync.logout',
  syncTriggerNow: 'sync.triggerNow',
  syncRecover: 'sync.recover',
  syncListDevices: 'sync.listDevices',
  syncRevokeDevice: 'sync.revokeDevice',

  // Library
  libraryGetHistory: 'library.getHistory',
  libraryDeleteHistory: 'library.deleteHistory',
  libraryGetArchive: 'library.getArchive',
  libraryRestoreArchived: 'library.restoreArchived',
  libraryGetDownloads: 'library.getDownloads',
  libraryOpenDownload: 'library.openDownload',
  libraryGetSpaces: 'library.getSpaces',
  libraryUpdateSpace: 'library.updateSpace',
  libraryDeleteSpace: 'library.deleteSpace',
  libraryGetMedia: 'library.getMedia',
  libraryGetEasels: 'library.getEasels',
  libraryOpenUrl: 'library.openUrl',

  // Boosts & Zap
  boostsList: 'boosts.list',
  boostsSave: 'boosts.save',
  boostsDelete: 'boosts.delete',
  boostsToggle: 'boosts.toggle',
  boostsStartZap: 'boosts.startZap',
  boostsRemoveZap: 'boosts.removeZap',

  // Documents (Easel & Note)
  easelLoad: 'easel.load',
  easelSave: 'easel.save',
  easelExportHtml: 'easel.exportHtml',
  noteLoad: 'note.load',
  noteSave: 'note.save',

  // Onboarding, Welcome & Import
  onboardingGetState: 'onboarding.getState',
  onboardingComplete: 'onboarding.complete',
  importProbeBrowsers: 'import.probeBrowsers',
  importRun: 'import.run',
  welcomeTriggerAction: 'welcome.triggerAction',
} as const;

export type RpcMethod = (typeof RPC_METHODS)[keyof typeof RPC_METHODS];

export const RPC_EVENTS = {
  stateChanged: 'open.stateChanged',
  syncStatusChanged: 'open.syncStatusChanged',
  downloadUpdated: 'open.downloadUpdated',
  adBlockUpdated: 'open.adBlockUpdated',
  importProgress: 'open.importProgress',
} as const;

export type RpcEventName = (typeof RPC_EVENTS)[keyof typeof RPC_EVENTS];

// --- Canonical Shared Data Models (mirrors open_types.h) ---

export interface RGBAColor {
  r: number; // 0..1
  g: number; // 0..1
  b: number; // 0..1
  a: number; // 0..1
}

export type ThemeWheel = 'analogous' | 'complementary';
export type ThemeAppearance = 'automatic' | 'light' | 'dark';
export type ThemeTexture = 'grain' | 'sand' | 'denim' | 'tweed';

export interface SpaceStyle {
  math_version: number;
  key_color: RGBAColor;
  color_count: 1 | 2 | 3;
  wheel: ThemeWheel;
  appearance: ThemeAppearance;
  noise_factor: number; // 0..1
  texture: ThemeTexture;
  intensity_factor: number; // 0..1
}

export interface SpaceIcon {
  kind: 'emoji' | 'symbol' | 'named';
  value: string;
}

export interface SpaceSummary {
  id: string;
  title: string;
  icon: SpaceIcon;
  profile_id: string;
  style: SpaceStyle;
  pinned_count: number;
  today_count: number;
}

export interface CustomSearchEngine {
  id: string;
  name: string;
  keyword: string;
  url_template: string;
}

export interface ProfileSummary {
  id: string;
  name: string;
  icon: SpaceIcon;
  data_directory_name: string;
  is_default: boolean;
  space_count: number;
  favorites_count: number;
  settings: {
    auto_archive_after: string;
    little_open_auto_archive_after: string;
    search_suggest_enabled: boolean;
    download_directory: string;
    ask_where_to_save_each_file: boolean;
    search_engine_id: string;
    custom_search_engines: CustomSearchEngine[];
    sleep_mode: 'off' | 'conservative' | 'balanced' | 'aggressive';
    keep_alive_sites: string[];
  };
}

export interface ShortcutBinding {
  id: string;
  title: string;
  category: 'Tabs' | 'Navigation' | 'Spaces' | 'View' | 'Tools' | 'Window';
  keys: string; // e.g. "Mod+T"
  default_keys: string;
  conflict_with?: string;
}

export interface RoutingDestination {
  kind: 'space' | 'little_open' | 'most_recent_space';
  space_id?: string;
  profile_id?: string;
}

export interface RoutingRule {
  id: string;
  name: string;
  host_pattern: string;
  path_prefix?: string;
  source_app_id?: string;
  destination: RoutingDestination;
  enabled: boolean;
}

export interface RoutingTestResult {
  matched_rule_id?: string;
  matched_rule_name?: string;
  destination: RoutingDestination;
  explanation: string;
}

export interface AdBlockListItem extends AdBlockCatalogEntry {
  enabled: boolean;
  rule_count?: number;
  last_updated_at?: number;
}

export interface AdBlockState {
  profile_id: string;
  global_enabled: boolean;
  generation: number;
  lists: AdBlockListItem[];
  exclusions: string[];
  blocked_count_session: number;
  last_error?: string;
}

export interface ExtensionItem {
  id: string;
  name: string;
  version: string;
  description: string;
  enabled: boolean;
  pinned: boolean;
  permissions: string[];
}

export interface SyncDevice {
  id: string;
  name: string;
  platform: 'macOS' | 'Windows' | 'Linux';
  is_current: boolean;
  last_seen_at: number;
}

export interface SyncStatus {
  signed_in: boolean;
  email?: string;
  server_url: string;
  state: 'signed_out' | 'idle' | 'syncing' | 'error';
  last_sync_at?: number;
  revision: number;
  recovery_key_hint?: string;
  categories: Record<string, boolean>;
  error_message?: string;
  devices: SyncDevice[];
}

export interface HistoryEntry {
  id: number;
  url: string;
  title: string;
  visit_count: number;
  typed_count: number;
  last_visit: number;
  profile_id: string;
}

export interface ArchivedTabRecord {
  id: string;
  url: string;
  title: string;
  space_id?: string;
  space_title?: string;
  profile_id: string;
  archived_at: number;
  reason: 'closed' | 'auto-archive' | 'clear-today' | 'space-deleted';
  original_location: 'today' | 'pinned' | 'folder';
  kind: 'tab' | 'folder';
}

export interface DownloadRecord {
  id: string;
  url: string;
  filename: string;
  target_path: string;
  mime_type: string;
  state: 'in_progress' | 'completed' | 'cancelled' | 'interrupted';
  received_bytes: number;
  total_bytes: number;
  started_at: number;
  ended_at: number;
  profile_id: string;
}

export interface MediaCaptureRecord {
  id: string;
  title: string;
  source_url: string;
  captured_at: number;
  width: number;
  height: number;
  preview_gradient: string;
  profile_id: string;
}

export interface BoostColorAdjustment {
  enabled: boolean;
  hue_degrees: number; // -180..180
  saturation: number; // 0..2
  lightness: number; // -0.5..0.5
  contrast: number; // 0.5..2
  invert: boolean;
}

export interface ZappedElement {
  id: string;
  selector: string;
  label: string;
}

export interface Boost {
  id: string;
  profile_id: string;
  name: string;
  host_pattern: string;
  enabled: boolean;
  color: BoostColorAdjustment;
  font_family?: string;
  text_zoom: number; // 0.5..2.0
  text_transform: '' | 'uppercase' | 'lowercase' | 'capitalize';
  custom_css: string;
  custom_js: string;
  zapped_elements: ZappedElement[];
  created_at: number;
  modified_at: number;
}

export interface NoteFormatRange {
  type:
    | 'bold'
    | 'italic'
    | 'underline'
    | 'strikethrough'
    | 'h1'
    | 'h2'
    | 'h3'
    | 'link'
    | 'bulletList'
    | 'numberedList'
    | 'image';
  location: number; // UTF-16 offset
  length: number; // UTF-16 length
  url?: string;
  level?: number;
}

export interface NoteDocument {
  format_version: number;
  id: string;
  title: string;
  text: string;
  formats: NoteFormatRange[];
  created_at: number;
  modified_at: number;
}

export type EaselElementType =
  | 'text'
  | 'image'
  | 'rect'
  | 'ellipse'
  | 'arrow'
  | 'freehand'
  | 'live_card';

export interface EaselElement {
  id: string;
  type: EaselElementType;
  x: number;
  y: number;
  width: number;
  height: number;
  content: string;
  fill_color: string;
  stroke_color: string;
  stroke_width: number;
  font_size: number;
  z_index: number;
}

export interface EaselDocument {
  format_version: number;
  id: string;
  title: string;
  canvas_width: number;
  canvas_height: number;
  palette: 'vibrant' | 'chill';
  elements: EaselElement[];
  created_at: number;
  modified_at: number;
}

export interface EaselSummary {
  id: string;
  title: string;
  element_count: number;
  palette: 'vibrant' | 'chill';
  modified_at: number;
  profile_id: string;
}

export interface BrowserImportSource {
  id: string;
  browser_name: string;
  profile_name: string;
  bookmarks_count: number;
  history_count: number;
  extensions_count: number;
  passwords_count: number;
  favorites_count: number;
}

export interface SettingsSnapshot {
  preferences: Record<string, unknown>;
  defaults: Record<string, unknown>;
  is_default_browser: boolean;
  app_version: string;
  chromium_version: string;
  active_profile_id: string;
}

// --- RPC Method Type Map ---

export interface RpcRequestMap {
  'settings.getAll': { profile_id?: string };
  'settings.setPreference': { key: string; value: unknown; profile_id?: string; apply_all_profiles?: boolean };
  'settings.resetPreference': { key: string; profile_id?: string };
  'settings.listProfiles': Record<string, never>;
  'settings.createProfile': { name: string; icon?: SpaceIcon };
  'settings.renameProfile': { profile_id: string; name: string; icon?: SpaceIcon };
  'settings.deleteProfile': { profile_id: string; confirm_name: string };
  'settings.getShortcuts': Record<string, never>;
  'settings.setShortcut': { id: string; keys: string };
  'settings.resetShortcut': { id?: string; reset_all?: boolean };
  'settings.getRoutingRules': Record<string, never>;
  'settings.saveRoutingRule': { rule: RoutingRule; default_destination?: RoutingDestination };
  'settings.deleteRoutingRule': { id: string };
  'settings.testRoutingUrl': { url: string; source_app_id?: string; recent_space_id?: string };
  'settings.getAdBlockState': { profile_id?: string };
  'settings.setAdBlockEnabled': { enabled: boolean };
  'settings.toggleAdBlockList': { profile_id: string; list_id: string; enabled: boolean };
  'settings.addAdBlockExclusion': { profile_id: string; host: string };
  'settings.removeAdBlockExclusion': { profile_id: string; host: string };
  'settings.clearBrowsingData': { profile_id: string; range: 'hour' | 'day' | 'week' | 'month' | 'all'; kinds: string[] };
  'settings.setDefaultBrowser': Record<string, never>;
  'settings.getExtensions': { profile_id?: string };
  'settings.toggleExtension': { id: string; enabled: boolean; pinned?: boolean };

  'sync.getStatus': Record<string, never>;
  'sync.configureServer': { server_url: string; categories?: Record<string, boolean> };
  'sync.register': { email: string; password: string; server_url: string };
  'sync.login': { email: string; password: string; server_url: string };
  'sync.logout': Record<string, never>;
  'sync.triggerNow': Record<string, never>;
  'sync.recover': { email: string; recovery_key: string; new_password: string; server_url: string };
  'sync.listDevices': Record<string, never>;
  'sync.revokeDevice': { device_id: string };

  'library.getHistory': { profile_id?: string; query?: string; limit?: number };
  'library.deleteHistory': { ids?: number[]; clear_all?: boolean; profile_id?: string };
  'library.getArchive': { profile_id?: string; query?: string };
  'library.restoreArchived': { id: string };
  'library.getDownloads': { profile_id?: string; query?: string };
  'library.openDownload': { id: string; reveal?: boolean };
  'library.getSpaces': Record<string, never>;
  'library.updateSpace': { id: string; title?: string; icon?: SpaceIcon; style?: SpaceStyle };
  'library.deleteSpace': { id: string };
  'library.getMedia': { profile_id?: string; query?: string };
  'library.getEasels': { profile_id?: string; query?: string };
  'library.openUrl': { url: string; new_tab?: boolean };

  'boosts.list': { profile_id?: string };
  'boosts.save': { boost: Boost };
  'boosts.delete': { id: string };
  'boosts.toggle': { id: string; enabled: boolean };
  'boosts.startZap': { boost_id: string; mode?: 'zap' | 'select' };
  'boosts.removeZap': { boost_id: string; zap_id: string };

  'easel.load': { id?: string };
  'easel.save': { document: EaselDocument };
  'easel.exportHtml': { document: EaselDocument };
  'note.load': { id?: string };
  'note.save': { document: NoteDocument };

  'onboarding.getState': Record<string, never>;
  'onboarding.complete': {
    user_name: string;
    imported_source_id?: string;
    favorite_urls: string[];
    space_style: SpaceStyle;
    adblock_enabled: boolean;
    make_default_browser: boolean;
  };
  'import.probeBrowsers': Record<string, never>;
  'import.run': { source_id: string; kinds: string[] };
  'welcome.triggerAction': { action: 'shortcuts' | 'help' | 'new_tab' | 'split' | 'replay_all' };
}

export interface RpcResponseMap {
  'settings.getAll': SettingsSnapshot;
  'settings.setPreference': { ok: boolean; preferences: Record<string, unknown> };
  'settings.resetPreference': { ok: boolean; preferences: Record<string, unknown> };
  'settings.listProfiles': { profiles: ProfileSummary[] };
  'settings.createProfile': { profile: ProfileSummary };
  'settings.renameProfile': { profile: ProfileSummary };
  'settings.deleteProfile': { ok: boolean };
  'settings.getShortcuts': { shortcuts: ShortcutBinding[]; priority: 'open' | 'website' };
  'settings.setShortcut': { shortcuts: ShortcutBinding[]; conflict?: string };
  'settings.resetShortcut': { shortcuts: ShortcutBinding[] };
  'settings.getRoutingRules': { rules: RoutingRule[]; default_destination: RoutingDestination };
  'settings.saveRoutingRule': { rules: RoutingRule[]; default_destination: RoutingDestination };
  'settings.deleteRoutingRule': { rules: RoutingRule[] };
  'settings.testRoutingUrl': RoutingTestResult;
  'settings.getAdBlockState': AdBlockState;
  'settings.setAdBlockEnabled': AdBlockState;
  'settings.toggleAdBlockList': AdBlockState;
  'settings.addAdBlockExclusion': AdBlockState;
  'settings.removeAdBlockExclusion': AdBlockState;
  'settings.clearBrowsingData': { ok: boolean; cleared_items: number };
  'settings.setDefaultBrowser': { status: 'already' | 'success' | 'declined' | 'failed'; is_default: boolean };
  'settings.getExtensions': { extensions: ExtensionItem[] };
  'settings.toggleExtension': { extensions: ExtensionItem[] };

  'sync.getStatus': SyncStatus;
  'sync.configureServer': SyncStatus;
  'sync.register': { status: SyncStatus; recovery_key: string };
  'sync.login': { status: SyncStatus; has_cloud_data: boolean };
  'sync.logout': SyncStatus;
  'sync.triggerNow': SyncStatus;
  'sync.recover': SyncStatus;
  'sync.listDevices': { devices: SyncDevice[] };
  'sync.revokeDevice': { devices: SyncDevice[] };

  'library.getHistory': { entries: HistoryEntry[] };
  'library.deleteHistory': { ok: boolean; remaining: number };
  'library.getArchive': { items: ArchivedTabRecord[] };
  'library.restoreArchived': { ok: boolean; restored_url: string };
  'library.getDownloads': { downloads: DownloadRecord[] };
  'library.openDownload': { ok: boolean };
  'library.getSpaces': { spaces: SpaceSummary[] };
  'library.updateSpace': { space: SpaceSummary };
  'library.deleteSpace': { ok: boolean };
  'library.getMedia': { items: MediaCaptureRecord[] };
  'library.getEasels': { easels: EaselSummary[] };
  'library.openUrl': { ok: boolean };

  'boosts.list': { boosts: Boost[]; global_enabled: boolean };
  'boosts.save': { boost: Boost };
  'boosts.delete': { ok: boolean };
  'boosts.toggle': { boost: Boost };
  'boosts.startZap': { armed: boolean; message: string };
  'boosts.removeZap': { boost: Boost };

  'easel.load': { document: EaselDocument };
  'easel.save': { ok: boolean; modified_at: number };
  'easel.exportHtml': { html: string; filename: string };
  'note.load': { document: NoteDocument };
  'note.save': { ok: boolean; modified_at: number };

  'onboarding.getState': {
    completed: boolean;
    default_space_style: SpaceStyle;
    is_default_browser: boolean;
    adblock_enabled: boolean;
  };
  'onboarding.complete': { ok: boolean; welcome_url: string };
  'import.probeBrowsers': { sources: BrowserImportSource[] };
  'import.run': { ok: boolean; imported_bookmarks: number; imported_history: number; imported_favorites: number };
  'welcome.triggerAction': { ok: boolean; message?: string };
}

// --- Window Globals for Chromium WebUI Bridge ---

declare global {
  interface Window {
    chrome?: {
      send?: (messageName: string, args: unknown[]) => void;
    };
    __openRpcResolve?: (requestId: number, ok: boolean, resultOrError: unknown) => void;
    __openRpcEvent?: (eventName: string, payload: unknown) => void;
  }
}

type PendingCall = {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
};

type EventListener = (payload: unknown) => void;

const pendingCalls = new Map<number, PendingCall>();
const eventListeners = new Map<string, Set<EventListener>>();
let nextRequestId = 1;

export function isNativeWebUI(): boolean {
  return typeof window !== 'undefined' && typeof window.chrome?.send === 'function';
}

function ensureGlobalCallbacks(): void {
  if (typeof window === 'undefined') return;
  if (!window.__openRpcResolve) {
    window.__openRpcResolve = (requestId: number, ok: boolean, resultOrError: unknown) => {
      const pending = pendingCalls.get(requestId);
      if (!pending) return;
      pendingCalls.delete(requestId);
      if (ok) {
        pending.resolve(resultOrError);
      } else {
        const message =
          typeof resultOrError === 'string'
            ? resultOrError
            : (resultOrError as { message?: string } | null)?.message ?? 'RPC request failed';
        pending.reject(new Error(message));
      }
    };
  }
  if (!window.__openRpcEvent) {
    window.__openRpcEvent = (eventName: string, payload: unknown) => {
      emitEvent(eventName, payload);
    };
  }
}

function emitEvent(eventName: string, payload: unknown): void {
  const listeners = eventListeners.get(eventName);
  if (!listeners) return;
  for (const fn of listeners) {
    try {
      fn(payload);
    } catch {
      // Keep event fan-out isolated.
    }
  }
}

export function subscribeEvent(eventName: RpcEventName, listener: EventListener): () => void {
  ensureGlobalCallbacks();
  let set = eventListeners.get(eventName);
  if (!set) {
    set = new Set();
    eventListeners.set(eventName, set);
  }
  set.add(listener);
  return () => {
    set?.delete(listener);
  };
}

// --- Response normalization ----------------------------------------------------

const ADBLOCK_CATEGORIES: ReadonlySet<string> = new Set<AdBlockListCategory>([
  'generic',
  'cookies',
  'privacy',
  'regional',
  'bcny',
]);

const ADBLOCK_STATE_METHODS: ReadonlySet<RpcMethod> = new Set<RpcMethod>([
  'settings.getAdBlockState',
  'settings.setAdBlockEnabled',
  'settings.toggleAdBlockList',
  'settings.addAdBlockExclusion',
  'settings.removeAdBlockExclusion',
]);

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/**
 * One AdBlockState shape for the live C++ reply (open_settings_ui.cc
 * AdBlockStateFor: Track 3's GetCatalog() with per-Profile `enabled`, no
 * rule counts, `last_error` when the engine is unavailable) and the preview.
 * Missing catalog fields come from ADBLOCK_CATALOG by id; lists without an id
 * are dropped; unknown categories fall back to the catalog's (or "regional").
 */
export function normalizeAdBlockState(raw: unknown): AdBlockState {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const catalogById = new Map(ADBLOCK_CATALOG.map((entry) => [entry.id, entry] as const));
  const lists: AdBlockListItem[] = [];
  for (const item of Array.isArray(r.lists) ? r.lists : []) {
    if (!item || typeof item !== 'object') continue;
    const it = item as Record<string, unknown>;
    const id = asString(it.id);
    if (!id) continue;
    const known = catalogById.get(id);
    const rawCategory = asString(it.category);
    const category: AdBlockListCategory =
      rawCategory && ADBLOCK_CATEGORIES.has(rawCategory)
        ? (rawCategory as AdBlockListCategory)
        : (known?.category ?? 'regional');
    const listItem: AdBlockListItem = {
      id,
      display_name: asString(it.display_name) ?? known?.display_name ?? id,
      info_url: asString(it.info_url) ?? known?.info_url ?? '',
      category,
      bundled: typeof it.bundled === 'boolean' ? it.bundled : (known?.bundled ?? false),
      default_enabled:
        typeof it.default_enabled === 'boolean' ? it.default_enabled : (known?.default_enabled ?? false),
      enabled: it.enabled === true,
    };
    const unavailable = asString(it.unavailable_reason);
    if (unavailable) listItem.unavailable_reason = unavailable;
    const ruleCount = asNumber(it.rule_count);
    if (ruleCount !== undefined) listItem.rule_count = ruleCount;
    const updatedAt = asNumber(it.last_updated_at);
    if (updatedAt !== undefined) listItem.last_updated_at = updatedAt;
    lists.push(listItem);
  }
  const state: AdBlockState = {
    profile_id: asString(r.profile_id) ?? '',
    global_enabled: r.global_enabled === true,
    generation: asNumber(r.generation) ?? 0,
    lists,
    exclusions: Array.isArray(r.exclusions)
      ? r.exclusions.filter((host): host is string => typeof host === 'string' && host.length > 0)
      : [],
    blocked_count_session: asNumber(r.blocked_count_session) ?? 0,
  };
  const lastError = asString(r.last_error);
  if (lastError) state.last_error = lastError;
  return state;
}

function normalizeResponse<M extends RpcMethod>(method: M, value: unknown): RpcResponseMap[M] {
  if (ADBLOCK_STATE_METHODS.has(method)) return normalizeAdBlockState(value) as RpcResponseMap[M];
  return value as RpcResponseMap[M];
}

export async function rpc<M extends RpcMethod>(
  method: M,
  payload: RpcRequestMap[M] = {} as RpcRequestMap[M],
): Promise<RpcResponseMap[M]> {
  ensureGlobalCallbacks();
  if (isNativeWebUI() && window.chrome?.send) {
    const requestId = nextRequestId++;
    const raw = await new Promise<unknown>((resolve, reject) => {
      pendingCalls.set(requestId, { resolve, reject });
      window.chrome!.send!(RPC_MESSAGE_NAME, [requestId, method, payload]);
    });
    return normalizeResponse(method, raw);
  }
  return normalizeResponse(method, await previewRpc(method, payload));
}

// ============================================================================
// Standalone In-Memory Dev / Preview Adapter (used ONLY outside Chromium WebUI)
// ============================================================================

const NOW_SEC = Math.floor(Date.now() / 1000);

const DEFAULT_PREFERENCES: Record<string, unknown> = {
  'general.automaticUpdates': true,
  'general.warnBeforeQuitting': true,
  'general.restoreWindows': true,
  'appearance.appIcon': 'open-indigo',
  'appearance.websiteAppearance': 'automatic',
  'appearance.toolbar': true,
  'appearance.fullUrl': false,
  'tabs.archiveAfter': '12h',
  'tabs.littleOpenArchiveAfter': '6h',
  'tabs.sleepMode': 'balanced',
  'tabs.includeFavoritesInSwitcher': true,
  'tabs.ninthTabGoesToLast': true,
  'search.engine': 'google',
  'search.suggestions': true,
  'downloads.location': '~/Downloads',
  'downloads.askEachTime': false,
  'previews.enabled': true,
  'previews.folders': true,
  'previews.pages': true,
  'links.littleOpenHotkey': 'Mod+Option+N',
  'links.optionCommandClick': true,
  'links.externalLinksLittleOpen': true,
  'links.peekShiftClick': true,
  'links.peekOtherSites': true,
  'shortcuts.priority': 'open',
  'advanced.soundEffects': true,
  'advanced.haptics': true,
  'advanced.windowDragging': true,
  'advanced.sharedQuotes': true,
  'advanced.pictureInPicture': true,
  'advanced.themeData': true,
  'advanced.enableBoosts': true,
  'advanced.translateOffer': true,
};

interface PreviewState {
  preferences: Record<string, unknown>;
  isDefaultBrowser: boolean;
  profiles: ProfileSummary[];
  spaces: SpaceSummary[];
  shortcuts: ShortcutBinding[];
  shortcutPriority: 'open' | 'website';
  routingRules: RoutingRule[];
  defaultRoutingDestination: RoutingDestination;
  adBlockGlobalEnabled: boolean;
  adBlockGeneration: number;
  adBlockEnabledListsByProfile: Record<string, Set<string>>;
  adBlockExclusionsByProfile: Record<string, string[]>;
  extensions: ExtensionItem[];
  sync: SyncStatus;
  history: HistoryEntry[];
  archive: ArchivedTabRecord[];
  downloads: DownloadRecord[];
  media: MediaCaptureRecord[];
  boosts: Boost[];
  easels: Record<string, EaselDocument>;
  notes: Record<string, NoteDocument>;
  onboardingCompleted: boolean;
}

let previewState: PreviewState | null = null;

function getPreviewState(): PreviewState {
  if (previewState) return previewState;

  const defaultLists = new Set(ADBLOCK_CATALOG.filter((l) => l.default_enabled).map((l) => l.id));

  previewState = {
    preferences: { ...DEFAULT_PREFERENCES },
    isDefaultBrowser: false,
    profiles: [
      {
        id: '00000000-0000-0000-0000-000000000001',
        name: 'Personal',
        icon: { kind: 'emoji', value: '🏠' },
        data_directory_name: 'Default',
        is_default: true,
        space_count: 2,
        favorites_count: 5,
        settings: {
          auto_archive_after: '12h',
          little_open_auto_archive_after: '6h',
          search_suggest_enabled: true,
          download_directory: '~/Downloads',
          ask_where_to_save_each_file: false,
          search_engine_id: 'google',
          custom_search_engines: [
            { id: 'github-code', name: 'GitHub Code', keyword: 'gh', url_template: 'https://github.com/search?q=%s' },
          ],
          sleep_mode: 'balanced',
          keep_alive_sites: ['mail.google.com', 'calendar.google.com'],
        },
      },
      {
        id: '00000000-0000-0000-0000-000000000002',
        name: 'Work',
        icon: { kind: 'emoji', value: '💼' },
        data_directory_name: 'Profile_Work',
        is_default: false,
        space_count: 1,
        favorites_count: 4,
        settings: {
          auto_archive_after: '24h',
          little_open_auto_archive_after: '12h',
          search_suggest_enabled: true,
          download_directory: '~/Downloads/Work',
          ask_where_to_save_each_file: true,
          search_engine_id: 'kagi',
          custom_search_engines: [],
          sleep_mode: 'conservative',
          keep_alive_sites: ['linear.app'],
        },
      },
    ],
    spaces: [
      {
        id: 'space-personal-1',
        title: 'Home',
        icon: { kind: 'emoji', value: '☀️' },
        profile_id: '00000000-0000-0000-0000-000000000001',
        style: {
          math_version: 1,
          key_color: { r: 0.19, g: 0.22, b: 1.0, a: 1 },
          color_count: 2,
          wheel: 'analogous',
          appearance: 'automatic',
          noise_factor: 0.18,
          texture: 'grain',
          intensity_factor: 0.65,
        },
        pinned_count: 6,
        today_count: 4,
      },
      {
        id: 'space-personal-2',
        title: 'Research',
        icon: { kind: 'emoji', value: '📚' },
        profile_id: '00000000-0000-0000-0000-000000000001',
        style: {
          math_version: 1,
          key_color: { r: 0.14, g: 0.68, b: 0.54, a: 1 },
          color_count: 3,
          wheel: 'analogous',
          appearance: 'automatic',
          noise_factor: 0.12,
          texture: 'sand',
          intensity_factor: 0.6,
        },
        pinned_count: 4,
        today_count: 9,
      },
      {
        id: 'space-work-1',
        title: 'Engineering',
        icon: { kind: 'emoji', value: '⚡' },
        profile_id: '00000000-0000-0000-0000-000000000002',
        style: {
          math_version: 1,
          key_color: { r: 0.85, g: 0.36, b: 0.24, a: 1 },
          color_count: 2,
          wheel: 'complementary',
          appearance: 'dark',
          noise_factor: 0.22,
          texture: 'denim',
          intensity_factor: 0.72,
        },
        pinned_count: 11,
        today_count: 7,
      },
    ],
    shortcuts: [
      { id: 'new-tab', title: 'New Tab (Command Bar)', category: 'Tabs', keys: 'Mod+T', default_keys: 'Mod+T' },
      { id: 'close-tab', title: 'Close Tab', category: 'Tabs', keys: 'Mod+W', default_keys: 'Mod+W' },
      { id: 'pin-tab', title: 'Pin / Unpin Tab', category: 'Tabs', keys: 'Mod+D', default_keys: 'Mod+D' },
      { id: 'copy-url', title: 'Copy Current URL', category: 'Navigation', keys: 'Mod+Shift+C', default_keys: 'Mod+Shift+C' },
      { id: 'toggle-sidebar', title: 'Toggle Sidebar', category: 'View', keys: 'Mod+S', default_keys: 'Mod+S' },
      { id: 'add-split-view', title: 'Add Split View', category: 'View', keys: 'Ctrl+Shift+=', default_keys: 'Ctrl+Shift+=' },
      { id: 'open-library', title: 'Toggle Library', category: 'Tools', keys: 'Mod+Y', default_keys: 'Mod+Y' },
      { id: 'new-easel', title: 'New Easel', category: 'Tools', keys: 'Ctrl+Shift+E', default_keys: 'Ctrl+Shift+E' },
      { id: 'new-note', title: 'New Note', category: 'Tools', keys: '', default_keys: '' },
      { id: 'next-space', title: 'Next Space', category: 'Spaces', keys: 'Ctrl+Right', default_keys: 'Ctrl+Right' },
      { id: 'prev-space', title: 'Previous Space', category: 'Spaces', keys: 'Ctrl+Left', default_keys: 'Ctrl+Left' },
      { id: 'new-little-open', title: 'New Little Open Window', category: 'Window', keys: 'Mod+Alt+N', default_keys: 'Mod+Alt+N' },
      { id: 'new-boost', title: 'New Boost for Current Site', category: 'Tools', keys: '', default_keys: '' },
    ],
    shortcutPriority: 'open',
    routingRules: [
      {
        id: 'rule-github',
        name: 'GitHub to Engineering',
        host_pattern: '*.github.com',
        destination: { kind: 'space', space_id: 'space-work-1', profile_id: '00000000-0000-0000-0000-000000000002' },
        enabled: true,
      },
      {
        id: 'rule-docs',
        name: 'Research Docs',
        host_pattern: 'arxiv.org',
        path_prefix: '/abs',
        destination: { kind: 'space', space_id: 'space-personal-2', profile_id: '00000000-0000-0000-0000-000000000001' },
        enabled: true,
      },
    ],
    defaultRoutingDestination: { kind: 'little_open' },
    adBlockGlobalEnabled: true,
    adBlockGeneration: 3,
    adBlockEnabledListsByProfile: {
      '00000000-0000-0000-0000-000000000001': new Set(defaultLists),
      '00000000-0000-0000-0000-000000000002': new Set(defaultLists),
    },
    adBlockExclusionsByProfile: {
      '00000000-0000-0000-0000-000000000001': ['localhost'],
      '00000000-0000-0000-0000-000000000002': ['internal.example.com'],
    },
    extensions: [
      {
        id: 'nngceckbapebfimnlniiiahkandclblb',
        name: 'Bitwarden Password Manager',
        version: '2026.10.1',
        description: 'Secure and free password manager for all of your devices.',
        enabled: true,
        pinned: true,
        permissions: ['tabs', 'storage', 'clipboardWrite'],
      },
      {
        id: 'eimadpbcbfnmbkopoojfekhnkhdbieeh',
        name: 'Dark Reader',
        version: '4.9.102',
        description: 'Dark mode for every website. Take care of your eyes.',
        enabled: false,
        pinned: false,
        permissions: ['tabs', 'activeTab'],
      },
      {
        id: 'fmkadmapgofadopljbjfkapdkoienihi',
        name: 'React Developer Tools',
        version: '6.1.0',
        description: 'Adds React debugging tools to the browser Developer Tools.',
        enabled: true,
        pinned: false,
        permissions: ['scripting'],
      },
    ],
    sync: {
      signed_in: false,
      server_url: 'https://sync.example.com',
      state: 'signed_out',
      revision: 0,
      categories: {
        workspace: true,
        today_tabs: true,
        archive: true,
        settings_shortcuts: true,
        ad_blocking: true,
        boosts_documents: true,
        history: true,
        extensions: true,
        credentials_permissions: false,
      },
      devices: [],
    },
    history: [
      { id: 101, url: 'https://github.com/SergeSerb2/open', title: 'SergeSerb2/open: Unified Cross-Platform Browser', visit_count: 14, typed_count: 5, last_visit: NOW_SEC - 180, profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 102, url: 'https://developer.mozilla.org/en-US/docs/Web/CSS/color_value/oklab', title: 'oklab() — CSS: Cascading Style Sheets | MDN', visit_count: 6, typed_count: 1, last_visit: NOW_SEC - 1400, profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 103, url: 'https://preactjs.com/guide/v10/getting-started', title: 'Getting Started – Preact', visit_count: 4, typed_count: 2, last_visit: NOW_SEC - 4200, profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 104, url: 'https://linear.app/open/cycle/active', title: 'Active Cycle — Open Unified', visit_count: 9, typed_count: 3, last_visit: NOW_SEC - 7800, profile_id: '00000000-0000-0000-0000-000000000002' },
      { id: 105, url: 'https://news.ycombinator.com/', title: 'Hacker News', visit_count: 22, typed_count: 18, last_visit: NOW_SEC - 90000, profile_id: '00000000-0000-0000-0000-000000000001' },
    ],
    archive: [
      { id: 'arch-1', url: 'https://chromium.googlesource.com/chromium/src/+/refs/tags/156.0.8078.48', title: 'Chromium 156.0.8078.48 Source Tree', space_id: 'space-work-1', space_title: 'Engineering', profile_id: '00000000-0000-0000-0000-000000000002', archived_at: NOW_SEC - 3600, reason: 'auto-archive', original_location: 'today', kind: 'tab' },
      { id: 'arch-2', url: 'https://vite.dev/guide/build.html', title: 'Building for Production | Vite', space_id: 'space-personal-2', space_title: 'Research', profile_id: '00000000-0000-0000-0000-000000000001', archived_at: NOW_SEC - 14400, reason: 'closed', original_location: 'today', kind: 'tab' },
      { id: 'arch-3', url: 'https://easylist.to/', title: 'EasyList — Overview', space_id: 'space-personal-1', space_title: 'Home', profile_id: '00000000-0000-0000-0000-000000000001', archived_at: NOW_SEC - 86400, reason: 'clear-today', original_location: 'today', kind: 'tab' },
    ],
    downloads: [
      { id: 'dl-1', url: 'https://releases.openbrowser.local/open-unified-linux-x64.tar.gz', filename: 'open-unified-linux-x64.tar.gz', target_path: '~/Downloads/open-unified-linux-x64.tar.gz', mime_type: 'application/gzip', state: 'in_progress', received_bytes: 54_200_000, total_bytes: 82_000_000, started_at: NOW_SEC - 12, ended_at: 0, profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 'dl-2', url: 'https://example.com/architecture-diagram.pdf', filename: 'architecture-diagram.pdf', target_path: '~/Downloads/architecture-diagram.pdf', mime_type: 'application/pdf', state: 'completed', received_bytes: 2_480_120, total_bytes: 2_480_120, started_at: NOW_SEC - 2400, ended_at: NOW_SEC - 2398, profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 'dl-3', url: 'https://example.com/design-tokens.json', filename: 'design-tokens.json', target_path: '~/Downloads/Work/design-tokens.json', mime_type: 'application/json', state: 'completed', received_bytes: 18_432, total_bytes: 18_432, started_at: NOW_SEC - 50000, ended_at: NOW_SEC - 49999, profile_id: '00000000-0000-0000-0000-000000000002' },
    ],
    media: [
      { id: 'med-1', title: 'Open Unified Window Chrome', source_url: 'https://github.com/SergeSerb2/open', captured_at: NOW_SEC - 900, width: 1440, height: 900, preview_gradient: 'linear-gradient(135deg, #3139FF 0%, #6D5CFF 52%, #FF8E53 100%)', profile_id: '00000000-0000-0000-0000-000000000001' },
      { id: 'med-2', title: 'OKLab Dual-Angle Swatch Study', source_url: 'https://developer.mozilla.org/', captured_at: NOW_SEC - 18000, width: 1200, height: 760, preview_gradient: 'linear-gradient(135deg, #169873 0%, #2C67F2 100%)', profile_id: '00000000-0000-0000-0000-000000000001' },
    ],
    boosts: [
      {
        id: 'boost-hn',
        profile_id: '00000000-0000-0000-0000-000000000001',
        name: 'Clean Hacker News',
        host_pattern: 'news.ycombinator.com',
        enabled: true,
        color: { enabled: true, hue_degrees: -12, saturation: 0.9, lightness: 0.04, contrast: 1.05, invert: false },
        font_family: 'Inter',
        text_zoom: 1.15,
        text_transform: '',
        custom_css: 'table#hnmain { max-width: 880px; border-radius: 12px; }',
        custom_js: '',
        zapped_elements: [
          { id: 'zap-1', selector: '.yclinks', label: 'Footer links bar' },
        ],
        created_at: NOW_SEC - 86400 * 3,
        modified_at: NOW_SEC - 3600,
      },
      {
        id: 'boost-wiki',
        profile_id: '00000000-0000-0000-0000-000000000001',
        name: 'Wikipedia Editorial Serif',
        host_pattern: 'wikipedia.org',
        enabled: true,
        color: { enabled: false, hue_degrees: 0, saturation: 1, lightness: 0, contrast: 1, invert: false },
        font_family: 'Georgia',
        text_zoom: 1.1,
        text_transform: '',
        custom_css: '#content { line-height: 1.72; }',
        custom_js: '',
        zapped_elements: [
          { id: 'zap-2', selector: '#siteNotice', label: 'Site notice banner' },
          { id: 'zap-3', selector: '.vector-pinnable-header', label: 'Pinnable sidebar header' },
        ],
        created_at: NOW_SEC - 86400 * 5,
        modified_at: NOW_SEC - 7200,
      },
    ],
    easels: {
      'easel-default': {
        format_version: 1,
        id: 'easel-default',
        title: 'Product Architecture Board',
        canvas_width: 1000,
        canvas_height: 1400,
        palette: 'vibrant',
        elements: [
          {
            id: 'el-1',
            type: 'text',
            x: 64,
            y: 48,
            width: 440,
            height: 60,
            content: 'Open Unified Architecture',
            fill_color: 'transparent',
            stroke_color: '#3139FF',
            stroke_width: 0,
            font_size: 28,
            z_index: 1,
          },
          {
            id: 'el-2',
            type: 'rect',
            x: 64,
            y: 136,
            width: 260,
            height: 132,
            content: 'Chromium Views Chrome\n120 Hz Sidebar & Splits',
            fill_color: '#3139FF',
            stroke_color: '#1E24B8',
            stroke_width: 2,
            font_size: 15,
            z_index: 2,
          },
          {
            id: 'el-3',
            type: 'arrow',
            x: 332,
            y: 190,
            width: 96,
            height: 24,
            content: '',
            fill_color: 'transparent',
            stroke_color: '#FF5C35',
            stroke_width: 3,
            font_size: 14,
            z_index: 3,
          },
          {
            id: 'el-4',
            type: 'ellipse',
            x: 438,
            y: 136,
            width: 220,
            height: 132,
            content: 'Preact WebUI\nopen:// Panels',
            fill_color: '#00B87C',
            stroke_color: '#008A5B',
            stroke_width: 2,
            font_size: 15,
            z_index: 4,
          },
          {
            id: 'el-5',
            type: 'live_card',
            x: 64,
            y: 316,
            width: 380,
            height: 220,
            content: 'https://github.com/SergeSerb2/open',
            fill_color: '#1D1D27',
            stroke_color: '#3139FF',
            stroke_width: 1,
            font_size: 14,
            z_index: 5,
          },
        ],
        created_at: NOW_SEC - 86400,
        modified_at: NOW_SEC - 120,
      },
    },
    notes: {
      'note-default': (() => {
        const text =
          'Open Unified WebUI Notes\n\nAll seven open:// surfaces run lazily on demand with zero idle RAM impact.\n\nKey highlights:\nTyped JSON RPC bridge matching open_ipc_contract.h\nDark and light surfaces calibrated for native parity\nUTF-16 format range persistence for rich notes\n';
        const rangeFor = (needle: string) => ({ location: text.indexOf(needle), length: needle.length });
        return {
          format_version: 1,
          id: 'note-default',
          title: 'Release Checklist & Notes',
          text,
          formats: [
            { type: 'h1' as const, ...rangeFor('Open Unified WebUI Notes') },
            { type: 'bold' as const, ...rangeFor('All seven open:// surfaces') },
            { type: 'italic' as const, ...rangeFor('zero idle RAM impact.') },
            { type: 'h2' as const, ...rangeFor('Key highlights:') },
            { type: 'bulletList' as const, ...rangeFor('Typed JSON RPC bridge matching open_ipc_contract.h') },
            { type: 'bulletList' as const, ...rangeFor('Dark and light surfaces calibrated for native parity') },
            { type: 'bulletList' as const, ...rangeFor('UTF-16 format range persistence for rich notes') },
          ],
          created_at: NOW_SEC - 7200,
          modified_at: NOW_SEC - 60,
        };
      })(),
    },
    onboardingCompleted: false,
  };

  return previewState;
}

function buildAdBlockState(st: PreviewState, profileId: string): AdBlockState {
  const enabledSet =
    st.adBlockEnabledListsByProfile[profileId] ??
    (st.adBlockEnabledListsByProfile[profileId] = new Set(
      ADBLOCK_CATALOG.filter((l) => l.default_enabled).map((l) => l.id),
    ));
  const exclusions = st.adBlockExclusionsByProfile[profileId] ?? (st.adBlockExclusionsByProfile[profileId] = []);

  return {
    profile_id: profileId,
    global_enabled: st.adBlockGlobalEnabled,
    generation: st.adBlockGeneration,
    lists: ADBLOCK_CATALOG.map((entry) => ({
      ...entry,
      enabled: enabledSet.has(entry.id),
      rule_count: entry.bundled ? (entry.id === 'EasyList' ? 74210 : 48930) : undefined,
      last_updated_at: entry.bundled ? NOW_SEC - 1800 : undefined,
    })),
    exclusions: [...exclusions],
    blocked_count_session: st.adBlockGlobalEnabled ? 142 : 0,
  };
}

function matchHostPattern(pattern: string, hostname: string): boolean {
  const cleanPattern = pattern.trim().toLowerCase();
  const cleanHost = hostname.trim().toLowerCase();
  if (!cleanPattern) return false;
  if (cleanPattern === '*') return true;
  if (cleanPattern.startsWith('*.')) {
    const suffix = cleanPattern.slice(2);
    return cleanHost === suffix || cleanHost.endsWith('.' + suffix);
  }
  return cleanHost === cleanPattern || cleanHost.endsWith('.' + cleanPattern);
}

async function previewRpc<M extends RpcMethod>(
  method: M,
  payload: RpcRequestMap[M],
): Promise<RpcResponseMap[M]> {
  const st = getPreviewState();
  const defaultProfileId = st.profiles[0]?.id ?? '00000000-0000-0000-0000-000000000001';

  switch (method) {
    case 'settings.getAll': {
      const req = payload as RpcRequestMap['settings.getAll'];
      return {
        preferences: { ...st.preferences },
        defaults: { ...DEFAULT_PREFERENCES },
        is_default_browser: st.isDefaultBrowser,
        app_version: '1.0.0-unified',
        chromium_version: '156.0.8078.48',
        active_profile_id: req.profile_id ?? defaultProfileId,
      } as RpcResponseMap[M];
    }

    case 'settings.setPreference': {
      const req = payload as RpcRequestMap['settings.setPreference'];
      st.preferences[req.key] = req.value;
      if (req.profile_id) {
        const targets = req.apply_all_profiles
          ? st.profiles
          : st.profiles.filter((p) => p.id === req.profile_id);
        for (const p of targets) {
          if (req.key === 'tabs.archiveAfter' && typeof req.value === 'string') {
            p.settings.auto_archive_after = req.value;
          } else if (req.key === 'tabs.littleOpenArchiveAfter' && typeof req.value === 'string') {
            p.settings.little_open_auto_archive_after = req.value;
          } else if (req.key === 'search.engine' && typeof req.value === 'string') {
            p.settings.search_engine_id = req.value;
          } else if (req.key === 'search.suggestions' && typeof req.value === 'boolean') {
            p.settings.search_suggest_enabled = req.value;
          } else if (req.key === 'downloads.location' && typeof req.value === 'string') {
            p.settings.download_directory = req.value;
          } else if (req.key === 'downloads.askEachTime' && typeof req.value === 'boolean') {
            p.settings.ask_where_to_save_each_file = req.value;
          } else if (req.key === 'tabs.sleepMode' && typeof req.value === 'string') {
            p.settings.sleep_mode = req.value as ProfileSummary['settings']['sleep_mode'];
          }
        }
      }
      if (req.key === 'shortcuts.priority' && (req.value === 'open' || req.value === 'website')) {
        st.shortcutPriority = req.value;
      }
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'preferences', key: req.key });
      return { ok: true, preferences: { ...st.preferences } } as RpcResponseMap[M];
    }

    case 'settings.resetPreference': {
      const req = payload as RpcRequestMap['settings.resetPreference'];
      if (req.key in DEFAULT_PREFERENCES) {
        st.preferences[req.key] = DEFAULT_PREFERENCES[req.key];
      }
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'preferences', key: req.key });
      return { ok: true, preferences: { ...st.preferences } } as RpcResponseMap[M];
    }

    case 'settings.listProfiles':
      return { profiles: st.profiles.map((p) => ({ ...p, settings: { ...p.settings } })) } as RpcResponseMap[M];

    case 'settings.createProfile': {
      const req = payload as RpcRequestMap['settings.createProfile'];
      const name = req.name.trim();
      if (!name) throw new Error('Profile name cannot be empty.');
      const id = `profile-${Date.now()}`;
      const created: ProfileSummary = {
        id,
        name,
        icon: req.icon ?? { kind: 'emoji', value: '✨' },
        data_directory_name: `Profile_${st.profiles.length + 1}`,
        is_default: false,
        space_count: 1,
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
        },
      };
      st.profiles.push(created);
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'profiles' });
      return { profile: created } as RpcResponseMap[M];
    }

    case 'settings.renameProfile': {
      const req = payload as RpcRequestMap['settings.renameProfile'];
      const target = st.profiles.find((p) => p.id === req.profile_id);
      if (!target) throw new Error('Profile not found.');
      if (!req.name.trim()) throw new Error('Profile name cannot be empty.');
      target.name = req.name.trim();
      if (req.icon) target.icon = req.icon;
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'profiles' });
      return { profile: { ...target } } as RpcResponseMap[M];
    }

    case 'settings.deleteProfile': {
      const req = payload as RpcRequestMap['settings.deleteProfile'];
      const idx = st.profiles.findIndex((p) => p.id === req.profile_id);
      if (idx < 0) throw new Error('Profile not found.');
      const target = st.profiles[idx]!;
      if (target.is_default) throw new Error('The default Profile cannot be deleted.');
      if (req.confirm_name.trim() !== target.name) {
        throw new Error(`Type "${target.name}" to confirm deletion.`);
      }
      st.profiles.splice(idx, 1);
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'profiles' });
      return { ok: true } as RpcResponseMap[M];
    }

    case 'settings.getShortcuts':
      return { shortcuts: st.shortcuts.map((s) => ({ ...s })), priority: st.shortcutPriority } as RpcResponseMap[M];

    case 'settings.setShortcut': {
      const req = payload as RpcRequestMap['settings.setShortcut'];
      const target = st.shortcuts.find((s) => s.id === req.id);
      if (!target) throw new Error('Unknown shortcut command.');
      const normalized = req.keys.trim();
      const conflictItem = normalized
        ? st.shortcuts.find((s) => s.id !== req.id && s.keys.toLowerCase() === normalized.toLowerCase())
        : undefined;
      if (conflictItem) {
        return {
          shortcuts: st.shortcuts.map((s) => ({ ...s })),
          conflict: `Conflicts with "${conflictItem.title}" (${conflictItem.keys}).`,
        } as RpcResponseMap[M];
      }
      target.keys = normalized;
      return { shortcuts: st.shortcuts.map((s) => ({ ...s })) } as RpcResponseMap[M];
    }

    case 'settings.resetShortcut': {
      const req = payload as RpcRequestMap['settings.resetShortcut'];
      if (req.reset_all) {
        for (const s of st.shortcuts) s.keys = s.default_keys;
      } else if (req.id) {
        const target = st.shortcuts.find((s) => s.id === req.id);
        if (target) target.keys = target.default_keys;
      }
      return { shortcuts: st.shortcuts.map((s) => ({ ...s })) } as RpcResponseMap[M];
    }

    case 'settings.getRoutingRules':
      return {
        rules: st.routingRules.map((r) => ({ ...r, destination: { ...r.destination } })),
        default_destination: { ...st.defaultRoutingDestination },
      } as RpcResponseMap[M];

    case 'settings.saveRoutingRule': {
      const req = payload as RpcRequestMap['settings.saveRoutingRule'];
      if (req.default_destination) {
        st.defaultRoutingDestination = { ...req.default_destination };
      }
      if (req.rule && req.rule.host_pattern.trim()) {
        const existingIdx = st.routingRules.findIndex((r) => r.id === req.rule.id);
        const cleanRule: RoutingRule = {
          ...req.rule,
          id: req.rule.id || `rule-${Date.now()}`,
          name: req.rule.name.trim() || req.rule.host_pattern.trim(),
          host_pattern: req.rule.host_pattern.trim(),
          path_prefix: req.rule.path_prefix?.trim() || undefined,
          source_app_id: req.rule.source_app_id?.trim() || undefined,
        };
        if (existingIdx >= 0) {
          st.routingRules[existingIdx] = cleanRule;
        } else {
          st.routingRules.push(cleanRule);
        }
      }
      return {
        rules: st.routingRules.map((r) => ({ ...r, destination: { ...r.destination } })),
        default_destination: { ...st.defaultRoutingDestination },
      } as RpcResponseMap[M];
    }

    case 'settings.deleteRoutingRule': {
      const req = payload as RpcRequestMap['settings.deleteRoutingRule'];
      st.routingRules = st.routingRules.filter((r) => r.id !== req.id);
      return { rules: st.routingRules.map((r) => ({ ...r })) } as RpcResponseMap[M];
    }

    case 'settings.testRoutingUrl': {
      const req = payload as RpcRequestMap['settings.testRoutingUrl'];
      let parsed: URL;
      try {
        const raw = /^https?:\/\//i.test(req.url.trim()) ? req.url.trim() : `https://${req.url.trim()}`;
        parsed = new URL(raw);
      } catch {
        throw new Error('Enter a valid http(s) URL to test.');
      }
      for (const rule of st.routingRules) {
        if (!rule.enabled) continue;
        if (!matchHostPattern(rule.host_pattern, parsed.hostname)) continue;
        if (rule.path_prefix && !parsed.pathname.startsWith(rule.path_prefix)) continue;
        if (rule.source_app_id && req.source_app_id && rule.source_app_id.toLowerCase() !== req.source_app_id.toLowerCase()) {
          continue;
        }
        const sp = st.spaces.find((s) => s.id === rule.destination.space_id);
        return {
          matched_rule_id: rule.id,
          matched_rule_name: rule.name,
          destination: { ...rule.destination },
          explanation: `Matched rule "${rule.name}" (${rule.host_pattern}) -> ${
            rule.destination.kind === 'little_open'
              ? 'Little Open'
              : rule.destination.kind === 'space'
                ? `Space "${sp?.title ?? rule.destination.space_id}"`
                : 'Most Recent Space'
          }`,
        } as RpcResponseMap[M];
      }
      const def = st.defaultRoutingDestination;
      return {
        destination: { ...def },
        explanation: `No custom rule matched ${parsed.hostname}. Using default destination: ${
          def.kind === 'little_open' ? 'Little Open' : def.kind === 'most_recent_space' ? 'Most Recent Space' : 'Specific Space'
        }.`,
      } as RpcResponseMap[M];
    }

    case 'settings.getAdBlockState': {
      const req = payload as RpcRequestMap['settings.getAdBlockState'];
      return buildAdBlockState(st, req.profile_id ?? defaultProfileId) as RpcResponseMap[M];
    }

    case 'settings.setAdBlockEnabled': {
      const req = payload as RpcRequestMap['settings.setAdBlockEnabled'];
      st.adBlockGlobalEnabled = req.enabled;
      st.adBlockGeneration += 1;
      const state = buildAdBlockState(st, defaultProfileId);
      emitEvent(RPC_EVENTS.adBlockUpdated, state);
      return state as RpcResponseMap[M];
    }

    case 'settings.toggleAdBlockList': {
      const req = payload as RpcRequestMap['settings.toggleAdBlockList'];
      const entry = ADBLOCK_CATALOG.find((e) => e.id === req.list_id);
      if (!entry) throw new Error('Unknown filter list.');
      if (entry.unavailable_reason && req.enabled) {
        throw new Error(entry.unavailable_reason);
      }
      const set =
        st.adBlockEnabledListsByProfile[req.profile_id] ??
        (st.adBlockEnabledListsByProfile[req.profile_id] = new Set());
      if (req.enabled) set.add(req.list_id);
      else set.delete(req.list_id);
      st.adBlockGeneration += 1;
      const state = buildAdBlockState(st, req.profile_id);
      emitEvent(RPC_EVENTS.adBlockUpdated, state);
      return state as RpcResponseMap[M];
    }

    case 'settings.addAdBlockExclusion': {
      const req = payload as RpcRequestMap['settings.addAdBlockExclusion'];
      const host = req.host.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
      if (!host || !/^[a-z0-9.-]+$/i.test(host)) {
        throw new Error('Enter a valid hostname (for example, example.com).');
      }
      const list = st.adBlockExclusionsByProfile[req.profile_id] ?? (st.adBlockExclusionsByProfile[req.profile_id] = []);
      if (!list.includes(host)) list.push(host);
      const state = buildAdBlockState(st, req.profile_id);
      emitEvent(RPC_EVENTS.adBlockUpdated, state);
      return state as RpcResponseMap[M];
    }

    case 'settings.removeAdBlockExclusion': {
      const req = payload as RpcRequestMap['settings.removeAdBlockExclusion'];
      const list = st.adBlockExclusionsByProfile[req.profile_id] ?? [];
      st.adBlockExclusionsByProfile[req.profile_id] = list.filter((h) => h !== req.host);
      const state = buildAdBlockState(st, req.profile_id);
      emitEvent(RPC_EVENTS.adBlockUpdated, state);
      return state as RpcResponseMap[M];
    }

    case 'settings.clearBrowsingData': {
      const req = payload as RpcRequestMap['settings.clearBrowsingData'];
      let cleared = 0;
      if (req.kinds.includes('history')) {
        const before = st.history.length;
        st.history = st.history.filter((h) => h.profile_id !== req.profile_id);
        cleared += before - st.history.length;
      }
      if (req.kinds.includes('downloads')) {
        const before = st.downloads.length;
        st.downloads = st.downloads.filter((d) => d.profile_id !== req.profile_id);
        cleared += before - st.downloads.length;
      }
      return { ok: true, cleared_items: cleared + 12 } as RpcResponseMap[M];
    }

    case 'settings.setDefaultBrowser': {
      const wasDefault = st.isDefaultBrowser;
      st.isDefaultBrowser = true;
      return { status: wasDefault ? 'already' : 'success', is_default: true } as RpcResponseMap[M];
    }

    case 'settings.getExtensions':
      return { extensions: st.extensions.map((e) => ({ ...e })) } as RpcResponseMap[M];

    case 'settings.toggleExtension': {
      const req = payload as RpcRequestMap['settings.toggleExtension'];
      const target = st.extensions.find((e) => e.id === req.id);
      if (target) {
        target.enabled = req.enabled;
        if (typeof req.pinned === 'boolean') target.pinned = req.pinned;
      }
      return { extensions: st.extensions.map((e) => ({ ...e })) } as RpcResponseMap[M];
    }

    // --- Account & Sync ---
    case 'sync.getStatus':
      return { ...st.sync, categories: { ...st.sync.categories }, devices: [...st.sync.devices] } as RpcResponseMap[M];

    case 'sync.configureServer': {
      const req = payload as RpcRequestMap['sync.configureServer'];
      if (req.server_url.trim()) st.sync.server_url = req.server_url.trim();
      if (req.categories) st.sync.categories = { ...st.sync.categories, ...req.categories };
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { ...st.sync, categories: { ...st.sync.categories }, devices: [...st.sync.devices] } as RpcResponseMap[M];
    }

    case 'sync.register': {
      const req = payload as RpcRequestMap['sync.register'];
      if (!req.email.includes('@')) throw new Error('Enter a valid email address.');
      if (req.password.length < 8) throw new Error('Password must be at least 8 characters.');
      const recoveryKey = 'OPEN-7K4M-9P2Q-W8XV-3N6R-5T2J-8H4C-V9L2';
      st.sync = {
        ...st.sync,
        signed_in: true,
        email: req.email.trim(),
        server_url: req.server_url.trim() || st.sync.server_url,
        state: 'idle',
        last_sync_at: Math.floor(Date.now() / 1000),
        revision: 1,
        recovery_key_hint: 'OPEN-7K4M-••••-V9L2',
        error_message: undefined,
        devices: [
          {
            id: 'dev-current',
            name: 'This Device (Open Unified)',
            platform: 'Linux',
            is_current: true,
            last_seen_at: Math.floor(Date.now() / 1000),
          },
        ],
      };
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { status: { ...st.sync }, recovery_key: recoveryKey } as RpcResponseMap[M];
    }

    case 'sync.login': {
      const req = payload as RpcRequestMap['sync.login'];
      if (!req.email.includes('@')) throw new Error('Enter a valid email address.');
      if (!req.password) throw new Error('Enter your password.');
      st.sync = {
        ...st.sync,
        signed_in: true,
        email: req.email.trim(),
        server_url: req.server_url.trim() || st.sync.server_url,
        state: 'idle',
        last_sync_at: Math.floor(Date.now() / 1000),
        revision: 42,
        recovery_key_hint: 'OPEN-4B2C-••••-9M1F',
        error_message: undefined,
        devices: [
          { id: 'dev-current', name: 'This Workstation', platform: 'Linux', is_current: true, last_seen_at: Math.floor(Date.now() / 1000) },
          { id: 'dev-mac', name: 'MacBook Pro', platform: 'macOS', is_current: false, last_seen_at: NOW_SEC - 3600 },
          { id: 'dev-win', name: 'Desktop PC', platform: 'Windows', is_current: false, last_seen_at: NOW_SEC - 22000 },
        ],
      };
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { status: { ...st.sync }, has_cloud_data: true } as RpcResponseMap[M];
    }

    case 'sync.logout': {
      st.sync = {
        ...st.sync,
        signed_in: false,
        email: undefined,
        state: 'signed_out',
        devices: [],
        error_message: undefined,
      };
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { ...st.sync } as RpcResponseMap[M];
    }

    case 'sync.triggerNow': {
      if (!st.sync.signed_in) throw new Error('Sign in to sync.');
      st.sync.revision += 1;
      st.sync.last_sync_at = Math.floor(Date.now() / 1000);
      st.sync.state = 'idle';
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { ...st.sync } as RpcResponseMap[M];
    }

    case 'sync.recover': {
      const req = payload as RpcRequestMap['sync.recover'];
      if (!req.recovery_key.startsWith('OPEN-')) {
        throw new Error('Recovery key must start with OPEN-.');
      }
      st.sync = {
        ...st.sync,
        signed_in: true,
        email: req.email.trim(),
        server_url: req.server_url.trim() || st.sync.server_url,
        state: 'idle',
        last_sync_at: Math.floor(Date.now() / 1000),
        revision: st.sync.revision + 1,
        devices: [
          { id: 'dev-current', name: 'This Device (Recovered)', platform: 'Linux', is_current: true, last_seen_at: Math.floor(Date.now() / 1000) },
        ],
      };
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { ...st.sync } as RpcResponseMap[M];
    }

    case 'sync.listDevices':
      return { devices: [...st.sync.devices] } as RpcResponseMap[M];

    case 'sync.revokeDevice': {
      const req = payload as RpcRequestMap['sync.revokeDevice'];
      st.sync.devices = st.sync.devices.filter((d) => d.id !== req.device_id || d.is_current);
      emitEvent(RPC_EVENTS.syncStatusChanged, st.sync);
      return { devices: [...st.sync.devices] } as RpcResponseMap[M];
    }

    // --- Library ---
    case 'library.getHistory': {
      const req = payload as RpcRequestMap['library.getHistory'];
      const q = (req.query ?? '').trim().toLowerCase();
      const entries = st.history.filter((h) => {
        if (req.profile_id && req.profile_id !== 'all' && h.profile_id !== req.profile_id) return false;
        if (q && !h.title.toLowerCase().includes(q) && !h.url.toLowerCase().includes(q)) return false;
        return true;
      });
      return { entries } as RpcResponseMap[M];
    }

    case 'library.deleteHistory': {
      const req = payload as RpcRequestMap['library.deleteHistory'];
      if (req.clear_all) {
        st.history = req.profile_id ? st.history.filter((h) => h.profile_id !== req.profile_id) : [];
      } else if (req.ids?.length) {
        const drop = new Set(req.ids);
        st.history = st.history.filter((h) => !drop.has(h.id));
      }
      return { ok: true, remaining: st.history.length } as RpcResponseMap[M];
    }

    case 'library.getArchive': {
      const req = payload as RpcRequestMap['library.getArchive'];
      const q = (req.query ?? '').trim().toLowerCase();
      const items = st.archive.filter((a) => {
        if (req.profile_id && req.profile_id !== 'all' && a.profile_id !== req.profile_id) return false;
        if (q && !a.title.toLowerCase().includes(q) && !a.url.toLowerCase().includes(q)) return false;
        return true;
      });
      return { items } as RpcResponseMap[M];
    }

    case 'library.restoreArchived': {
      const req = payload as RpcRequestMap['library.restoreArchived'];
      const item = st.archive.find((a) => a.id === req.id);
      st.archive = st.archive.filter((a) => a.id !== req.id);
      return { ok: true, restored_url: item?.url ?? '' } as RpcResponseMap[M];
    }

    case 'library.getDownloads': {
      const req = payload as RpcRequestMap['library.getDownloads'];
      const q = (req.query ?? '').trim().toLowerCase();
      const downloads = st.downloads.filter((d) => {
        if (req.profile_id && req.profile_id !== 'all' && d.profile_id !== req.profile_id) return false;
        if (q && !d.filename.toLowerCase().includes(q) && !d.url.toLowerCase().includes(q)) return false;
        return true;
      });
      return { downloads } as RpcResponseMap[M];
    }

    case 'library.openDownload':
      return { ok: true } as RpcResponseMap[M];

    case 'library.getSpaces':
      return { spaces: st.spaces.map((s) => ({ ...s, style: { ...s.style, key_color: { ...s.style.key_color } } })) } as RpcResponseMap[M];

    case 'library.updateSpace': {
      const req = payload as RpcRequestMap['library.updateSpace'];
      const target = st.spaces.find((s) => s.id === req.id);
      if (!target) throw new Error('Space not found.');
      if (typeof req.title === 'string') target.title = req.title.trim() || target.title;
      if (req.icon) target.icon = req.icon;
      if (req.style) target.style = { ...req.style };
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'spaces' });
      return { space: { ...target } } as RpcResponseMap[M];
    }

    case 'library.deleteSpace': {
      const req = payload as RpcRequestMap['library.deleteSpace'];
      if (st.spaces.length <= 1) throw new Error('Cannot delete the last remaining Space.');
      st.spaces = st.spaces.filter((s) => s.id !== req.id);
      emitEvent(RPC_EVENTS.stateChanged, { scope: 'spaces' });
      return { ok: true } as RpcResponseMap[M];
    }

    case 'library.getMedia': {
      const req = payload as RpcRequestMap['library.getMedia'];
      const q = (req.query ?? '').trim().toLowerCase();
      const items = st.media.filter((m) => {
        if (req.profile_id && req.profile_id !== 'all' && m.profile_id !== req.profile_id) return false;
        if (q && !m.title.toLowerCase().includes(q) && !m.source_url.toLowerCase().includes(q)) return false;
        return true;
      });
      return { items } as RpcResponseMap[M];
    }

    case 'library.getEasels': {
      const req = payload as RpcRequestMap['library.getEasels'];
      const q = (req.query ?? '').trim().toLowerCase();
      const easels: EaselSummary[] = Object.values(st.easels)
        .map((doc) => ({
          id: doc.id,
          title: doc.title,
          element_count: doc.elements.length,
          palette: doc.palette,
          modified_at: doc.modified_at,
          profile_id: defaultProfileId,
        }))
        .filter((e) => !q || e.title.toLowerCase().includes(q));
      return { easels } as RpcResponseMap[M];
    }

    case 'library.openUrl':
      return { ok: true } as RpcResponseMap[M];

    // --- Boosts & Zap ---
    case 'boosts.list': {
      const req = payload as RpcRequestMap['boosts.list'];
      const boosts = st.boosts.filter(
        (b) => !req.profile_id || req.profile_id === 'all' || b.profile_id === req.profile_id,
      );
      return {
        boosts: boosts.map((b) => ({ ...b, color: { ...b.color }, zapped_elements: [...b.zapped_elements] })),
        global_enabled: Boolean(st.preferences['advanced.enableBoosts']),
      } as RpcResponseMap[M];
    }

    case 'boosts.save': {
      const req = payload as RpcRequestMap['boosts.save'];
      const now = Math.floor(Date.now() / 1000);
      const clamped: Boost = {
        ...req.boost,
        id: req.boost.id || `boost-${Date.now()}`,
        text_zoom: Math.min(2.0, Math.max(0.5, req.boost.text_zoom || 1.0)),
        modified_at: now,
        created_at: req.boost.created_at || now,
      };
      const idx = st.boosts.findIndex((b) => b.id === clamped.id);
      if (idx >= 0) st.boosts[idx] = clamped;
      else st.boosts.unshift(clamped);
      return { boost: clamped } as RpcResponseMap[M];
    }

    case 'boosts.delete': {
      const req = payload as RpcRequestMap['boosts.delete'];
      st.boosts = st.boosts.filter((b) => b.id !== req.id);
      return { ok: true } as RpcResponseMap[M];
    }

    case 'boosts.toggle': {
      const req = payload as RpcRequestMap['boosts.toggle'];
      const target = st.boosts.find((b) => b.id === req.id);
      if (!target) throw new Error('Boost not found.');
      target.enabled = req.enabled;
      return { boost: { ...target } } as RpcResponseMap[M];
    }

    case 'boosts.startZap': {
      const req = payload as RpcRequestMap['boosts.startZap'];
      const target = st.boosts.find((b) => b.id === req.boost_id);
      if (target && req.mode !== 'select') {
        const nextNum = target.zapped_elements.length + 1;
        target.zapped_elements.push({
          id: `zap-${Date.now()}`,
          selector: `.promo-banner-${nextNum}`,
          label: `Zapped element #${nextNum}`,
        });
      }
      return {
        armed: true,
        message: req.mode === 'select' ? 'Selector picker armed on active tab.' : 'Zap picker armed on active tab.',
      } as RpcResponseMap[M];
    }

    case 'boosts.removeZap': {
      const req = payload as RpcRequestMap['boosts.removeZap'];
      const target = st.boosts.find((b) => b.id === req.boost_id);
      if (!target) throw new Error('Boost not found.');
      target.zapped_elements = target.zapped_elements.filter((z) => z.id !== req.zap_id);
      return { boost: { ...target, zapped_elements: [...target.zapped_elements] } } as RpcResponseMap[M];
    }

    // --- Easels & Notes ---
    case 'easel.load': {
      const req = payload as RpcRequestMap['easel.load'];
      const id = req.id || 'easel-default';
      let doc = st.easels[id];
      if (!doc) {
        doc = {
          format_version: 1,
          id,
          title: 'Untitled Easel',
          canvas_width: 1000,
          canvas_height: 1400,
          palette: 'vibrant',
          elements: [],
          created_at: NOW_SEC,
          modified_at: NOW_SEC,
        };
        st.easels[id] = doc;
      }
      return { document: { ...doc, elements: doc.elements.map((e) => ({ ...e })) } } as RpcResponseMap[M];
    }

    case 'easel.save': {
      const req = payload as RpcRequestMap['easel.save'];
      const modified = Math.floor(Date.now() / 1000);
      st.easels[req.document.id] = { ...req.document, modified_at: modified };
      return { ok: true, modified_at: modified } as RpcResponseMap[M];
    }

    case 'easel.exportHtml': {
      const req = payload as RpcRequestMap['easel.exportHtml'];
      const doc = req.document;
      const safeTitle = doc.title.replace(/[<>&"]/g, '');
      const itemsHtml = doc.elements
        .slice()
        .sort((a, b) => a.z_index - b.z_index)
        .map((el) => {
          const leftPct = ((el.x / doc.canvas_width) * 100).toFixed(3);
          const widthPct = ((el.width / doc.canvas_width) * 100).toFixed(3);
          return `<div style="position:absolute;left:${leftPct}%;top:${Math.round(el.y)}px;width:${widthPct}%;height:${Math.round(el.height)}px;background:${el.fill_color || 'transparent'};border:${el.stroke_width}px solid ${el.stroke_color || 'transparent'};border-radius:${el.type === 'ellipse' ? '9999px' : '12px'};padding:10px;box-sizing:border-box;font-size:${el.font_size}px;color:#fff;">${el.content.replace(/[<>&]/g, '')}</div>`;
        })
        .join('\n');
      const html = `<!doctype html>\n<html><head><meta charset="utf-8"><title>${safeTitle}</title></head><body style="margin:0;background:#15151c;color:#f4f4f8;font-family:system-ui,sans-serif;"><main style="position:relative;max-width:${doc.canvas_width}px;min-height:${doc.canvas_height}px;margin:24px auto;background:#1d1d27;border-radius:16px;overflow:hidden;">${itemsHtml}</main></body></html>`;
      return { html, filename: `${safeTitle.toLowerCase().replace(/[^a-z0-9]+/g, '-') || 'easel'}.html` } as RpcResponseMap[M];
    }

    case 'note.load': {
      const req = payload as RpcRequestMap['note.load'];
      const id = req.id || 'note-default';
      let doc = st.notes[id];
      if (!doc) {
        doc = {
          format_version: 1,
          id,
          title: 'Untitled Note',
          text: '',
          formats: [],
          created_at: NOW_SEC,
          modified_at: NOW_SEC,
        };
        st.notes[id] = doc;
      }
      return { document: { ...doc, formats: doc.formats.map((f) => ({ ...f })) } } as RpcResponseMap[M];
    }

    case 'note.save': {
      const req = payload as RpcRequestMap['note.save'];
      const modified = Math.floor(Date.now() / 1000);
      st.notes[req.document.id] = { ...req.document, modified_at: modified };
      return { ok: true, modified_at: modified } as RpcResponseMap[M];
    }

    // --- Onboarding, Import & Welcome ---
    case 'onboarding.getState':
      return {
        completed: st.onboardingCompleted,
        default_space_style: st.spaces[0]!.style,
        is_default_browser: st.isDefaultBrowser,
        adblock_enabled: st.adBlockGlobalEnabled,
      } as RpcResponseMap[M];

    case 'onboarding.complete': {
      const req = payload as RpcRequestMap['onboarding.complete'];
      st.onboardingCompleted = true;
      st.adBlockGlobalEnabled = req.adblock_enabled;
      if (req.make_default_browser) st.isDefaultBrowser = true;
      if (st.spaces[0]) {
        st.spaces[0].style = req.space_style;
      }
      return { ok: true, welcome_url: 'open://welcome' } as RpcResponseMap[M];
    }

    case 'import.probeBrowsers':
      return {
        sources: [
          {
            id: 'arc-default',
            browser_name: 'Arc',
            profile_name: 'Default',
            bookmarks_count: 42,
            history_count: 640,
            extensions_count: 5,
            passwords_count: 18,
            favorites_count: 6,
          },
          {
            id: 'chrome-default',
            browser_name: 'Google Chrome',
            profile_name: 'Default',
            bookmarks_count: 88,
            history_count: 1205,
            extensions_count: 7,
            passwords_count: 34,
            favorites_count: 0,
          },
          {
            id: 'firefox-default',
            browser_name: 'Firefox',
            profile_name: 'default-release',
            bookmarks_count: 19,
            history_count: 310,
            extensions_count: 2,
            passwords_count: 4,
            favorites_count: 0,
          },
        ],
      } as RpcResponseMap[M];

    case 'import.run': {
      const req = payload as RpcRequestMap['import.run'];
      emitEvent(RPC_EVENTS.importProgress, { source_id: req.source_id, progress: 1, done: true });
      return {
        ok: true,
        imported_bookmarks: req.kinds.includes('bookmarks') ? 42 : 0,
        imported_history: req.kinds.includes('history') ? 640 : 0,
        imported_favorites: req.source_id.startsWith('arc') ? 6 : 0,
      } as RpcResponseMap[M];
    }

    case 'welcome.triggerAction': {
      const req = payload as RpcRequestMap['welcome.triggerAction'];
      return { ok: true, message: `Triggered ${req.action}` } as RpcResponseMap[M];
    }
  }
}
