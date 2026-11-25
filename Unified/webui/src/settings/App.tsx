import type { JSX } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import {
  type AdBlockState,
  type BrowserImportSource,
  type ExtensionItem,
  type ProfileSummary,
  type RoutingDestination,
  type RoutingRule,
  type RoutingTestResult,
  type SettingsSnapshot,
  type ShortcutBinding,
  type SpaceSummary,
  type SyncStatus,
  RPC_EVENTS,
  rpc,
  subscribeEvent,
} from '../shared/bridge';
import { BUILTIN_SEARCH_ENGINES, SYNC_CATEGORIES, type AdBlockListCategory } from '../shared/catalog';
import {
  Badge,
  Card,
  Modal,
  ProfilePill,
  SearchInput,
  SegmentedControl,
  SettingRow,
  ShortcutRecorder,
  Toast,
  Toggle,
} from '../shared/components';
import { CloseIcon, ExternalIcon, OpenDoorwayMark, PlusIcon, ShieldIcon, SyncIcon, TrashIcon } from '../shared/icons';
import { currentPageRoute } from '../shared/route';
import { formatShortcut, isMacPlatform } from '../shared/shortcuts';

// Platform-formatted labels ("⌘9" on macOS, "Ctrl+9" elsewhere).
const NINTH_TAB_LABEL = `${formatShortcut('Mod+9')} jumps to last tab`;
const LITTLE_OPEN_CLICK_LABEL = isMacPlatform()
  ? 'Option-Command-click opens Little Open'
  : 'Ctrl+Alt+click opens Little Open';
const LITTLE_OPEN_CLICK_HELP = `Hold ${formatShortcut('Mod+Alt+Click').replace(/Click$/, '').replace(/\+$/, '')} while clicking any link to open it in Little Open.`;

// The category chips of the ad-block catalog (counts come from the lists).
const ADBLOCK_CATEGORY_CHIPS: readonly (readonly ['all' | AdBlockListCategory, string])[] = [
  ['all', 'All'],
  ['generic', 'Generic'],
  ['cookies', 'Cookies'],
  ['privacy', 'Privacy'],
  ['regional', 'Regional'],
  ['bcny', 'BCNY'],
];

type SectionId =
  | 'general'
  | 'appearance'
  | 'tabs-archive'
  | 'search'
  | 'links'
  | 'downloads'
  | 'previews'
  | 'ad-blocking'
  | 'site-permissions'
  | 'passwords-cards'
  | 'browsing-data'
  | 'account-sync'
  | 'profiles'
  | 'shortcuts'
  | 'extensions'
  | 'advanced';

interface SectionDef {
  id: SectionId;
  title: string;
  subtitle: string;
  profileScoped?: boolean;
}

const SECTIONS: readonly SectionDef[] = [
  { id: 'general', title: 'General', subtitle: 'Default browser, updates, startup behavior, and data transfer.' },
  { id: 'appearance', title: 'Appearance', subtitle: 'App icon, website color scheme, and focused-window toolbar.' },
  { id: 'tabs-archive', title: 'Tabs & Archive', subtitle: 'Auto-archive schedule, sleeping tabs, and tab switching.', profileScoped: true },
  { id: 'search', title: 'Search', subtitle: 'Default search engine, suggestions, and custom keywords.', profileScoped: true },
  { id: 'links', title: 'Links', subtitle: 'Little Open, Peek previews, and Air Traffic Control routing rules.' },
  { id: 'downloads', title: 'Downloads', subtitle: 'Save location and download prompt behavior.', profileScoped: true },
  { id: 'previews', title: 'Previews', subtitle: 'Hover previews for pinned folders and supported pages.' },
  { id: 'ad-blocking', title: 'Ad Blocking', subtitle: 'Built-in Rust content blocker, filter list catalog, and site exceptions.', profileScoped: true },
  { id: 'site-permissions', title: 'Site Permissions', subtitle: 'Privacy, camera, microphone, and notification permissions.', profileScoped: true },
  { id: 'passwords-cards', title: 'Passwords & Cards', subtitle: 'Saved logins, passkeys, and payment autofill.', profileScoped: true },
  { id: 'browsing-data', title: 'Browsing Data', subtitle: 'Clear history, cookies, cached files, and download logs.', profileScoped: true },
  { id: 'account-sync', title: 'Account & Sync', subtitle: 'Optional zero-knowledge end-to-end encrypted sync.' },
  { id: 'profiles', title: 'Profiles', subtitle: 'Organize isolated cookies, history, extensions, and Spaces.' },
  { id: 'shortcuts', title: 'Shortcuts', subtitle: 'Customize every Open command and resolve website shortcut conflicts.' },
  { id: 'extensions', title: 'Extensions', subtitle: 'Manage Chrome Web Store extensions and toolbar pins.' },
  { id: 'advanced', title: 'Advanced', subtitle: 'Feedback, media behavior, Boosts switch, and diagnostics.' },
];

interface SearchIndexItem {
  id: string;
  section: SectionId;
  label: string;
  help: string;
  prefKey?: string;
  aliases?: string;
}

const SEARCH_INDEX: readonly SearchIndexItem[] = [
  { id: 'general/default-browser', section: 'general', label: 'Default browser', help: 'Make Open your default web browser.' },
  { id: 'general/automatic-updates', section: 'general', label: 'Automatic updates', help: 'Keep Open up to date automatically.', prefKey: 'general.automaticUpdates' },
  { id: 'general/warn-before-quitting', section: 'general', label: 'Warn before quitting', help: 'Confirm quit when downloads are active.', prefKey: 'general.warnBeforeQuitting' },
  { id: 'general/restore-windows', section: 'general', label: 'Restore windows on launch', help: 'Reopen previous Spaces and tabs.', prefKey: 'general.restoreWindows' },
  { id: 'general/import', section: 'general', label: 'Import from another browser', help: 'Import bookmarks, history, and Favorites from Arc, Chrome, or Firefox.' },
  { id: 'appearance/app-icon', section: 'appearance', label: 'App icon', help: 'Choose Open artwork for dock and taskbar.', prefKey: 'appearance.appIcon' },
  { id: 'appearance/website-appearance', section: 'appearance', label: 'Website appearance', help: 'Automatic, Light, or Dark color scheme for websites.', prefKey: 'appearance.websiteAppearance' },
  { id: 'appearance/toolbar', section: 'appearance', label: 'Show toolbar', help: 'Show navigation toolbar in focused window.', prefKey: 'appearance.toolbar' },
  { id: 'appearance/full-url', section: 'appearance', label: 'Always show full URL', help: 'Show scheme and path in toolbar address field.', prefKey: 'appearance.fullUrl' },
  { id: 'tabs-archive/archive-after', section: 'tabs-archive', label: 'Auto-archive Today tabs', help: 'Automatically archive inactive Today tabs.', prefKey: 'tabs.archiveAfter' },
  { id: 'tabs-archive/little-open-archive', section: 'tabs-archive', label: 'Little Open auto-archive', help: 'Archive inactive Little Open windows.', prefKey: 'tabs.littleOpenArchiveAfter' },
  { id: 'tabs-archive/sleep', section: 'tabs-archive', label: 'Sleeping tabs policy', help: 'Discard idle tabs to save RAM and battery.', prefKey: 'tabs.sleepMode' },
  { id: 'tabs-archive/include-favorites', section: 'tabs-archive', label: 'Include Favorites in switcher', help: 'Include Favorite tabs in Ctrl+Tab.', prefKey: 'tabs.includeFavoritesInSwitcher' },
  { id: 'tabs-archive/ninth-tab', section: 'tabs-archive', label: NINTH_TAB_LABEL, help: 'Jump to the final tab instead of the ninth.', prefKey: 'tabs.ninthTabGoesToLast' },
  { id: 'search/engine', section: 'search', label: 'Default search engine', help: 'Search engine used in the Command Bar.', prefKey: 'search.engine' },
  { id: 'search/suggestions', section: 'search', label: 'Search suggestions', help: 'Show query completions as you type.', prefKey: 'search.suggestions' },
  { id: 'links/little-open-hotkey', section: 'links', label: 'Little Open hotkey', help: 'Global shortcut to open a quick Little Open window.', prefKey: 'links.littleOpenHotkey' },
  { id: 'links/option-command-click', section: 'links', label: LITTLE_OPEN_CLICK_LABEL, help: 'Open links in a quick floating window.', prefKey: 'links.optionCommandClick' },
  { id: 'links/peek-shift-click', section: 'links', label: 'Shift-click opens Peek', help: 'Preview a link in an overlay without leaving the tab.', prefKey: 'links.peekShiftClick' },
  { id: 'links/peek-other-sites', section: 'links', label: 'Peek links to other sites from Pinned tabs', help: 'Automatically Peek external links from Favorites and Pinned tabs.', prefKey: 'links.peekOtherSites' },
  { id: 'links/rules', section: 'links', label: 'Air Traffic Control routing rules', help: 'Route incoming URLs to specific Spaces or Little Open.', aliases: 'atc routing' },
  { id: 'links/test', section: 'links', label: 'Test a Link', help: 'Preview which Space or window a URL routes to.', aliases: 'atc test' },
  { id: 'downloads/location', section: 'downloads', label: 'Download location', help: 'Folder where downloaded files are saved.', prefKey: 'downloads.location' },
  { id: 'downloads/ask', section: 'downloads', label: 'Ask where to save each file', help: 'Prompt before starting each download.', prefKey: 'downloads.askEachTime' },
  { id: 'previews/enabled', section: 'previews', label: 'Enable hover previews', help: 'Show live preview cards on sidebar hover.', prefKey: 'previews.enabled' },
  { id: 'previews/folders', section: 'previews', label: 'Folder hover previews', help: 'Peek inside pinned folders on hover.', prefKey: 'previews.folders' },
  { id: 'previews/pages', section: 'previews', label: 'Page hover previews', help: 'Show live data previews for supported web apps.', prefKey: 'previews.pages' },
  { id: 'ad-blocking/enabled', section: 'ad-blocking', label: 'Built-in ad & tracker blocker', help: 'Block ads and trackers with the Rust adblock engine.' },
  { id: 'ad-blocking/lists', section: 'ad-blocking', label: 'Filter lists (46 lists)', help: 'EasyList, EasyPrivacy, cookies, and regional filter lists.' },
  { id: 'ad-blocking/allowed-sites', section: 'ad-blocking', label: 'Allowed sites (exclusions)', help: 'Disable ad blocking for specific domains.' },
  { id: 'site-permissions/privacy', section: 'site-permissions', label: 'Privacy & Site Settings', help: 'Camera, microphone, location, and cookies.' },
  { id: 'site-permissions/notifications', section: 'site-permissions', label: 'Notifications', help: 'Control which origins can show desktop notifications.' },
  { id: 'passwords-cards/passwords', section: 'passwords-cards', label: 'Saved Passwords', help: 'View and manage stored credentials.' },
  { id: 'passwords-cards/cards', section: 'passwords-cards', label: 'Payment Methods', help: 'Manage credit cards and autofill.' },
  { id: 'browsing-data/clear', section: 'browsing-data', label: 'Clear Browsing Data', help: 'Erase history, cookies, cache, or download records.' },
  { id: 'account-sync/account', section: 'account-sync', label: 'Open Account & Sync (E2EE)', help: 'Zero-knowledge AES-256-GCM encrypted sync across devices.' },
  { id: 'profiles/manage', section: 'profiles', label: 'Manage Profiles', help: 'Create, rename, or delete browser Profiles.' },
  { id: 'shortcuts/priority', section: 'shortcuts', label: 'Shortcut priority', help: 'Prefer Open shortcuts or website shortcuts.' },
  { id: 'extensions/manage', section: 'extensions', label: 'Installed Chrome Extensions', help: 'Enable, disable, or pin extensions.' },
  { id: 'advanced/sound', section: 'advanced', label: 'Sound effects', help: 'Play subtle audio cues for browser actions.', prefKey: 'advanced.soundEffects' },
  { id: 'advanced/haptics', section: 'advanced', label: 'Haptic feedback', help: 'Subtle trackpad feedback on snap points.', prefKey: 'advanced.haptics' },
  { id: 'advanced/picture-in-picture', section: 'advanced', label: 'Auto Picture-in-Picture', help: 'Float playing video when switching away from a tab.', prefKey: 'advanced.pictureInPicture' },
  { id: 'advanced/boosts', section: 'advanced', label: 'Enable Boosts', help: 'Allow custom per-site colors, fonts, CSS, JS, and Zaps.', prefKey: 'advanced.enableBoosts' },
];

const APP_ICONS = [
  { id: 'open-indigo', label: 'Indigo', bg: 'linear-gradient(135deg, #3139FF, #6E62FF)' },
  { id: 'open-obsidian', label: 'Obsidian', bg: 'linear-gradient(135deg, #1E1F2B, #3C4057)' },
  { id: 'open-sunburst', label: 'Sunburst', bg: 'linear-gradient(135deg, #F59E0B, #EF4444)' },
  { id: 'open-sage', label: 'Sage', bg: 'linear-gradient(135deg, #10B981, #047857)' },
  { id: 'open-slate', label: 'Slate', bg: 'linear-gradient(135deg, #64748B, #334155)' },
  { id: 'open-dawn', label: 'Dawn', bg: 'linear-gradient(135deg, #EC4899, #8B5CF6)' },
];

const SELF_HOST_AGENT_PROMPT = `Set up a private Open Sync Server for my Open browser from https://github.com/SergeSerb2/open (the \`SyncServer/\` folder).
1. Build and run \`SyncServer/\` using its \`Dockerfile\` (Node.js 22+ built-in SQLite + WebSockets).
2. Run a single instance with persistent storage mounted at /data and OPEN_SYNC_DATA_DIR=/data.
3. Expose HTTPS with WebSocket upgrades forwarded on /v1/sync/ws and set OPEN_SYNC_TRUST_PROXY=1.
4. Verify GET <url>/health returns {"ok":true,"service":"open-sync","version":1} and reply with my final https:// server URL.`;

// open://settings/<section>[/<row>] (C++ opens settings/shortcuts; a row
// such as settings/shortcuts/find is scrolled to and highlighted).
function parseInitialSection(): SectionId {
  const raw = currentPageRoute().segments[0];
  if (SECTIONS.some((s) => s.id === raw)) return raw as SectionId;
  return 'general';
}

function parseInitialRowId(): string | null {
  const { segments } = currentPageRoute();
  return segments[0] && segments[1] && SECTIONS.some((s) => s.id === segments[0])
    ? `${segments[0]}/${segments.slice(1).join('/')}`
    : null;
}

export function SettingsApp(): JSX.Element {
  const [section, setSection] = useState<SectionId>(parseInitialSection);
  const [historyStack, setHistoryStack] = useState<SectionId[]>([parseInitialSection()]);
  const [historyIdx, setHistoryIdx] = useState(0);
  const [pulsingRowId, setPulsingRowId] = useState<string | null>(null);

  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [spaces, setSpaces] = useState<SpaceSummary[]>([]);
  const [selectedProfileId, setSelectedProfileId] = useState<string>('');
  const [shortcuts, setShortcuts] = useState<ShortcutBinding[]>([]);
  const [shortcutPriority, setShortcutPriority] = useState<'open' | 'website'>('open');
  const [shortcutConflict, setShortcutConflict] = useState<string | null>(null);
  const [shortcutSearch, setShortcutSearch] = useState('');
  const [shortcutCat, setShortcutCat] = useState<string>('All');

  const [routingRules, setRoutingRules] = useState<RoutingRule[]>([]);
  const [defaultDestination, setDefaultDestination] = useState<RoutingDestination>({ kind: 'little_open' });
  const [ruleDraft, setRuleDraft] = useState<{
    id: string;
    name: string;
    host_pattern: string;
    path_prefix: string;
    source_app_id: string;
    destKind: RoutingDestination['kind'];
    destSpaceId: string;
  } | null>(null);
  const [testLinkOpen, setTestLinkOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('https://github.com/SergeSerb2/open');
  const [testSourceApp, setTestSourceApp] = useState('');
  const [testResult, setTestResult] = useState<RoutingTestResult | null>(null);

  const [adBlock, setAdBlock] = useState<AdBlockState | null>(null);
  const [adBlockQuery, setAdBlockQuery] = useState('');
  const [adBlockCategory, setAdBlockCategory] = useState<'all' | AdBlockListCategory>('all');
  const [newExclusionHost, setNewExclusionHost] = useState('');
  const [adBlockError, setAdBlockError] = useState<string | null>(null);

  const [extensions, setExtensions] = useState<ExtensionItem[]>([]);
  const [syncStatus, setSyncStatus] = useState<SyncStatus | null>(null);
  const [syncTab, setSyncTab] = useState<'login' | 'register' | 'recover'>('login');
  const [syncServerInput, setSyncServerInput] = useState('https://sync.example.com');
  const [syncEmail, setSyncEmail] = useState('');
  const [syncPassword, setSyncPassword] = useState('');
  const [syncRecoveryKey, setSyncRecoveryKey] = useState('');
  const [generatedRecoveryKey, setGeneratedRecoveryKey] = useState<string | null>(null);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchIndex, setSearchIndex] = useState(0);
  const searchRef = useRef<HTMLInputElement | null>(null);

  const [archiveApplyBanner, setArchiveApplyBanner] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  // Modals
  const [createProfileOpen, setCreateProfileOpen] = useState(false);
  const [newProfileName, setNewProfileName] = useState('');
  const [newProfileEmoji, setNewProfileEmoji] = useState('🚀');
  const [deleteProfileTarget, setDeleteProfileTarget] = useState<ProfileSummary | null>(null);
  const [deleteProfileConfirm, setDeleteProfileConfirm] = useState('');
  const [renamingProfileId, setRenamingProfileId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState('');

  const [clearModalOpen, setClearModalOpen] = useState(false);
  const [clearRange, setClearRange] = useState<'hour' | 'day' | 'week' | 'month' | 'all'>('day');
  const [clearKinds, setClearKinds] = useState<Record<string, boolean>>({
    history: true,
    cookies: false,
    cache: true,
    downloads: false,
  });

  const [importModalOpen, setImportModalOpen] = useState(false);
  const [importSources, setImportSources] = useState<BrowserImportSource[]>([]);
  const [selectedImportId, setSelectedImportId] = useState('');
  const [importStatus, setImportStatus] = useState<string | null>(null);

  const [resetAllShortcutsOpen, setResetAllShortcutsOpen] = useState(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((cur) => (cur === msg ? null : cur)), 2800);
  };

  const navigateSection = (target: SectionId, rowId?: string) => {
    setSection(target);
    setHistoryStack((prev) => {
      const next = prev.slice(0, historyIdx + 1);
      if (next[next.length - 1] !== target) next.push(target);
      setHistoryIdx(next.length - 1);
      return next;
    });
    if (rowId) {
      setPulsingRowId(rowId);
      window.setTimeout(() => {
        document.getElementById(rowId)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }, 30);
      window.setTimeout(() => setPulsingRowId((cur) => (cur === rowId ? null : cur)), 1000);
    }
  };

  // A deep-linked row (open://settings/shortcuts/<id>) is highlighted once
  // its section has rendered it (shortcut rows arrive with the RPC reply).
  const initialRowId = useRef<string | null>(parseInitialRowId());
  useEffect(() => {
    const rowId = initialRowId.current;
    if (!rowId || !document.getElementById(rowId)) return;
    initialRowId.current = null;
    navigateSection(section, rowId);
  });

  // Initial load
  useEffect(() => {
    let active = true;
    async function load() {
      const [allRes, profRes, spaceRes, scRes, routeRes, extRes, syncRes] = await Promise.all([
        rpc('settings.getAll', {}),
        rpc('settings.listProfiles', {}),
        rpc('library.getSpaces', {}),
        rpc('settings.getShortcuts', {}),
        rpc('settings.getRoutingRules', {}),
        rpc('settings.getExtensions', {}),
        rpc('sync.getStatus', {}),
      ]);
      if (!active) return;
      setSnapshot(allRes);
      setProfiles(profRes.profiles);
      setSpaces(spaceRes.spaces);
      const firstProfile = allRes.active_profile_id || profRes.profiles[0]?.id || '';
      setSelectedProfileId(firstProfile);
      setShortcuts(scRes.shortcuts);
      setShortcutPriority(scRes.priority);
      setRoutingRules(routeRes.rules);
      setDefaultDestination(routeRes.default_destination);
      setExtensions(extRes.extensions);
      setSyncStatus(syncRes);
      setSyncServerInput(syncRes.server_url);

      const ab = await rpc('settings.getAdBlockState', { profile_id: firstProfile });
      if (active) setAdBlock(ab);
    }
    void load();

    const unsubSync = subscribeEvent(RPC_EVENTS.syncStatusChanged, (p) => {
      if (p && typeof p === 'object') setSyncStatus(p as SyncStatus);
    });
    const unsubAd = subscribeEvent(RPC_EVENTS.adBlockUpdated, (p) => {
      if (p && typeof p === 'object') setAdBlock(p as AdBlockState);
    });
    return () => {
      active = false;
      unsubSync();
      unsubAd();
    };
  }, []);

  // Reload per-profile AdBlock when profile switches
  useEffect(() => {
    if (!selectedProfileId) return;
    let active = true;
    void rpc('settings.getAdBlockState', { profile_id: selectedProfileId }).then((ab) => {
      if (active) setAdBlock(ab);
    });
    return () => {
      active = false;
    };
  }, [selectedProfileId]);

  // Apply website appearance preview to document root
  useEffect(() => {
    const mode = snapshot?.preferences['appearance.websiteAppearance'];
    if (mode === 'dark' || mode === 'light') {
      document.documentElement.setAttribute('data-theme', mode);
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
  }, [snapshot?.preferences['appearance.websiteAppearance']]);

  // Global keyboard shortcuts: Cmd/Ctrl+F, Cmd/Ctrl+1..9, Cmd/Ctrl+[ and ], Escape
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        searchRef.current?.focus();
        searchRef.current?.select();
        return;
      }
      if (mod && !e.shiftKey && !e.altKey && e.key >= '1' && e.key <= '9') {
        const idx = Number(e.key) - 1;
        const target = SECTIONS[idx];
        if (target) {
          e.preventDefault();
          setSearchQuery('');
          navigateSection(target.id);
        }
        return;
      }
      if (mod && e.key === '[') {
        e.preventDefault();
        if (historyIdx > 0) {
          const nextIdx = historyIdx - 1;
          setHistoryIdx(nextIdx);
          const prevSection = historyStack[nextIdx];
          if (prevSection) setSection(prevSection);
        }
        return;
      }
      if (mod && e.key === ']') {
        e.preventDefault();
        if (historyIdx < historyStack.length - 1) {
          const nextIdx = historyIdx + 1;
          setHistoryIdx(nextIdx);
          const nextSection = historyStack[nextIdx];
          if (nextSection) setSection(nextSection);
        }
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [historyIdx, historyStack]);

  const prefs = snapshot?.preferences ?? {};
  const defaults = snapshot?.defaults ?? {};

  const isChanged = (key: string): boolean => {
    if (!(key in defaults)) return false;
    return prefs[key] !== defaults[key];
  };

  const setPref = async (key: string, value: unknown, profileScoped = false, applyAll = false) => {
    const res = await rpc('settings.setPreference', {
      key,
      value,
      profile_id: profileScoped ? selectedProfileId : undefined,
      apply_all_profiles: applyAll,
    });
    setSnapshot((prev) => (prev ? { ...prev, preferences: res.preferences } : prev));
    if (key === 'tabs.archiveAfter' && !applyAll && profiles.length > 1) {
      setArchiveApplyBanner(true);
    }
  };

  const resetPref = async (key: string) => {
    const res = await rpc('settings.resetPreference', { key, profile_id: selectedProfileId });
    setSnapshot((prev) => (prev ? { ...prev, preferences: res.preferences } : prev));
    showToast('Restored shipping default.');
  };

  // Global search results (includes is:changed + shortcuts)
  const searchHits = useMemo(() => {
    const raw = searchQuery.trim().toLowerCase();
    if (!raw) return [];
    const onlyChanged = raw.includes('is:changed');
    const clean = raw.replace(/is:changed/g, '').trim();

    const rowHits = SEARCH_INDEX.filter((item) => {
      if (onlyChanged) {
        if (!item.prefKey || !isChanged(item.prefKey)) return false;
      }
      if (!clean) return true;
      const hay = `${item.label} ${item.help} ${item.section} ${item.aliases ?? ''}`.toLowerCase();
      return hay.includes(clean);
    });

    const scHits: SearchIndexItem[] = shortcuts
      .filter((sc) => {
        if (onlyChanged && sc.keys === sc.default_keys) return false;
        if (!clean) return onlyChanged;
        return `${sc.title} ${sc.keys} ${sc.category} shortcut`.toLowerCase().includes(clean);
      })
      .map((sc) => ({
        id: `shortcuts/${sc.id}`,
        section: 'shortcuts' as const,
        label: `Shortcut: ${sc.title}`,
        help: sc.keys ? `Assigned to ${sc.keys}` : 'Unassigned command',
      }));

    return [...rowHits, ...scHits];
  }, [searchQuery, prefs, defaults, shortcuts]);

  useEffect(() => {
    setSearchIndex(0);
  }, [searchQuery]);

  const currentSectionDef = SECTIONS.find((s) => s.id === section) ?? SECTIONS[0]!;
  const activeProfile = profiles.find((p) => p.id === selectedProfileId) ?? profiles[0];

  const handleOpenImport = async () => {
    setImportModalOpen(true);
    setImportStatus(null);
    const res = await rpc('import.probeBrowsers', {});
    setImportSources(res.sources);
    setSelectedImportId(res.sources[0]?.id ?? '');
  };

  const handleRunImport = async () => {
    if (!selectedImportId) return;
    setImportStatus('Importing…');
    const res = await rpc('import.run', {
      source_id: selectedImportId,
      kinds: ['bookmarks', 'history', 'favorites'],
    });
    setImportStatus(
      `Imported ${res.imported_bookmarks} bookmarks, ${res.imported_history} history entries, and ${res.imported_favorites} Favorites.`,
    );
  };

  // Category counts and the "on" count come from the catalog the browser
  // sent (Track 3's GetCatalog(), 46 lists today), never from constants.
  const adBlockCategoryCounts = useMemo(() => {
    const counts: Partial<Record<AdBlockListCategory, number>> = {};
    for (const item of adBlock?.lists ?? []) counts[item.category] = (counts[item.category] ?? 0) + 1;
    return counts;
  }, [adBlock]);
  const adBlockEnabledCount = useMemo(() => (adBlock?.lists ?? []).filter((l) => l.enabled).length, [adBlock]);

  const filteredAdBlockLists = useMemo(() => {
    if (!adBlock) return [];
    const q = adBlockQuery.trim().toLowerCase();
    return adBlock.lists.filter((item) => {
      if (adBlockCategory !== 'all' && item.category !== adBlockCategory) return false;
      if (q && !item.display_name.toLowerCase().includes(q) && !item.id.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [adBlock, adBlockQuery, adBlockCategory]);

  const filteredShortcuts = useMemo(() => {
    const q = shortcutSearch.trim().toLowerCase();
    return shortcuts.filter((s) => {
      if (shortcutCat !== 'All' && s.category !== shortcutCat) return false;
      if (q && !s.title.toLowerCase().includes(q) && !s.keys.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [shortcuts, shortcutSearch, shortcutCat]);

  const renderSection = (): JSX.Element => {
    switch (section) {
      case 'general':
        return (
          <div class="settings-stack">
            <Card>
              <SettingRow
                id="general/default-browser"
                label="Default browser"
                help={snapshot?.is_default_browser ? 'Open is your default browser.' : 'Make Open your default web browser for links from other apps.'}
                pulsing={pulsingRowId === 'general/default-browser'}
              >
                {snapshot?.is_default_browser ? (
                  <Badge tone="success">Default</Badge>
                ) : (
                  <button
                    type="button"
                    class="open-btn open-btn-primary"
                    onClick={async () => {
                      const res = await rpc('settings.setDefaultBrowser', {});
                      setSnapshot((prev) => (prev ? { ...prev, is_default_browser: res.is_default } : prev));
                      showToast(res.is_default ? 'Open is now your default browser.' : 'Default browser request cancelled.');
                    }}
                  >
                    Make Default
                  </button>
                )}
              </SettingRow>
              <SettingRow
                id="general/automatic-updates"
                label="Automatic updates"
                help="Download and stage Open updates automatically in the background."
                changed={isChanged('general.automaticUpdates')}
                onReset={() => void resetPref('general.automaticUpdates')}
                pulsing={pulsingRowId === 'general/automatic-updates'}
              >
                <Toggle
                  label="Automatic updates"
                  checked={Boolean(prefs['general.automaticUpdates'])}
                  onChange={(v) => void setPref('general.automaticUpdates', v)}
                />
              </SettingRow>
              <SettingRow
                id="general/warn-before-quitting"
                label="Warn before quitting"
                help="Show a confirmation guard when closing Open during active downloads."
                changed={isChanged('general.warnBeforeQuitting')}
                onReset={() => void resetPref('general.warnBeforeQuitting')}
                pulsing={pulsingRowId === 'general/warn-before-quitting'}
              >
                <Toggle
                  label="Warn before quitting"
                  checked={Boolean(prefs['general.warnBeforeQuitting'])}
                  onChange={(v) => void setPref('general.warnBeforeQuitting', v)}
                />
              </SettingRow>
              <SettingRow
                id="general/restore-windows"
                label="Restore windows on launch"
                help="Reopen your previous Spaces, Splits, and tabs when Open starts."
                changed={isChanged('general.restoreWindows')}
                onReset={() => void resetPref('general.restoreWindows')}
                pulsing={pulsingRowId === 'general/restore-windows'}
              >
                <Toggle
                  label="Restore windows on launch"
                  checked={Boolean(prefs['general.restoreWindows'])}
                  onChange={(v) => void setPref('general.restoreWindows', v)}
                />
              </SettingRow>
            </Card>

            <Card title="Data Transfer">
              <SettingRow
                id="general/import"
                label="Import from another browser"
                help="Bring bookmarks, Favorites, history, and extensions from Arc, Chrome, or Firefox."
                pulsing={pulsingRowId === 'general/import'}
              >
                <button type="button" class="open-btn" onClick={() => void handleOpenImport()}>
                  Import…
                </button>
              </SettingRow>
              <SettingRow
                id="general/export"
                label="Export browser snapshot"
                help="Save a portable backup of your Spaces, pinned items, and Archive."
              >
                <button
                  type="button"
                  class="open-btn"
                  onClick={() => showToast('Exported State/browser.json snapshot.')}
                >
                  Export…
                </button>
              </SettingRow>
            </Card>
          </div>
        );

      case 'appearance': {
        const toolbarOn = Boolean(prefs['appearance.toolbar']);
        return (
          <div class="settings-stack">
            <Card title="App Icon">
              <div id="appearance/app-icon" class="app-icon-grid">
                {APP_ICONS.map((icon) => {
                  const active = prefs['appearance.appIcon'] === icon.id;
                  return (
                    <button
                      key={icon.id}
                      type="button"
                      class={`app-icon-tile${active ? ' is-active' : ''}`}
                      onClick={() => void setPref('appearance.appIcon', icon.id)}
                    >
                      <span class="app-icon-swatch" style={{ background: icon.bg }}>
                        O
                      </span>
                      <span>{icon.label}</span>
                    </button>
                  );
                })}
              </div>
            </Card>

            <Card title="Window & Web Pages">
              <SettingRow
                id="appearance/website-appearance"
                label="Website appearance"
                help="Controls prefers-color-scheme reported to websites and internal open:// pages."
                changed={isChanged('appearance.websiteAppearance')}
                onReset={() => void resetPref('appearance.websiteAppearance')}
                pulsing={pulsingRowId === 'appearance/website-appearance'}
              >
                <SegmentedControl<'automatic' | 'light' | 'dark'>
                  ariaLabel="Website appearance"
                  value={(prefs['appearance.websiteAppearance'] as 'automatic' | 'light' | 'dark') || 'automatic'}
                  options={[
                    { value: 'automatic', label: 'Auto' },
                    { value: 'light', label: 'Light' },
                    { value: 'dark', label: 'Dark' },
                  ]}
                  onChange={(v) => void setPref('appearance.websiteAppearance', v)}
                />
              </SettingRow>
              <SettingRow
                id="appearance/toolbar"
                label="Show toolbar in focused window"
                help="Display the top address, navigation, and extension strip."
                changed={isChanged('appearance.toolbar')}
                onReset={() => void resetPref('appearance.toolbar')}
                pulsing={pulsingRowId === 'appearance/toolbar'}
              >
                <Toggle
                  label="Show toolbar"
                  checked={toolbarOn}
                  onChange={(v) => void setPref('appearance.toolbar', v)}
                />
              </SettingRow>
              <SettingRow
                id="appearance/full-url"
                label="Always show full URL"
                help={toolbarOn ? 'Show full scheme, path, and query string in the toolbar.' : 'Turn on Show toolbar to display the full URL.'}
                changed={isChanged('appearance.fullUrl')}
                onReset={() => void resetPref('appearance.fullUrl')}
                disabled={!toolbarOn}
                pulsing={pulsingRowId === 'appearance/full-url'}
              >
                <Toggle
                  label="Always show full URL"
                  checked={Boolean(prefs['appearance.fullUrl'])}
                  disabled={!toolbarOn}
                  onChange={(v) => void setPref('appearance.fullUrl', v)}
                />
              </SettingRow>
            </Card>
          </div>
        );
      }

      case 'tabs-archive':
        return (
          <div class="settings-stack">
            <Card title="Auto-Archive">
              <SettingRow
                id="tabs-archive/archive-after"
                label="Archive Today tabs after"
                help="Inactive Today tabs move to Library › Archived Tabs automatically."
                changed={isChanged('tabs.archiveAfter')}
                onReset={() => void resetPref('tabs.archiveAfter')}
                pulsing={pulsingRowId === 'tabs-archive/archive-after'}
              >
                <select
                  class="open-select"
                  aria-label="Archive Today tabs after"
                  value={String(prefs['tabs.archiveAfter'] ?? '12h')}
                  onChange={(e) => void setPref('tabs.archiveAfter', (e.currentTarget as HTMLSelectElement).value, true)}
                >
                  <option value="1h">1 hour</option>
                  <option value="6h">6 hours</option>
                  <option value="12h">12 hours (Default)</option>
                  <option value="24h">24 hours</option>
                  <option value="7d">7 days</option>
                  <option value="30d">30 days</option>
                  <option value="never">Never</option>
                </select>
              </SettingRow>
              {archiveApplyBanner && (
                <div class="open-setting-row" style={{ background: 'var(--open-accent-soft)' }}>
                  <span style={{ fontSize: '12px' }}>
                    Applied to <strong>{activeProfile?.name}</strong>. Apply this interval to all Profiles?
                  </span>
                  <div style={{ display: 'flex', gap: '8px' }}>
                    <button
                      type="button"
                      class="open-btn open-btn-primary"
                      onClick={async () => {
                        await setPref('tabs.archiveAfter', prefs['tabs.archiveAfter'], true, true);
                        setArchiveApplyBanner(false);
                        showToast('Applied archive interval to all Profiles.');
                      }}
                    >
                      Apply to all Profiles
                    </button>
                    <button type="button" class="open-btn open-btn-ghost" onClick={() => setArchiveApplyBanner(false)}>
                      Dismiss
                    </button>
                  </div>
                </div>
              )}
              <SettingRow
                id="tabs-archive/little-open-archive"
                label="Little Open auto-archive"
                help="Automatically close and archive idle Little Open windows."
                changed={isChanged('tabs.littleOpenArchiveAfter')}
                onReset={() => void resetPref('tabs.littleOpenArchiveAfter')}
                pulsing={pulsingRowId === 'tabs-archive/little-open-archive'}
              >
                <select
                  class="open-select"
                  aria-label="Little Open auto-archive"
                  value={String(prefs['tabs.littleOpenArchiveAfter'] ?? '6h')}
                  onChange={(e) =>
                    void setPref('tabs.littleOpenArchiveAfter', (e.currentTarget as HTMLSelectElement).value, true)
                  }
                >
                  <option value="1h">1 hour</option>
                  <option value="6h">6 hours (Default)</option>
                  <option value="12h">12 hours</option>
                  <option value="24h">24 hours</option>
                  <option value="never">Never</option>
                </select>
              </SettingRow>
            </Card>

            <Card title="Memory & Switching">
              <SettingRow
                id="tabs-archive/sleep"
                label="Sleeping tabs"
                help="Freeze and discard background tabs with instant OPNH state restore."
                changed={isChanged('tabs.sleepMode')}
                onReset={() => void resetPref('tabs.sleepMode')}
                pulsing={pulsingRowId === 'tabs-archive/sleep'}
              >
                <SegmentedControl<'off' | 'conservative' | 'balanced' | 'aggressive'>
                  ariaLabel="Sleeping tabs policy"
                  value={(prefs['tabs.sleepMode'] as 'off' | 'conservative' | 'balanced' | 'aggressive') || 'balanced'}
                  options={[
                    { value: 'off', label: 'Off' },
                    { value: 'conservative', label: '15m' },
                    { value: 'balanced', label: '5m' },
                    { value: 'aggressive', label: '2m' },
                  ]}
                  onChange={(v) => void setPref('tabs.sleepMode', v, true)}
                />
              </SettingRow>
              <SettingRow
                id="tabs-archive/include-favorites"
                label="Include Favorites in Ctrl+Tab switcher"
                help="Include pinned Favorite tiles when cycling recently used tabs."
                changed={isChanged('tabs.includeFavoritesInSwitcher')}
                onReset={() => void resetPref('tabs.includeFavoritesInSwitcher')}
                pulsing={pulsingRowId === 'tabs-archive/include-favorites'}
              >
                <Toggle
                  label="Include Favorites"
                  checked={Boolean(prefs['tabs.includeFavoritesInSwitcher'])}
                  onChange={(v) => void setPref('tabs.includeFavoritesInSwitcher', v)}
                />
              </SettingRow>
              <SettingRow
                id="tabs-archive/ninth-tab"
                label={NINTH_TAB_LABEL}
                help="Jump to the final tab in the current Space rather than tab #9."
                changed={isChanged('tabs.ninthTabGoesToLast')}
                onReset={() => void resetPref('tabs.ninthTabGoesToLast')}
                pulsing={pulsingRowId === 'tabs-archive/ninth-tab'}
              >
                <Toggle
                  label={NINTH_TAB_LABEL}
                  checked={Boolean(prefs['tabs.ninthTabGoesToLast'])}
                  onChange={(v) => void setPref('tabs.ninthTabGoesToLast', v)}
                />
              </SettingRow>
            </Card>
          </div>
        );

      case 'search':
        return (
          <div class="settings-stack">
            <Card>
              <SettingRow
                id="search/engine"
                label="Default search engine"
                help="Used when submitting non-URL queries in the Command Bar."
                changed={isChanged('search.engine')}
                onReset={() => void resetPref('search.engine')}
                pulsing={pulsingRowId === 'search/engine'}
              >
                <select
                  class="open-select"
                  aria-label="Default search engine"
                  value={String(prefs['search.engine'] ?? 'google')}
                  onChange={(e) => void setPref('search.engine', (e.currentTarget as HTMLSelectElement).value, true)}
                >
                  {BUILTIN_SEARCH_ENGINES.map((eng) => (
                    <option key={eng.id} value={eng.id}>
                      {eng.name}
                    </option>
                  ))}
                </select>
              </SettingRow>
              <SettingRow
                id="search/suggestions"
                label="Search suggestions"
                help="Request live autocomplete suggestions from your selected search engine."
                changed={isChanged('search.suggestions')}
                onReset={() => void resetPref('search.suggestions')}
                pulsing={pulsingRowId === 'search/suggestions'}
              >
                <Toggle
                  label="Search suggestions"
                  checked={Boolean(prefs['search.suggestions'])}
                  onChange={(v) => void setPref('search.suggestions', v, true)}
                />
              </SettingRow>
            </Card>

            <Card title="Built-in & Custom Keywords">
              {BUILTIN_SEARCH_ENGINES.map((eng) => (
                <SettingRow key={eng.id} label={eng.name} help={eng.url_template}>
                  <Badge>{eng.keyword}</Badge>
                </SettingRow>
              ))}
            </Card>
          </div>
        );

      case 'links':
        return (
          <div class="settings-stack">
            <Card title="Little Open & Peek">
              <SettingRow
                id="links/little-open-hotkey"
                label="Little Open global hotkey"
                help="Launch a quick Little Open window from any app."
                changed={isChanged('links.littleOpenHotkey')}
                onReset={() => void resetPref('links.littleOpenHotkey')}
                pulsing={pulsingRowId === 'links/little-open-hotkey'}
              >
                <ShortcutRecorder
                  value={String(prefs['links.littleOpenHotkey'] ?? '')}
                  onRecord={(k) => void setPref('links.littleOpenHotkey', k)}
                  onClear={() => void setPref('links.littleOpenHotkey', '')}
                />
              </SettingRow>
              <SettingRow
                id="links/option-command-click"
                label={LITTLE_OPEN_CLICK_LABEL}
                help={LITTLE_OPEN_CLICK_HELP}
                changed={isChanged('links.optionCommandClick')}
                onReset={() => void resetPref('links.optionCommandClick')}
                pulsing={pulsingRowId === 'links/option-command-click'}
              >
                <Toggle
                  label={LITTLE_OPEN_CLICK_LABEL}
                  checked={Boolean(prefs['links.optionCommandClick'])}
                  onChange={(v) => void setPref('links.optionCommandClick', v)}
                />
              </SettingRow>
              <SettingRow
                id="links/peek-shift-click"
                label="Shift-click opens Peek"
                help="Preview a link in an 80% centered overlay with quick expand."
                changed={isChanged('links.peekShiftClick')}
                onReset={() => void resetPref('links.peekShiftClick')}
                pulsing={pulsingRowId === 'links/peek-shift-click'}
              >
                <Toggle
                  label="Shift-click Peek"
                  checked={Boolean(prefs['links.peekShiftClick'])}
                  onChange={(v) => void setPref('links.peekShiftClick', v)}
                />
              </SettingRow>
              <SettingRow
                id="links/peek-other-sites"
                label="Peek external links from Pinned & Favorite tabs"
                help="Keep Pinned apps clean by opening cross-site links in Peek."
                changed={isChanged('links.peekOtherSites')}
                onReset={() => void resetPref('links.peekOtherSites')}
                pulsing={pulsingRowId === 'links/peek-other-sites'}
              >
                <Toggle
                  label="Peek external links"
                  checked={Boolean(prefs['links.peekOtherSites'])}
                  onChange={(v) => void setPref('links.peekOtherSites', v)}
                />
              </SettingRow>
            </Card>

            <Card title="Air Traffic Control">
              <SettingRow
                id="links/destination"
                label="Default external link destination"
                help="Where links from other apps open when no Air Traffic Control rule matches (shipping default: Little Open)."
              >
                <select
                  class="open-select"
                  aria-label="Default external link destination"
                  value={defaultDestination.kind}
                  onChange={async (e) => {
                    const kind = (e.currentTarget as HTMLSelectElement).value as RoutingDestination['kind'];
                    const nextDest: RoutingDestination =
                      kind === 'space' ? { kind, space_id: spaces[0]?.id } : { kind };
                    const res = await rpc('settings.saveRoutingRule', {
                      rule: {
                        id: '',
                        name: '',
                        host_pattern: '',
                        destination: nextDest,
                        enabled: true,
                      },
                      default_destination: nextDest,
                    });
                    setDefaultDestination(res.default_destination);
                  }}
                >
                  <option value="little_open">Little Open (Default)</option>
                  <option value="most_recent_space">Most Recent Space</option>
                  <option value="space">Specific Space</option>
                </select>
              </SettingRow>

              <div id="links/rules" style={{ padding: '12px 14px', borderTop: '1px solid var(--border-subtle)' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '10px' }}>
                  <span style={{ fontWeight: 600, fontSize: '12.5px' }}>Routing Rules ({routingRules.length})</span>
                  <button
                    type="button"
                    class="open-btn open-btn-primary"
                    onClick={() =>
                      setRuleDraft({
                        id: '',
                        name: '',
                        host_pattern: '',
                        path_prefix: '',
                        source_app_id: '',
                        destKind: 'space',
                        destSpaceId: spaces[0]?.id ?? '',
                      })
                    }
                  >
                    <PlusIcon size={13} /> Add Rule
                  </button>
                </div>

                {routingRules.length === 0 ? (
                  <div style={{ color: 'var(--text-secondary)', fontSize: '12px', padding: '8px 0' }}>
                    No custom Air Traffic Control rules yet.
                  </div>
                ) : (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                    {routingRules.map((rule) => {
                      const targetSpace = spaces.find((s) => s.id === rule.destination.space_id);
                      const destLabel =
                        rule.destination.kind === 'little_open'
                          ? 'Little Open'
                          : rule.destination.kind === 'most_recent_space'
                            ? 'Most Recent Space'
                            : `Space: ${targetSpace?.title ?? rule.destination.space_id}`;
                      return (
                        <div
                          key={rule.id}
                          style={{
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'space-between',
                            gap: '10px',
                            padding: '10px 12px',
                            borderRadius: '9px',
                            background: 'var(--bg-input)',
                            border: '1px solid var(--border-subtle)',
                          }}
                        >
                          <div style={{ minWidth: 0 }}>
                            <div style={{ fontWeight: 600, fontSize: '12.5px' }}>{rule.name}</div>
                            <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)' }}>
                              {rule.host_pattern}
                              {rule.path_prefix ? rule.path_prefix : ''} → {destLabel}
                            </div>
                          </div>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                            <Toggle
                              label={`Toggle ${rule.name}`}
                              checked={rule.enabled}
                              onChange={async (enabled) => {
                                const res = await rpc('settings.saveRoutingRule', {
                                  rule: { ...rule, enabled },
                                });
                                setRoutingRules(res.rules);
                              }}
                            />
                            <button
                              type="button"
                              class="open-btn open-btn-ghost"
                              aria-label={`Delete ${rule.name}`}
                              onClick={async () => {
                                const res = await rpc('settings.deleteRoutingRule', { id: rule.id });
                                setRoutingRules(res.rules);
                              }}
                            >
                              <TrashIcon size={13} />
                            </button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}

                {ruleDraft && (
                  <div
                    style={{
                      marginTop: '12px',
                      padding: '12px',
                      borderRadius: '10px',
                      border: '1px solid var(--open-accent)',
                      background: 'var(--bg-canvas)',
                      display: 'flex',
                      flexDirection: 'column',
                      gap: '10px',
                    }}
                  >
                    <div class="form-grid-2">
                      <label class="field-group">
                        <span class="field-label">Rule name</span>
                        <input
                          class="open-input"
                          placeholder="e.g. Work GitHub"
                          value={ruleDraft.name}
                          onInput={(e) => setRuleDraft({ ...ruleDraft, name: (e.currentTarget as HTMLInputElement).value })}
                        />
                      </label>
                      <label class="field-group">
                        <span class="field-label">Host pattern</span>
                        <input
                          class="open-input"
                          placeholder="*.github.com"
                          value={ruleDraft.host_pattern}
                          onInput={(e) =>
                            setRuleDraft({ ...ruleDraft, host_pattern: (e.currentTarget as HTMLInputElement).value })
                          }
                        />
                      </label>
                      <label class="field-group">
                        <span class="field-label">Path prefix (optional)</span>
                        <input
                          class="open-input"
                          placeholder="/org/"
                          value={ruleDraft.path_prefix}
                          onInput={(e) =>
                            setRuleDraft({ ...ruleDraft, path_prefix: (e.currentTarget as HTMLInputElement).value })
                          }
                        />
                      </label>
                      <label class="field-group">
                        <span class="field-label">Destination</span>
                        <select
                          class="open-select"
                          value={ruleDraft.destKind === 'space' ? `space:${ruleDraft.destSpaceId}` : ruleDraft.destKind}
                          onChange={(e) => {
                            const val = (e.currentTarget as HTMLSelectElement).value;
                            if (val.startsWith('space:')) {
                              setRuleDraft({ ...ruleDraft, destKind: 'space', destSpaceId: val.slice(6) });
                            } else {
                              setRuleDraft({ ...ruleDraft, destKind: val as RoutingDestination['kind'] });
                            }
                          }}
                        >
                          {spaces.map((sp) => (
                            <option key={sp.id} value={`space:${sp.id}`}>
                              Space: {sp.title}
                            </option>
                          ))}
                          <option value="little_open">Little Open</option>
                          <option value="most_recent_space">Most Recent Space</option>
                        </select>
                      </label>
                    </div>
                    <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '8px' }}>
                      <button type="button" class="open-btn" onClick={() => setRuleDraft(null)}>
                        Cancel
                      </button>
                      <button
                        type="button"
                        class="open-btn open-btn-primary"
                        onClick={async () => {
                          if (!ruleDraft.host_pattern.trim()) {
                            showToast('Host pattern is required.');
                            return;
                          }
                          const res = await rpc('settings.saveRoutingRule', {
                            rule: {
                              id: ruleDraft.id,
                              name: ruleDraft.name || ruleDraft.host_pattern,
                              host_pattern: ruleDraft.host_pattern,
                              path_prefix: ruleDraft.path_prefix || undefined,
                              source_app_id: ruleDraft.source_app_id || undefined,
                              destination:
                                ruleDraft.destKind === 'space'
                                  ? { kind: 'space', space_id: ruleDraft.destSpaceId }
                                  : { kind: ruleDraft.destKind },
                              enabled: true,
                            },
                          });
                          setRoutingRules(res.rules);
                          setRuleDraft(null);
                          showToast('Saved Air Traffic Control rule.');
                        }}
                      >
                        Save Rule
                      </button>
                    </div>
                  </div>
                )}
              </div>

              <div id="links/test" style={{ padding: '12px 14px', borderTop: '1px solid var(--border-subtle)' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <div>
                    <div style={{ fontWeight: 500, fontSize: '13px' }}>Test a Link</div>
                    <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                      Evaluate a URL against your Air Traffic Control rules before opening it.
                    </div>
                  </div>
                  <button type="button" class="open-btn" onClick={() => setTestLinkOpen((o) => !o)}>
                    {testLinkOpen ? 'Hide Tester' : 'Test a Link'}
                  </button>
                </div>

                {testLinkOpen && (
                  <div style={{ marginTop: '12px', display: 'flex', flexDirection: 'column', gap: '8px' }}>
                    <div style={{ display: 'flex', gap: '8px' }}>
                      <input
                        class="open-input"
                        style={{ flex: 1 }}
                        value={testUrl}
                        placeholder="https://github.com/..."
                        aria-label="Test URL"
                        onInput={(e) => setTestUrl((e.currentTarget as HTMLInputElement).value)}
                      />
                      <input
                        class="open-input"
                        style={{ width: '160px' }}
                        value={testSourceApp}
                        placeholder="Source app (optional)"
                        aria-label="Source application"
                        onInput={(e) => setTestSourceApp((e.currentTarget as HTMLInputElement).value)}
                      />
                      <button
                        type="button"
                        class="open-btn open-btn-primary"
                        onClick={async () => {
                          try {
                            const res = await rpc('settings.testRoutingUrl', {
                              url: testUrl,
                              source_app_id: testSourceApp || undefined,
                            });
                            setTestResult(res);
                          } catch (err) {
                            showToast(err instanceof Error ? err.message : 'Invalid URL');
                          }
                        }}
                      >
                        Evaluate
                      </button>
                    </div>
                    {testResult && (
                      <div
                        style={{
                          padding: '9px 12px',
                          borderRadius: '8px',
                          background: 'var(--open-accent-soft)',
                          color: 'var(--text-primary)',
                          fontSize: '12px',
                        }}
                      >
                        {testResult.explanation}
                      </div>
                    )}
                  </div>
                )}
              </div>
            </Card>
          </div>
        );

      case 'downloads':
        return (
          <Card>
            <SettingRow
              id="downloads/location"
              label="Download location"
              help="Folder where files downloaded in this Profile are saved."
              changed={isChanged('downloads.location')}
              onReset={() => void resetPref('downloads.location')}
              pulsing={pulsingRowId === 'downloads/location'}
            >
              <input
                class="open-input"
                style={{ width: '210px', fontFamily: 'var(--font-mono)' }}
                aria-label="Download location"
                value={String(prefs['downloads.location'] ?? '~/Downloads')}
                onChange={(e) => void setPref('downloads.location', (e.currentTarget as HTMLInputElement).value, true)}
              />
            </SettingRow>
            <SettingRow
              id="downloads/ask"
              label="Ask where to save each file before downloading"
              help="Prompt with a native save dialog for every download."
              changed={isChanged('downloads.askEachTime')}
              onReset={() => void resetPref('downloads.askEachTime')}
              pulsing={pulsingRowId === 'downloads/ask'}
            >
              <Toggle
                label="Ask where to save each file"
                checked={Boolean(prefs['downloads.askEachTime'])}
                onChange={(v) => void setPref('downloads.askEachTime', v, true)}
              />
            </SettingRow>
          </Card>
        );

      case 'previews': {
        const master = Boolean(prefs['previews.enabled']);
        return (
          <Card>
            <SettingRow
              id="previews/enabled"
              label="Enable hover previews"
              help="Master switch for live-data and folder hover cards in the sidebar."
              changed={isChanged('previews.enabled')}
              onReset={() => void resetPref('previews.enabled')}
              pulsing={pulsingRowId === 'previews/enabled'}
            >
              <Toggle
                label="Enable hover previews"
                checked={master}
                onChange={(v) => void setPref('previews.enabled', v)}
              />
            </SettingRow>
            <SettingRow
              id="previews/folders"
              label="Folder previews"
              help={master ? 'Show child tabs when hovering a collapsed folder.' : 'Enable hover previews first.'}
              changed={isChanged('previews.folders')}
              onReset={() => void resetPref('previews.folders')}
              disabled={!master}
              pulsing={pulsingRowId === 'previews/folders'}
            >
              <Toggle
                label="Folder previews"
                checked={Boolean(prefs['previews.folders'])}
                disabled={!master}
                onChange={(v) => void setPref('previews.folders', v)}
              />
            </SettingRow>
            <SettingRow
              id="previews/pages"
              label="Page live-data previews"
              help={master ? 'Preview upcoming calendar meetings and GitHub PR status on hover.' : 'Enable hover previews first.'}
              changed={isChanged('previews.pages')}
              onReset={() => void resetPref('previews.pages')}
              disabled={!master}
              pulsing={pulsingRowId === 'previews/pages'}
            >
              <Toggle
                label="Page previews"
                checked={Boolean(prefs['previews.pages'])}
                disabled={!master}
                onChange={(v) => void setPref('previews.pages', v)}
              />
            </SettingRow>
          </Card>
        );
      }

      case 'ad-blocking':
        return (
          <div class="settings-stack">
            <Card>
              <SettingRow
                id="ad-blocking/enabled"
                label="Built-in ad & tracker blocker"
                help="Blocks network requests, WebSockets, and cosmetic ads using the Rust adblock 0.8.11 engine."
                pulsing={pulsingRowId === 'ad-blocking/enabled'}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                  {adBlock && (
                    <Badge tone={adBlock.global_enabled ? 'success' : 'default'}>
                      <ShieldIcon size={12} /> {adBlock.blocked_count_session} blocked
                    </Badge>
                  )}
                  <Toggle
                    label="Built-in ad blocker"
                    checked={Boolean(adBlock?.global_enabled)}
                    onChange={async (enabled) => {
                      const next = await rpc('settings.setAdBlockEnabled', { enabled });
                      setAdBlock(next);
                    }}
                  />
                </div>
              </SettingRow>
            </Card>

            <Card
              title={`Filter Lists (${adBlock?.lists.length ?? 0} catalog entries · ${adBlockEnabledCount} on · gen #${adBlock?.generation ?? 0})`}
            >
              <div id="ad-blocking/lists" style={{ padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: '10px' }}>
                <SearchInput
                  value={adBlockQuery}
                  onInput={setAdBlockQuery}
                  placeholder={`Filter ${adBlock?.lists.length ?? 0} ad-block lists…`}
                  ariaLabel="Search filter lists"
                />
                <div class="chip-row">
                  {ADBLOCK_CATEGORY_CHIPS.filter(([cat]) => cat === 'all' || (adBlockCategoryCounts[cat] ?? 0) > 0).map(
                    ([cat, label]) => (
                      <button
                        key={cat}
                        type="button"
                        class={`chip-btn${adBlockCategory === cat ? ' is-active' : ''}`}
                        onClick={() => setAdBlockCategory(cat)}
                      >
                        {label} ({cat === 'all' ? (adBlock?.lists.length ?? 0) : (adBlockCategoryCounts[cat] ?? 0)})
                      </button>
                    ),
                  )}
                </div>
                {adBlock?.last_error && (
                  <div style={{ color: 'var(--open-sun)', fontSize: '12px' }}>{adBlock.last_error}</div>
                )}
                {adBlockError && (
                  <div style={{ color: 'var(--open-danger)', fontSize: '12px' }}>{adBlockError}</div>
                )}
              </div>

              <div class="adblock-list-scroll">
                {filteredAdBlockLists.map((list) => (
                  <label key={list.id} class="adblock-list-row" style={{ cursor: list.unavailable_reason ? 'not-allowed' : 'pointer' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '10px', minWidth: 0 }}>
                      <input
                        type="checkbox"
                        checked={list.enabled}
                        disabled={Boolean(list.unavailable_reason)}
                        onChange={async (e) => {
                          setAdBlockError(null);
                          try {
                            const next = await rpc('settings.toggleAdBlockList', {
                              profile_id: selectedProfileId,
                              list_id: list.id,
                              enabled: (e.currentTarget as HTMLInputElement).checked,
                            });
                            setAdBlock(next);
                          } catch (err) {
                            setAdBlockError(err instanceof Error ? err.message : 'Unable to toggle filter list.');
                          }
                        }}
                      />
                      <div style={{ minWidth: 0 }}>
                        <div style={{ fontWeight: 500, fontSize: '12.5px' }}>{list.display_name}</div>
                        <div style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>
                          {list.unavailable_reason ? list.unavailable_reason : `${list.category} · ${list.id}`}
                        </div>
                      </div>
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '6px', flexShrink: 0 }}>
                      {list.bundled && <Badge tone="accent">Bundled</Badge>}
                      {list.unavailable_reason && <Badge tone="sun">Unavailable</Badge>}
                    </div>
                  </label>
                ))}
              </div>
            </Card>

            <Card title="Allowed Sites (Per-Profile Exclusions)">
              <div id="ad-blocking/allowed-sites" style={{ padding: '12px 14px', display: 'flex', gap: '8px' }}>
                <input
                  class="open-input"
                  style={{ flex: 1 }}
                  placeholder="Add hostname (e.g. example.com)"
                  aria-label="Allowed site hostname"
                  value={newExclusionHost}
                  onInput={(e) => setNewExclusionHost((e.currentTarget as HTMLInputElement).value)}
                />
                <button
                  type="button"
                  class="open-btn open-btn-primary"
                  onClick={async () => {
                    setAdBlockError(null);
                    try {
                      const next = await rpc('settings.addAdBlockExclusion', {
                        profile_id: selectedProfileId,
                        host: newExclusionHost,
                      });
                      setAdBlock(next);
                      setNewExclusionHost('');
                    } catch (err) {
                      setAdBlockError(err instanceof Error ? err.message : 'Invalid host.');
                    }
                  }}
                >
                  Allow Site
                </button>
              </div>
              <div class="exclusion-chips">
                {(adBlock?.exclusions ?? []).length === 0 ? (
                  <span style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>No excluded sites for this Profile.</span>
                ) : (
                  adBlock!.exclusions.map((host) => (
                    <span key={host} class="exclusion-chip">
                      {host}
                      <button
                        type="button"
                        aria-label={`Remove ${host}`}
                        onClick={async () => {
                          const next = await rpc('settings.removeAdBlockExclusion', {
                            profile_id: selectedProfileId,
                            host,
                          });
                          setAdBlock(next);
                        }}
                      >
                        <CloseIcon size={11} />
                      </button>
                    </span>
                  ))
                )}
              </div>
            </Card>
          </div>
        );

      case 'site-permissions':
        return (
          <Card>
            <SettingRow
              id="site-permissions/privacy"
              label="Privacy & Site Permissions"
              help="Manage camera, microphone, location, cookies, and JavaScript permissions for this Profile."
            >
              <button
                type="button"
                class="open-btn"
                onClick={() => void rpc('library.openUrl', { url: 'chrome://settings/content', new_tab: true })}
              >
                Open in Tab <ExternalIcon size={12} />
              </button>
            </SettingRow>
            <SettingRow
              id="site-permissions/notifications"
              label="Notifications"
              help="Review origins allowed to send desktop notifications."
            >
              <button
                type="button"
                class="open-btn"
                onClick={() =>
                  void rpc('library.openUrl', { url: 'chrome://settings/content/notifications', new_tab: true })
                }
              >
                Open in Tab <ExternalIcon size={12} />
              </button>
            </SettingRow>
          </Card>
        );

      case 'passwords-cards':
        return (
          <Card>
            <SettingRow
              id="passwords-cards/passwords"
              label="Passwords & Passkeys"
              help="Inspect saved logins, generate passwords, and manage passkeys for this Profile."
            >
              <button
                type="button"
                class="open-btn"
                onClick={() => void rpc('library.openUrl', { url: 'chrome://password-manager/passwords', new_tab: true })}
              >
                Open in Tab <ExternalIcon size={12} />
              </button>
            </SettingRow>
            <SettingRow
              id="passwords-cards/cards"
              label="Credit Cards & Addresses"
              help="Manage payment methods and autofill addresses stored locally."
            >
              <button
                type="button"
                class="open-btn"
                onClick={() => void rpc('library.openUrl', { url: 'chrome://settings/payments', new_tab: true })}
              >
                Open in Tab <ExternalIcon size={12} />
              </button>
            </SettingRow>
          </Card>
        );

      case 'browsing-data':
        return (
          <Card>
            <SettingRow
              id="browsing-data/clear"
              label={`Clear Browsing Data for ${activeProfile?.name ?? 'Profile'}`}
              help="Permanently delete browsing history, cookies, cached images, or download history."
            >
              <button type="button" class="open-btn open-btn-danger" onClick={() => setClearModalOpen(true)}>
                Clear Browsing Data…
              </button>
            </SettingRow>
          </Card>
        );

      case 'account-sync':
        return (
          <div id="account-sync/account" class="settings-stack">
            <Card title="Zero-Knowledge E2EE Sync Server">
              <div style={{ padding: '14px', display: 'flex', flexDirection: 'column', gap: '10px' }}>
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                  <input
                    class="open-input"
                    style={{ flex: 1 }}
                    aria-label="Sync server URL"
                    value={syncServerInput}
                    placeholder="https://sync.example.com"
                    onInput={(e) => setSyncServerInput((e.currentTarget as HTMLInputElement).value)}
                  />
                  <button
                    type="button"
                    class="open-btn"
                    onClick={async () => {
                      const next = await rpc('sync.configureServer', { server_url: syncServerInput });
                      setSyncStatus(next);
                      showToast('Saved Sync Server URL.');
                    }}
                  >
                    Save Server
                  </button>
                  <button
                    type="button"
                    class="open-btn open-btn-ghost"
                    onClick={() => {
                      void navigator.clipboard?.writeText(SELF_HOST_AGENT_PROMPT);
                      showToast('Copied self-hosted SyncServer agent prompt.');
                    }}
                  >
                    Copy Agent Prompt
                  </button>
                </div>
                <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                  All browser data is encrypted locally with AES-256-GCM before upload. Open works offline with no account required.
                </div>
              </div>
            </Card>

            {!syncStatus?.signed_in ? (
              <Card title="Sign In or Create Account">
                <div style={{ padding: '14px', display: 'flex', flexDirection: 'column', gap: '12px' }}>
                  <SegmentedControl<'login' | 'register' | 'recover'>
                    ariaLabel="Sync account action"
                    value={syncTab}
                    options={[
                      { value: 'login', label: 'Sign In' },
                      { value: 'register', label: 'Create Account' },
                      { value: 'recover', label: 'Recover Account' },
                    ]}
                    onChange={setSyncTab}
                  />
                  <div class="form-grid-2">
                    <label class="field-group">
                      <span class="field-label">Email</span>
                      <input
                        class="open-input"
                        type="email"
                        placeholder="you@example.com"
                        value={syncEmail}
                        onInput={(e) => setSyncEmail((e.currentTarget as HTMLInputElement).value)}
                      />
                    </label>
                    <label class="field-group">
                      <span class="field-label">{syncTab === 'recover' ? 'New password' : 'Password'}</span>
                      <input
                        class="open-input"
                        type="password"
                        placeholder="At least 8 characters"
                        value={syncPassword}
                        onInput={(e) => setSyncPassword((e.currentTarget as HTMLInputElement).value)}
                      />
                    </label>
                  </div>
                  {syncTab === 'recover' && (
                    <label class="field-group">
                      <span class="field-label">256-bit Recovery Key</span>
                      <input
                        class="open-input"
                        style={{ fontFamily: 'var(--font-mono)' }}
                        placeholder="OPEN-XXXX-XXXX-..."
                        value={syncRecoveryKey}
                        onInput={(e) => setSyncRecoveryKey((e.currentTarget as HTMLInputElement).value)}
                      />
                    </label>
                  )}
                  <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                    <button
                      type="button"
                      class="open-btn open-btn-primary"
                      onClick={async () => {
                        try {
                          if (syncTab === 'register') {
                            const res = await rpc('sync.register', {
                              email: syncEmail,
                              password: syncPassword,
                              server_url: syncServerInput,
                            });
                            setSyncStatus(res.status);
                            setGeneratedRecoveryKey(res.recovery_key);
                            showToast('Created E2EE Open Account.');
                          } else if (syncTab === 'login') {
                            const res = await rpc('sync.login', {
                              email: syncEmail,
                              password: syncPassword,
                              server_url: syncServerInput,
                            });
                            setSyncStatus(res.status);
                            showToast('Signed in to Open Sync.');
                          } else {
                            const res = await rpc('sync.recover', {
                              email: syncEmail,
                              recovery_key: syncRecoveryKey,
                              new_password: syncPassword,
                              server_url: syncServerInput,
                            });
                            setSyncStatus(res);
                            showToast('Vault Key recovered and signed in.');
                          }
                        } catch (err) {
                          showToast(err instanceof Error ? err.message : 'Sync authentication failed.');
                        }
                      }}
                    >
                      {syncTab === 'register'
                        ? 'Create E2EE Account'
                        : syncTab === 'login'
                          ? 'Sign In'
                          : 'Recover Vault'}
                    </button>
                  </div>
                </div>
              </Card>
            ) : (
              <>
                <Card title="Connected Account">
                  <SettingRow
                    label={syncStatus.email ?? 'Signed in'}
                    help={`Revision #${syncStatus.revision} · Server: ${syncStatus.server_url}${
                      syncStatus.recovery_key_hint ? ` · Key: ${syncStatus.recovery_key_hint}` : ''
                    }`}
                  >
                    <div style={{ display: 'flex', gap: '8px' }}>
                      <button
                        type="button"
                        class="open-btn open-btn-primary"
                        onClick={async () => {
                          const next = await rpc('sync.triggerNow', {});
                          setSyncStatus(next);
                          showToast(`Synced revision #${next.revision}.`);
                        }}
                      >
                        <SyncIcon size={13} /> Sync Now
                      </button>
                      <button
                        type="button"
                        class="open-btn open-btn-danger"
                        onClick={async () => {
                          const next = await rpc('sync.logout', {});
                          setSyncStatus(next);
                          showToast('Signed out of Open Sync.');
                        }}
                      >
                        Sign Out
                      </button>
                    </div>
                  </SettingRow>
                </Card>

                <Card title="Synced Categories">
                  {SYNC_CATEGORIES.map((cat) => (
                    <SettingRow key={cat.id} label={cat.title} help={cat.description}>
                      <Toggle
                        label={cat.title}
                        checked={Boolean(syncStatus.categories[cat.id])}
                        onChange={async (checked) => {
                          const next = await rpc('sync.configureServer', {
                            server_url: syncStatus.server_url,
                            categories: { [cat.id]: checked },
                          });
                          setSyncStatus(next);
                        }}
                      />
                    </SettingRow>
                  ))}
                </Card>

                <Card title={`Connected Devices (${syncStatus.devices.length})`}>
                  {syncStatus.devices.map((dev) => (
                    <SettingRow
                      key={dev.id}
                      label={`${dev.name} (${dev.platform})`}
                      help={dev.is_current ? 'This device' : `Last active ${new Date(dev.last_seen_at * 1000).toLocaleString()}`}
                    >
                      {dev.is_current ? (
                        <Badge tone="accent">Current</Badge>
                      ) : (
                        <button
                          type="button"
                          class="open-btn open-btn-danger"
                          onClick={async () => {
                            const res = await rpc('sync.revokeDevice', { device_id: dev.id });
                            setSyncStatus((prev) => (prev ? { ...prev, devices: res.devices } : prev));
                            showToast(`Revoked ${dev.name}.`);
                          }}
                        >
                          Revoke
                        </button>
                      )}
                    </SettingRow>
                  ))}
                </Card>
              </>
            )}
          </div>
        );

      case 'profiles':
        return (
          <div id="profiles/manage" class="settings-stack">
            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <button type="button" class="open-btn open-btn-primary" onClick={() => setCreateProfileOpen(true)}>
                <PlusIcon size={13} /> New Profile
              </button>
            </div>
            <Card>
              {profiles.map((prof) => (
                <SettingRow
                  key={prof.id}
                  label={`${prof.icon.value} ${prof.name}`}
                  help={`${prof.space_count} Space${prof.space_count === 1 ? '' : 's'} · ${prof.favorites_count} Favorites · Folder: ${prof.data_directory_name}`}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    {prof.is_default && <Badge tone="accent">Default</Badge>}
                    {renamingProfileId === prof.id ? (
                      <>
                        <input
                          class="open-input"
                          style={{ width: '130px' }}
                          value={renameDraft}
                          onInput={(e) => setRenameDraft((e.currentTarget as HTMLInputElement).value)}
                        />
                        <button
                          type="button"
                          class="open-btn open-btn-primary"
                          onClick={async () => {
                            try {
                              const res = await rpc('settings.renameProfile', {
                                profile_id: prof.id,
                                name: renameDraft,
                              });
                              setProfiles((prev) => prev.map((p) => (p.id === prof.id ? res.profile : p)));
                              setRenamingProfileId(null);
                            } catch (err) {
                              showToast(err instanceof Error ? err.message : 'Rename failed.');
                            }
                          }}
                        >
                          Save
                        </button>
                      </>
                    ) : (
                      <button
                        type="button"
                        class="open-btn"
                        onClick={() => {
                          setRenamingProfileId(prof.id);
                          setRenameDraft(prof.name);
                        }}
                      >
                        Rename
                      </button>
                    )}
                    {!prof.is_default && (
                      <button
                        type="button"
                        class="open-btn open-btn-danger"
                        onClick={() => {
                          setDeleteProfileTarget(prof);
                          setDeleteProfileConfirm('');
                        }}
                      >
                        Delete
                      </button>
                    )}
                  </div>
                </SettingRow>
              ))}
            </Card>
          </div>
        );

      case 'shortcuts':
        return (
          <div class="settings-stack">
            <Card>
              <SettingRow
                id="shortcuts/priority"
                label="Shortcut priority"
                help="Choose whether Open commands or active web apps handle shared shortcuts first."
              >
                <SegmentedControl<'open' | 'website'>
                  ariaLabel="Shortcut priority"
                  value={shortcutPriority}
                  options={[
                    { value: 'open', label: 'Open First' },
                    { value: 'website', label: 'Websites First' },
                  ]}
                  onChange={async (v) => {
                    setShortcutPriority(v);
                    await setPref('shortcuts.priority', v);
                  }}
                />
              </SettingRow>
            </Card>

            <Card title="Command Shortcuts">
              <div style={{ padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: '10px', borderBottom: '1px solid var(--border-subtle)' }}>
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                  <div style={{ flex: 1 }}>
                    <SearchInput
                      value={shortcutSearch}
                      onInput={setShortcutSearch}
                      placeholder="Filter commands or keys…"
                      ariaLabel="Filter shortcuts"
                    />
                  </div>
                  <button type="button" class="open-btn" onClick={() => setResetAllShortcutsOpen(true)}>
                    Reset All…
                  </button>
                </div>
                <div class="chip-row">
                  {(['All', 'Tabs', 'Navigation', 'Spaces', 'View', 'Tools', 'Window'] as const).map((cat) => (
                    <button
                      key={cat}
                      type="button"
                      class={`chip-btn${shortcutCat === cat ? ' is-active' : ''}`}
                      onClick={() => setShortcutCat(cat)}
                    >
                      {cat}
                    </button>
                  ))}
                </div>
                {shortcutConflict && (
                  <div style={{ color: 'var(--open-danger)', fontSize: '12px' }}>{shortcutConflict}</div>
                )}
              </div>

              {filteredShortcuts.map((sc) => (
                <SettingRow
                  key={sc.id}
                  id={`shortcuts/${sc.id}`}
                  label={sc.title}
                  help={sc.category}
                  changed={sc.keys !== sc.default_keys}
                  pulsing={pulsingRowId === `shortcuts/${sc.id}`}
                  onReset={async () => {
                    const res = await rpc('settings.resetShortcut', { id: sc.id });
                    setShortcuts(res.shortcuts);
                    setShortcutConflict(null);
                  }}
                >
                  <ShortcutRecorder
                    value={sc.keys}
                    onRecord={async (keys) => {
                      const res = await rpc('settings.setShortcut', { id: sc.id, keys });
                      setShortcuts(res.shortcuts);
                      setShortcutConflict(res.conflict ?? null);
                    }}
                    onClear={async () => {
                      const res = await rpc('settings.setShortcut', { id: sc.id, keys: '' });
                      setShortcuts(res.shortcuts);
                      setShortcutConflict(null);
                    }}
                  />
                </SettingRow>
              ))}
            </Card>
          </div>
        );

      case 'extensions':
        return (
          <Card title={`Installed Extensions (${extensions.length})`}>
            {extensions.map((ext) => (
              <SettingRow
                key={ext.id}
                label={`${ext.name} v${ext.version}`}
                help={`${ext.description} · Permissions: ${ext.permissions.join(', ')}`}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <button
                    type="button"
                    class="open-btn"
                    onClick={async () => {
                      const res = await rpc('settings.toggleExtension', {
                        id: ext.id,
                        enabled: ext.enabled,
                        pinned: !ext.pinned,
                      });
                      setExtensions(res.extensions);
                    }}
                  >
                    {ext.pinned ? 'Unpin' : 'Pin'}
                  </button>
                  <Toggle
                    label={`Enable ${ext.name}`}
                    checked={ext.enabled}
                    onChange={async (enabled) => {
                      const res = await rpc('settings.toggleExtension', { id: ext.id, enabled });
                      setExtensions(res.extensions);
                    }}
                  />
                </div>
              </SettingRow>
            ))}
          </Card>
        );

      case 'advanced':
        return (
          <div class="settings-stack">
            <Card title="Behavior & Features">
              {(
                [
                  ['advanced/sound', 'advanced.soundEffects', 'Sound effects', 'Play subtle audio cues for browser feedback.'],
                  ['advanced/haptics', 'advanced.haptics', 'Haptic feedback', 'Tactile feedback when snapping splits and Space switches.'],
                  ['advanced/window-dragging', 'advanced.windowDragging', 'Window dragging from sidebar', 'Drag anywhere on empty sidebar space to move the window.'],
                  ['advanced/shared-quotes', 'advanced.sharedQuotes', 'Shared Quotes', 'Create highlight links when copying selected text.'],
                  ['advanced/picture-in-picture', 'advanced.pictureInPicture', 'Automatic Picture-in-Picture', 'Float playing videos when leaving the tab.'],
                  ['advanced/theme-data', 'advanced.themeData', 'Adaptive page chrome tint', 'Tint Split pane headers with each page’s theme color.'],
                  ['advanced/boosts', 'advanced.enableBoosts', 'Enable Boosts & Zap', 'Apply custom per-site colors, typography, CSS, JS, and Zaps.'],
                  ['advanced/translate', 'advanced.translateOffer', 'Offer page translation', 'Prompt to translate pages written in other languages.'],
                ] as const
              ).map(([rowId, prefKey, label, help]) => (
                <SettingRow
                  key={rowId}
                  id={rowId}
                  label={label}
                  help={help}
                  changed={isChanged(prefKey)}
                  onReset={() => void resetPref(prefKey)}
                  pulsing={pulsingRowId === rowId}
                >
                  <Toggle
                    label={label}
                    checked={Boolean(prefs[prefKey])}
                    onChange={(v) => void setPref(prefKey, v)}
                  />
                </SettingRow>
              ))}
            </Card>

            <Card title="Diagnostics">
              <SettingRow
                id="advanced/copy-info"
                label="Copy diagnostic info"
                help={`Open ${snapshot?.app_version ?? '1.0.0'} · Chromium ${snapshot?.chromium_version ?? '156.0.8078.48'}`}
              >
                <button
                  type="button"
                  class="open-btn"
                  onClick={() => {
                    const info = `Open ${snapshot?.app_version ?? '1.0.0'} | Chromium ${snapshot?.chromium_version ?? '156.0.8078.48'} | Profiles: ${profiles.length}`;
                    void navigator.clipboard?.writeText(info);
                    showToast('Copied diagnostic info to clipboard.');
                  }}
                >
                  Copy Info
                </button>
              </SettingRow>
            </Card>
          </div>
        );
    }
  };

  return (
    <div class="settings-shell">
      <aside class="settings-sidebar" aria-label="Settings navigation">
        <div class="settings-brand">
          <OpenDoorwayMark size={26} />
          <span class="settings-brand-title">Settings</span>
        </div>

        <SearchInput
          inputRef={searchRef}
          value={searchQuery}
          onInput={setSearchQuery}
          placeholder={`Search (${formatShortcut('Mod+F')} · is:changed)`}
          ariaLabel="Search all settings"
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              setSearchQuery('');
              return;
            }
            if (e.key === 'ArrowDown' && searchHits.length > 0) {
              e.preventDefault();
              setSearchIndex((i) => Math.min(searchHits.length - 1, i + 1));
            } else if (e.key === 'ArrowUp' && searchHits.length > 0) {
              e.preventDefault();
              setSearchIndex((i) => Math.max(0, i - 1));
            } else if (e.key === 'Enter' && searchHits[searchIndex]) {
              e.preventDefault();
              const hit = searchHits[searchIndex]!;
              setSearchQuery('');
              navigateSection(hit.section, hit.id);
            }
          }}
        />

        <nav class="settings-nav">
          {SECTIONS.map((s, idx) => (
            <button
              key={s.id}
              type="button"
              class={`settings-nav-item${!searchQuery && section === s.id ? ' is-active' : ''}`}
              aria-current={!searchQuery && section === s.id ? 'page' : undefined}
              onClick={() => {
                setSearchQuery('');
                navigateSection(s.id);
              }}
            >
              <span>{s.title}</span>
              {idx < 9 && <span class="settings-nav-index">{formatShortcut(`Mod+${idx + 1}`)}</span>}
            </button>
          ))}
        </nav>

        <div class="settings-sidebar-footer">
          <span>Open {snapshot?.app_version ?? '1.0'}</span>
          <button
            type="button"
            class="open-btn open-btn-ghost"
            style={{ height: '24px', padding: '0 6px', fontSize: '11px' }}
            onClick={() => showToast('Open is up to date.')}
          >
            Check
          </button>
        </div>
      </aside>

      <main class="settings-main">
        {searchQuery.trim() ? (
          <div>
            <div class="settings-page-header">
              <div>
                <h1 class="settings-page-title">Search Results</h1>
                <p class="settings-page-subtitle">
                  {searchHits.length} match{searchHits.length === 1 ? '' : 'es'} for “{searchQuery.trim()}”
                </p>
              </div>
              <button type="button" class="open-btn" onClick={() => setSearchQuery('is:changed')}>
                Filter: is:changed
              </button>
            </div>
            {searchHits.length === 0 ? (
              <Card>
                <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                  No settings matched “{searchQuery.trim()}”. Try another keyword or clear <code>is:changed</code>.
                </div>
              </Card>
            ) : (
              <div class="settings-search-results">
                {searchHits.map((hit, idx) => (
                  <button
                    key={hit.id}
                    type="button"
                    class={`settings-search-hit${idx === searchIndex ? ' is-selected' : ''}`}
                    onClick={() => {
                      setSearchQuery('');
                      navigateSection(hit.section, hit.id);
                    }}
                  >
                    <div>
                      <div style={{ fontWeight: 600, fontSize: '13px' }}>{hit.label}</div>
                      <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)' }}>{hit.help}</div>
                    </div>
                    <Badge>{SECTIONS.find((s) => s.id === hit.section)?.title ?? hit.section}</Badge>
                  </button>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            <header class="settings-page-header">
              <div>
                <h1 class="settings-page-title">{currentSectionDef.title}</h1>
                <p class="settings-page-subtitle">{currentSectionDef.subtitle}</p>
              </div>
              {currentSectionDef.profileScoped && profiles.length > 0 && (
                <ProfilePill
                  profiles={profiles}
                  selectedProfileId={selectedProfileId}
                  onChange={setSelectedProfileId}
                />
              )}
            </header>
            {renderSection()}
          </div>
        )}
      </main>

      {/* Modals */}
      <Modal
        open={createProfileOpen}
        title="New Profile"
        onClose={() => setCreateProfileOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setCreateProfileOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              onClick={async () => {
                try {
                  const res = await rpc('settings.createProfile', {
                    name: newProfileName,
                    icon: { kind: 'emoji', value: newProfileEmoji || '✨' },
                  });
                  setProfiles((prev) => [...prev, res.profile]);
                  setCreateProfileOpen(false);
                  setNewProfileName('');
                  showToast(`Created Profile "${res.profile.name}".`);
                } catch (err) {
                  showToast(err instanceof Error ? err.message : 'Unable to create Profile.');
                }
              }}
            >
              Create Profile
            </button>
          </>
        }
      >
        <label class="field-group">
          <span class="field-label">Profile name</span>
          <input
            class="open-input"
            placeholder="e.g. Studio"
            value={newProfileName}
            onInput={(e) => setNewProfileName((e.currentTarget as HTMLInputElement).value)}
          />
        </label>
        <label class="field-group">
          <span class="field-label">Icon emoji</span>
          <input
            class="open-input"
            value={newProfileEmoji}
            onInput={(e) => setNewProfileEmoji((e.currentTarget as HTMLInputElement).value)}
          />
        </label>
      </Modal>

      <Modal
        open={Boolean(deleteProfileTarget)}
        title={`Delete Profile "${deleteProfileTarget?.name ?? ''}"`}
        onClose={() => setDeleteProfileTarget(null)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setDeleteProfileTarget(null)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-danger"
              disabled={!deleteProfileTarget || deleteProfileConfirm.trim() !== deleteProfileTarget.name}
              onClick={async () => {
                if (!deleteProfileTarget) return;
                try {
                  await rpc('settings.deleteProfile', {
                    profile_id: deleteProfileTarget.id,
                    confirm_name: deleteProfileConfirm,
                  });
                  setProfiles((prev) => prev.filter((p) => p.id !== deleteProfileTarget.id));
                  if (selectedProfileId === deleteProfileTarget.id && profiles[0]) {
                    setSelectedProfileId(profiles[0].id);
                  }
                  setDeleteProfileTarget(null);
                  showToast(`Deleted Profile "${deleteProfileTarget.name}".`);
                } catch (err) {
                  showToast(err instanceof Error ? err.message : 'Delete failed.');
                }
              }}
            >
              Delete Profile
            </button>
          </>
        }
      >
        <p style={{ margin: 0, color: 'var(--text-secondary)' }}>
          This permanently removes all cookies, history, Boosts, and Ad Block settings for{' '}
          <strong>{deleteProfileTarget?.name}</strong>. Type its exact name to confirm:
        </p>
        <input
          class="open-input"
          placeholder={deleteProfileTarget?.name}
          value={deleteProfileConfirm}
          onInput={(e) => setDeleteProfileConfirm((e.currentTarget as HTMLInputElement).value)}
        />
      </Modal>

      <Modal
        open={clearModalOpen}
        title="Clear Browsing Data"
        onClose={() => setClearModalOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setClearModalOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-danger"
              onClick={async () => {
                const kinds = Object.entries(clearKinds)
                  .filter(([, on]) => on)
                  .map(([k]) => k);
                const res = await rpc('settings.clearBrowsingData', {
                  profile_id: selectedProfileId,
                  range: clearRange,
                  kinds,
                });
                setClearModalOpen(false);
                showToast(`Cleared ${res.cleared_items} items for ${activeProfile?.name ?? 'Profile'}.`);
              }}
            >
              Clear Data
            </button>
          </>
        }
      >
        <label class="field-group">
          <span class="field-label">Time range</span>
          <select
            class="open-select"
            value={clearRange}
            onChange={(e) => setClearRange((e.currentTarget as HTMLSelectElement).value as typeof clearRange)}
          >
            <option value="hour">Last hour</option>
            <option value="day">Last 24 hours</option>
            <option value="week">Last 7 days</option>
            <option value="month">Last 30 days</option>
            <option value="all">All time</option>
          </select>
        </label>
        {(['history', 'cookies', 'cache', 'downloads'] as const).map((kind) => (
          <label key={kind} style={{ display: 'flex', alignItems: 'center', gap: '8px', textTransform: 'capitalize' }}>
            <input
              type="checkbox"
              checked={Boolean(clearKinds[kind])}
              onChange={(e) =>
                setClearKinds((prev) => ({ ...prev, [kind]: (e.currentTarget as HTMLInputElement).checked }))
              }
            />
            <span>{kind}</span>
          </label>
        ))}
      </Modal>

      <Modal
        open={importModalOpen}
        title="Import from Another Browser"
        onClose={() => setImportModalOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setImportModalOpen(false)}>
              Close
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              disabled={!selectedImportId}
              onClick={() => void handleRunImport()}
            >
              Import Selected
            </button>
          </>
        }
      >
        {importSources.map((src) => (
          <label
            key={src.id}
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '10px 12px',
              borderRadius: '10px',
              border: selectedImportId === src.id ? '1px solid var(--open-accent)' : '1px solid var(--border-subtle)',
              background: 'var(--bg-input)',
              cursor: 'pointer',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
              <input
                type="radio"
                name="import-source"
                checked={selectedImportId === src.id}
                onChange={() => setSelectedImportId(src.id)}
              />
              <div>
                <div style={{ fontWeight: 600 }}>
                  {src.browser_name} ({src.profile_name})
                </div>
                <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                  {src.bookmarks_count} bookmarks · {src.history_count} history · {src.favorites_count} Favorites
                </div>
              </div>
            </div>
          </label>
        ))}
        {importStatus && <Badge tone="success">{importStatus}</Badge>}
      </Modal>

      <Modal
        open={Boolean(generatedRecoveryKey)}
        title="Save Your 256-bit Recovery Key"
        onClose={() => setGeneratedRecoveryKey(null)}
        footer={
          <>
            <button
              type="button"
              class="open-btn"
              onClick={() => {
                if (generatedRecoveryKey) void navigator.clipboard?.writeText(generatedRecoveryKey);
                showToast('Copied recovery key.');
              }}
            >
              Copy Key
            </button>
            <button type="button" class="open-btn open-btn-primary" onClick={() => setGeneratedRecoveryKey(null)}>
              I Saved It
            </button>
          </>
        }
      >
        <p style={{ margin: 0, color: 'var(--text-secondary)' }}>
          Because Open Sync is zero-knowledge, only you can decrypt your vault. Store this recovery key in a safe place:
        </p>
        <code
          style={{
            display: 'block',
            padding: '12px',
            borderRadius: '10px',
            background: 'var(--bg-input)',
            fontFamily: 'var(--font-mono)',
            fontSize: '12.5px',
            wordBreak: 'break-all',
          }}
        >
          {generatedRecoveryKey}
        </code>
      </Modal>

      <Modal
        open={resetAllShortcutsOpen}
        title="Reset All Shortcuts?"
        onClose={() => setResetAllShortcutsOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setResetAllShortcutsOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-danger"
              onClick={async () => {
                const res = await rpc('settings.resetShortcut', { reset_all: true });
                setShortcuts(res.shortcuts);
                setResetAllShortcutsOpen(false);
                showToast('Reset all shortcuts to defaults.');
              }}
            >
              Reset All
            </button>
          </>
        }
      >
        <p style={{ margin: 0, color: 'var(--text-secondary)' }}>
          Restore every custom keyboard shortcut back to its Open default.
        </p>
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
