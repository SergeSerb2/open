// Typed calls for open://onboarding and open://welcome.
//
// The C++ side is Unified/src/open_unified/ui/webui/open_onboarding_ui.{h,cc}.
// Methods that shared/bridge.ts does not list yet (onboarding.prefetchFavicons,
// welcome.getState, welcome.markStepDone) go through the same open.rpc channel
// with their canonical names. Outside Chromium (Vite dev/preview) every call
// has an in-memory preview so the pages stay interactive.

import { type SpaceStyle, isNativeWebUI, rpc } from '../shared/bridge';

type RawRpc = (method: string, payload?: unknown) => Promise<unknown>;
const rawRpc = rpc as unknown as RawRpc;

export const EXTRA_METHODS = {
  prefetchFavicons: 'onboarding.prefetchFavicons',
  welcomeGetState: 'welcome.getState',
  welcomeMarkStepDone: 'welcome.markStepDone',
} as const;

export const ONBOARDING_COMPLETED_EVENT = 'open.onboardingCompleted' as const;

// --- Types --------------------------------------------------------------------

export type ImportKind =
  | 'bookmarks'
  | 'favorites'
  | 'history'
  | 'spaces'
  | 'boosts'
  | 'documents'
  | 'archive'
  | 'preferences';

export type SourceFamily = 'arc' | 'chromium' | 'firefox' | 'safari' | 'open-legacy' | 'html';

export interface ImportSource {
  id: string;
  browser_id: string;
  browser_name: string;
  profile_name: string;
  family: SourceFamily;
  is_default: boolean;
  recommended: boolean;
  read_only: boolean;
  access_denied: boolean;
  access_error?: string;
  bookmarks_count: number;
  history_count: number;
  supported_kinds: ImportKind[];
  imported_kinds: ImportKind[];
}

export interface OnboardingState {
  completed: boolean;
  first_run: boolean;
  default_space_style: SpaceStyle;
  space_title: string;
  user_name: string;
  existing_favorite_urls: string[];
  is_default_browser: boolean;
  adblock_enabled: boolean;
  platform: 'mac' | 'windows' | 'linux';
}

export interface ImportCounts {
  ok: boolean;
  imported_bookmarks: number;
  imported_history: number;
  imported_favorites: number;
  imported_spaces: number;
  imported_tabs: number;
  imported_boosts: number;
  imported_documents: number;
  imported_archive: number;
  skipped_already_imported: number;
  error?: string;
}

export type HandoffMode = 'navigated' | 'selected_existing' | 'opened' | 'none';

export interface CompletePayload {
  user_name: string;
  favorite_urls: string[];
  space_style: SpaceStyle;
  adblock_enabled: boolean;
  make_default_browser: boolean;
  replay: boolean;
  import?: { source_id: string; kinds: ImportKind[] };
}

export interface CompleteResult {
  ok: boolean;
  replay: boolean;
  welcome_url: string;
  handoff: HandoffMode;
  welcome_tab_id: string;
  favorites_added: number;
  import?: ImportCounts;
}

export interface FaviconResult {
  page_url: string;
  icon?: string;
  source?: string;
  fallback_color?: string;
}

export interface WelcomeStep {
  id: string;
  title: string;
  action: string;
  done: boolean;
}

export interface EssentialShortcut {
  id: string;
  title: string;
  group: string;
  keys: string;
}

export interface WelcomeState {
  user_name: string;
  steps: WelcomeStep[];
  done_count: number;
  total: number;
  shortcuts: EssentialShortcut[];
  space: { id?: string; title?: string; style?: SpaceStyle };
  platform: 'mac' | 'windows' | 'linux';
  onboarding_completed: boolean;
}

export interface WelcomeActionResult {
  ok: boolean;
  message?: string;
  steps?: WelcomeStep[];
  done_count?: number;
}

// --- Normalization (the reply is data from another process) -----------------------

const ALL_KINDS: readonly ImportKind[] = [
  'bookmarks',
  'favorites',
  'history',
  'spaces',
  'boosts',
  'documents',
  'archive',
  'preferences',
];

function str(v: unknown, fallback = ''): string {
  return typeof v === 'string' ? v : fallback;
}
function num(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}
function bool(v: unknown): boolean {
  return v === true;
}
function kinds(v: unknown): ImportKind[] {
  return Array.isArray(v) ? v.filter((k): k is ImportKind => ALL_KINDS.includes(k as ImportKind)) : [];
}

function inferFamily(name: string, id: string): SourceFamily {
  const n = `${name} ${id}`.toLowerCase();
  if (n.includes('legacy')) return 'open-legacy';
  if (n.includes('safari')) return 'safari';
  if (n.includes('firefox')) return 'firefox';
  if (/\barc\b/.test(n) || n.startsWith('arc')) return 'arc';
  return 'chromium';
}

export function supportedKindsFor(family: SourceFamily): ImportKind[] {
  switch (family) {
    case 'arc':
      return ['spaces', 'favorites', 'history', 'boosts', 'documents', 'archive'];
    case 'open-legacy':
      return ['spaces', 'favorites', 'history', 'boosts', 'documents', 'archive', 'preferences'];
    case 'html':
      return ['bookmarks'];
    default:
      return ['bookmarks', 'history'];
  }
}

function normalizeSource(raw: unknown): ImportSource | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const id = str(r.id);
  if (!id) return null;
  const browserName = str(r.browser_name, 'Browser');
  const familyRaw = str(r.family);
  const family: SourceFamily = (
    ['arc', 'chromium', 'firefox', 'safari', 'open-legacy', 'html'] as const
  ).includes(familyRaw as SourceFamily)
    ? (familyRaw as SourceFamily)
    : inferFamily(browserName, id);
  const supported = kinds(r.supported_kinds);
  const source: ImportSource = {
    id,
    browser_id: str(r.browser_id, id.split('/')[0] ?? id),
    browser_name: browserName,
    profile_name: str(r.profile_name),
    family,
    is_default: bool(r.is_default),
    recommended: bool(r.recommended) || family === 'open-legacy',
    read_only: r.read_only === undefined ? true : bool(r.read_only),
    access_denied: bool(r.access_denied),
    bookmarks_count: num(r.bookmarks_count),
    history_count: num(r.history_count),
    supported_kinds: supported.length ? supported : supportedKindsFor(family),
    imported_kinds: kinds(r.imported_kinds),
  };
  const accessError = str(r.access_error);
  if (accessError) source.access_error = accessError;
  return source;
}

const FAMILY_ORDER: Record<SourceFamily, number> = {
  'open-legacy': 0,
  arc: 1,
  safari: 2,
  chromium: 3,
  firefox: 4,
  html: 5,
};

// --- Preview state (Vite dev/preview only) ------------------------------------------

function previewParam(name: string): string | null {
  try {
    return new URLSearchParams(window.location.search).get(name);
  } catch {
    return null;
  }
}

function readLocal<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}
function writeLocal(key: string, value: unknown): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Private windows refuse storage; the preview still works in memory.
  }
}

const PREVIEW_STEPS_KEY = 'open.preview.welcomeSteps';
const PREVIEW_STEP_DEFS: readonly Omit<WelcomeStep, 'done'>[] = [
  { id: 'command-bar', title: 'Open the Command Bar', action: 'open-command-bar' },
  { id: 'sidebar', title: 'Hide and show the sidebar', action: 'toggle-sidebar' },
  { id: 'peek', title: 'Peek at a link', action: 'peek' },
  { id: 'split', title: 'Open a Split View', action: 'split-view' },
  { id: 'boosts', title: 'Make a Boost', action: 'new-boost' },
  { id: 'library', title: 'Open the Library', action: 'view-library' },
  { id: 'theme', title: 'Edit your Space theme', action: 'edit-theme' },
];

const ACTION_STEP: Record<string, string> = {
  'open-command-bar': 'command-bar',
  new_tab: 'command-bar',
  'toggle-sidebar': 'sidebar',
  peek: 'peek',
  'split-view': 'split',
  split: 'split',
  'new-boost': 'boosts',
  'boost-gallery': 'boosts',
  'view-library': 'library',
  'edit-theme': 'theme',
};

function previewSteps(): WelcomeStep[] {
  const done = new Set(readLocal<string[]>(PREVIEW_STEPS_KEY, []));
  return PREVIEW_STEP_DEFS.map((s) => ({ ...s, done: done.has(s.id) }));
}

function previewMark(step: string, done: boolean): WelcomeStep[] {
  const set = new Set(readLocal<string[]>(PREVIEW_STEPS_KEY, []));
  if (done) set.add(step);
  else set.delete(step);
  writeLocal(PREVIEW_STEPS_KEY, [...set]);
  return previewSteps();
}

const PREVIEW_SHORTCUTS: readonly EssentialShortcut[] = [
  { id: 'new-tab', title: 'New Tab…', group: 'Navigation', keys: 'Mod+T' },
  { id: 'open-command-bar', title: 'Open Command Bar', group: 'Navigation', keys: 'Mod+L' },
  { id: 'toggle-sidebar', title: 'Show/Hide Sidebar', group: 'Navigation', keys: 'Mod+S' },
  { id: 'go-back', title: 'Back', group: 'Navigation', keys: 'Mod+[' },
  { id: 'go-forward', title: 'Forward', group: 'Navigation', keys: 'Mod+]' },
  { id: 'find', title: 'Find…', group: 'Navigation', keys: 'Mod+F' },
  { id: 'copy-url', title: 'Copy URL', group: 'Navigation', keys: 'Mod+Shift+C' },
  { id: 'pin-unpin-tab', title: 'Pin/Unpin Tab', group: 'Tabs', keys: 'Mod+D' },
  { id: 'archive-tab', title: 'Archive Tab', group: 'Tabs', keys: 'Mod+W' },
  { id: 'restore-last-closed-tab', title: 'Reopen Last Closed Tab', group: 'Tabs', keys: 'Mod+Shift+T' },
  { id: 'tab-switcher-forward', title: 'Switch to a Recent Tab', group: 'Tabs', keys: 'Ctrl+Tab' },
  { id: 'next-tab', title: 'Next Tab', group: 'Tabs', keys: 'Mod+Alt+Down' },
  { id: 'next-space', title: 'Next Space', group: 'Spaces', keys: 'Mod+Alt+Right' },
  { id: 'previous-space', title: 'Previous Space', group: 'Spaces', keys: 'Mod+Alt+Left' },
  { id: 'go-to-space-1', title: 'Go to Space 1', group: 'Spaces', keys: 'Ctrl+1' },
  { id: 'add-split-view', title: 'Add Split View', group: 'Split & Peek', keys: 'Ctrl+Shift+=' },
  { id: 'close-split-pane', title: 'Close Split Pane', group: 'Split & Peek', keys: 'Ctrl+Shift+-' },
  { id: 'new-little-open-window', title: 'New Little Open Window', group: 'Split & Peek', keys: 'Mod+Alt+N' },
  { id: 'capture-page', title: 'Capture…', group: 'Boosts & Capture', keys: 'Mod+Shift+2' },
  { id: 'new-easel', title: 'New Easel', group: 'Boosts & Capture', keys: '' },
  { id: 'new-boost', title: 'New Boost', group: 'Boosts & Capture', keys: '' },
];

function previewPlatform(): 'mac' | 'windows' | 'linux' {
  const p = previewParam('platform');
  if (p === 'mac' || p === 'windows' || p === 'linux') return p;
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent.toLowerCase() : '';
  if (ua.includes('mac')) return 'mac';
  if (ua.includes('win')) return 'windows';
  return 'linux';
}

// --- Calls --------------------------------------------------------------------

export async function getOnboardingState(): Promise<OnboardingState> {
  const raw = (await rawRpc('onboarding.getState', {})) as Record<string, unknown>;
  const style = raw.default_space_style as SpaceStyle | undefined;
  const platform = str(raw.platform);
  return {
    completed: isNativeWebUI() ? bool(raw.completed) : previewParam('replay') === '1',
    first_run: bool(raw.first_run),
    default_space_style: style ?? {
      math_version: 1,
      key_color: { r: 0.19, g: 0.22, b: 1, a: 1 },
      color_count: 2,
      wheel: 'analogous',
      appearance: 'automatic',
      noise_factor: 0.16,
      texture: 'grain',
      intensity_factor: 0.65,
    },
    space_title: str(raw.space_title),
    user_name: str(raw.user_name),
    existing_favorite_urls: Array.isArray(raw.existing_favorite_urls)
      ? raw.existing_favorite_urls.filter((u): u is string => typeof u === 'string')
      : [],
    is_default_browser: bool(raw.is_default_browser),
    adblock_enabled: raw.adblock_enabled === undefined ? true : bool(raw.adblock_enabled),
    platform: platform === 'mac' || platform === 'windows' || platform === 'linux' ? platform : previewPlatform(),
  };
}

export async function probeImportSources(): Promise<ImportSource[]> {
  const raw = (await rawRpc('import.probeBrowsers', {})) as { sources?: unknown[] };
  const sources = (raw.sources ?? []).map(normalizeSource).filter((s): s is ImportSource => s !== null);
  if (!isNativeWebUI() && previewParam('sources') !== 'none') {
    // The preview adapter knows only Chromium-style rows; add the macOS-only
    // sources so every card state can be seen outside the browser.
    sources.push(
      {
        id: 'open-legacy/OpenLegacy',
        browser_id: 'open-legacy',
        browser_name: 'Open (Legacy)',
        profile_name: 'Open (Legacy)',
        family: 'open-legacy',
        is_default: true,
        recommended: true,
        read_only: true,
        access_denied: false,
        bookmarks_count: 128,
        history_count: 4210,
        supported_kinds: supportedKindsFor('open-legacy'),
        imported_kinds: [],
      },
      {
        id: 'safari/Safari',
        browser_id: 'safari',
        browser_name: 'Safari',
        profile_name: 'Safari',
        family: 'safari',
        is_default: true,
        recommended: false,
        read_only: true,
        access_denied: true,
        access_error: 'Full Disk Access required to read Safari data',
        bookmarks_count: 0,
        history_count: 0,
        supported_kinds: supportedKindsFor('safari'),
        imported_kinds: [],
      },
    );
  }
  if (previewParam('sources') === 'none') return [];
  return sources.sort((a, b) => FAMILY_ORDER[a.family] - FAMILY_ORDER[b.family]);
}

export async function completeOnboarding(payload: CompletePayload): Promise<CompleteResult> {
  if (!isNativeWebUI()) {
    await rawRpc('onboarding.complete', { ...payload, imported_source_id: payload.import?.source_id });
    await new Promise((r) => window.setTimeout(r, 450));
    if (previewParam('fail') === 'import' && payload.import) {
      throw new Error('Import failed: that browser profile was not found');
    }
    return {
      ok: true,
      replay: payload.replay,
      welcome_url: 'open://welcome',
      handoff: 'none',
      welcome_tab_id: '',
      favorites_added: payload.favorite_urls.length,
    };
  }
  const raw = (await rawRpc('onboarding.complete', payload)) as Record<string, unknown>;
  const handoff = str(raw.handoff, 'none');
  return {
    ok: raw.ok !== false,
    replay: bool(raw.replay),
    welcome_url: str(raw.welcome_url, 'open://welcome/'),
    handoff: (['navigated', 'selected_existing', 'opened', 'none'] as const).includes(handoff as HandoffMode)
      ? (handoff as HandoffMode)
      : 'none',
    welcome_tab_id: str(raw.welcome_tab_id),
    favorites_added: num(raw.favorites_added),
    import: raw.import as ImportCounts | undefined,
  };
}

export async function prefetchFavicons(urls: string[]): Promise<FaviconResult[]> {
  if (!isNativeWebUI() || urls.length === 0) return [];
  try {
    const raw = (await rawRpc(EXTRA_METHODS.prefetchFavicons, { urls })) as { icons?: unknown[] };
    return (raw.icons ?? []).flatMap((item) => {
      if (!item || typeof item !== 'object') return [];
      const r = item as Record<string, unknown>;
      const icon = str(r.icon);
      const result: FaviconResult = { page_url: str(r.page_url) };
      // Only inline images: the page CSP allows data: and chrome://favicon2.
      if (icon.startsWith('data:image/')) result.icon = icon;
      const source = str(r.source);
      if (source) result.source = source;
      const fallback = str(r.fallback_color);
      if (/^#[0-9a-f]{6}$/i.test(fallback)) result.fallback_color = fallback;
      return [result];
    });
  } catch {
    // An older browser build without the method: monograms stay.
    return [];
  }
}

export async function getWelcomeState(): Promise<WelcomeState> {
  if (!isNativeWebUI()) {
    const steps = previewSteps();
    return {
      user_name: previewParam('name') ?? '',
      steps,
      done_count: steps.filter((s) => s.done).length,
      total: steps.length,
      shortcuts: [...PREVIEW_SHORTCUTS],
      space: {},
      platform: previewPlatform(),
      onboarding_completed: true,
    };
  }
  const raw = (await rawRpc(EXTRA_METHODS.welcomeGetState, {})) as Record<string, unknown>;
  const steps = normalizeSteps(raw.steps);
  const space = (raw.space && typeof raw.space === 'object' ? raw.space : {}) as WelcomeState['space'];
  const platform = str(raw.platform);
  return {
    user_name: str(raw.user_name),
    steps,
    done_count: steps.filter((s) => s.done).length,
    total: steps.length,
    shortcuts: Array.isArray(raw.shortcuts)
      ? raw.shortcuts.flatMap((item) => {
          if (!item || typeof item !== 'object') return [];
          const r = item as Record<string, unknown>;
          return [{ id: str(r.id), title: str(r.title), group: str(r.group, 'Navigation'), keys: str(r.keys) }];
        })
      : [],
    space,
    platform: platform === 'mac' || platform === 'windows' || platform === 'linux' ? platform : previewPlatform(),
    onboarding_completed: bool(raw.onboarding_completed),
  };
}

function normalizeSteps(raw: unknown): WelcomeStep[] {
  if (!Array.isArray(raw)) return previewSteps().map((s) => ({ ...s, done: false }));
  return raw.flatMap((item) => {
    if (!item || typeof item !== 'object') return [];
    const r = item as Record<string, unknown>;
    return [{ id: str(r.id), title: str(r.title), action: str(r.action), done: bool(r.done) }];
  });
}

export async function triggerWelcomeAction(action: string): Promise<WelcomeActionResult> {
  if (!isNativeWebUI()) {
    const step = ACTION_STEP[action];
    const steps = step ? previewMark(step, true) : previewSteps();
    return { ok: true, message: `Preview: ${action}`, steps, done_count: steps.filter((s) => s.done).length };
  }
  const raw = (await rawRpc('welcome.triggerAction', { action })) as Record<string, unknown>;
  const result: WelcomeActionResult = { ok: raw.ok !== false };
  const message = str(raw.message);
  if (message) result.message = message;
  if (Array.isArray(raw.steps)) {
    result.steps = normalizeSteps(raw.steps);
    result.done_count = result.steps.filter((s) => s.done).length;
  }
  return result;
}

export async function markWelcomeStep(step: string, done: boolean): Promise<WelcomeStep[]> {
  if (!isNativeWebUI()) return previewMark(step, done);
  const raw = (await rawRpc(EXTRA_METHODS.welcomeMarkStepDone, { step, done })) as Record<string, unknown>;
  return normalizeSteps(raw.steps);
}
