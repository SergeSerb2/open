import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import {
  type AdBlockState,
  type AtcState,
  type ProfileSummary,
  RPC_EVENTS,
  type SettingsSnapshot,
  type SettingsSpace,
  type SettingsTheme,
  type ShortcutEntry,
  rpc,
  subscribeEvent,
} from '../shared/bridge';
import { SearchIcon, CloseIcon } from '../shared/icons';
import { currentPageRoute, replacePageRoute } from '../shared/route';
import { primaryModifierLabel } from '../shared/shortcuts';
import { type SettingsContext, SettingsCtx, type ToastTone, errorMessage } from './context';
import { AdBlockPane } from './pane-adblock';
import { AboutPane, AdvancedPane } from './pane-advanced';
import { AppearancePane } from './pane-appearance';
import { ExtensionsPane } from './pane-extensions';
import { GeneralPane } from './pane-general';
import { ImportPane } from './pane-import';
import { LinksPane } from './pane-links';
import { PasswordsPane, PrivacyPane } from './pane-privacy';
import { ProfilesPane } from './pane-profiles';
import { ShortcutsPane } from './pane-shortcuts';
import { SpacesPane } from './pane-spaces';
import { SyncPane } from './pane-sync';
import { TabsPane } from './pane-tabs';
import {
  LEGACY_SECTIONS,
  SEARCH_INDEX,
  SECTIONS,
  SECTION_BY_ID,
  type SearchEntry,
  type SectionGroup,
  type SectionId,
  fold,
  isSectionId,
} from './sections';
import { Highlight, rowDomId } from './ui';

const GROUPS: SectionGroup[] = ['BROWSING', 'PRIVACY', 'OPEN'];

// Preferences that only exist for the page (not shown in is:changed).
const HIDDEN_PREFS = new Set(['general.userName']);

function initialRoute(): { section: SectionId; row: string | null } {
  const { segments } = currentPageRoute();
  const [first, ...rest] = segments;
  if (isSectionId(first)) return { section: first, row: rest.length ? `${first}/${rest.join('/')}` : null };
  if (first && LEGACY_SECTIONS[first]) {
    const legacy = LEGACY_SECTIONS[first];
    return { section: legacy.section, row: legacy.row ?? null };
  }
  return { section: 'general', row: null };
}

/** Applies the focused Space's accessible accent to the page. */
function applyTheme(theme: SettingsTheme | null): void {
  const root = document.documentElement;
  if (!theme) return;
  root.style.setProperty('--open-space-accent', theme.accent);
  root.style.setProperty('--open-space-accent-hover', theme.accent_hover);
  root.style.setProperty('--open-space-accent-soft', theme.accent_soft);
  root.style.setProperty('--open-space-on-accent', theme.on_accent);
  root.style.setProperty('--open-space-bg', theme.space_bg);
  root.style.setProperty('--open-theme-mode', theme.mode);
  if (theme.preference === 'light' || theme.preference === 'dark') root.setAttribute('data-theme', theme.preference);
  else root.removeAttribute('data-theme');
}

interface SearchHit {
  entry: SearchEntry;
  changed: boolean;
  reset?: () => Promise<void>;
}

interface Toast {
  id: number;
  message: string;
  tone: ToastTone;
}

export function SettingsApp(): JSX.Element {
  const start = useRef(initialRoute());
  const [section, setSection] = useState<SectionId>(start.current.section);
  const [back, setBack] = useState<SectionId[]>([]);
  const [forward, setForward] = useState<SectionId[]>([]);
  const [pulsingRow, setPulsingRow] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [prefs, setPrefs] = useState<Record<string, unknown>>({});
  const [theme, setTheme] = useState<SettingsTheme | null>(null);
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [spaces, setSpaces] = useState<SettingsSpace[]>([]);
  const [profileId, setProfileIdState] = useState('');
  const [query, setQuery] = useState('');
  const [selection, setSelection] = useState(0);
  const [toast, setToast] = useState<Toast | null>(null);
  const [extras, setExtras] = useState<{ shortcuts: ShortcutEntry[]; atc: AtcState | null; adblock: AdBlockState | null } | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const toastSeq = useRef(0);
  const pendingRow = useRef<string | null>(start.current.row);

  const showToast = useCallback((message: string, tone: ToastTone = 'default') => {
    const id = ++toastSeq.current;
    setToast({ id, message, tone });
    window.setTimeout(() => setToast((cur) => (cur?.id === id ? null : cur)), tone === 'danger' ? 5200 : 3000);
  }, []);

  const run = useCallback(
    async <T,>(task: () => Promise<T>, success?: string | ((value: T) => string | null)): Promise<T | null> => {
      try {
        const value = await task();
        const message = typeof success === 'function' ? success(value) : success;
        if (message) showToast(message, 'success');
        return value;
      } catch (error) {
        showToast(errorMessage(error), 'danger');
        return null;
      }
    },
    [showToast],
  );

  const reloadProfiles = useCallback(async () => {
    const res = await run(() => rpc('settings.profiles.list', {}));
    if (res) setProfiles(res.profiles);
  }, [run]);

  const reloadSpaces = useCallback(async () => {
    const res = await run(() => rpc('settings.spaces.list', {}));
    if (res) setSpaces(res.spaces);
  }, [run]);

  const reloadTheme = useCallback(async () => {
    try {
      const t = await rpc('settings.getTheme', {});
      setTheme(t);
      applyTheme(t);
    } catch {
      // Keep the last theme.
    }
  }, []);

  // Initial load.
  useEffect(() => {
    void (async () => {
      const [all, list, spaceList] = await Promise.all([
        run(() => rpc('settings.getAll', {})),
        run(() => rpc('settings.profiles.list', {})),
        run(() => rpc('settings.spaces.list', {})),
      ]);
      if (all) {
        setSnapshot(all);
        setPrefs(all.preferences);
        if (all.theme) {
          setTheme(all.theme);
          applyTheme(all.theme);
        }
        setProfileIdState(all.active_profile_id || list?.profiles[0]?.id || '');
      }
      if (list) setProfiles(list.profiles);
      if (spaceList) setSpaces(spaceList.spaces);
    })();
  }, [run]);

  // Browser state changes: the focused Space (accent), Profiles and Spaces.
  useEffect(() => {
    let timer = 0;
    const off = subscribeEvent(RPC_EVENTS.stateChanged, () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        void reloadTheme();
        void rpc('settings.profiles.list', {})
          .then((r) => setProfiles(r.profiles))
          .catch(() => undefined);
        void rpc('settings.spaces.list', {})
          .then((r) => setSpaces(r.spaces))
          .catch(() => undefined);
      }, 250);
    });
    const media = window.matchMedia?.('(prefers-color-scheme: dark)');
    const onScheme = () => void reloadTheme();
    media?.addEventListener?.('change', onScheme);
    return () => {
      off();
      window.clearTimeout(timer);
      media?.removeEventListener?.('change', onScheme);
    };
  }, [reloadTheme]);

  const setProfileId = useCallback(
    (id: string) => {
      if (!id || id === profileId) return;
      setProfileIdState(id);
      void run(() => rpc('settings.profiles.switch', { profile_id: id })).then((res) => {
        if (res) setPrefs(res.preferences);
      });
    },
    [profileId, run],
  );

  const defaults = snapshot?.defaults ?? {};

  const isChanged = useCallback(
    (key: string) => {
      if (!(key in defaults) || HIDDEN_PREFS.has(key)) return false;
      return JSON.stringify(prefs[key]) !== JSON.stringify(defaults[key]);
    },
    [prefs, defaults],
  );

  const setPref = useCallback(
    async (key: string, value: unknown, options?: { applyAll?: boolean }) => {
      const res = await run(() =>
        rpc('settings.setPreference', { key, value, profile_id: profileId, ...(options?.applyAll ? { apply_all_profiles: true } : {}) }),
      );
      if (!res) return false;
      setPrefs(res.preferences);
      if (key === 'appearance.websiteAppearance') void reloadTheme();
      if (key.startsWith('search.') || key.startsWith('downloads.') || key.startsWith('tabs.') || key === 'profiles.newDocuments') void reloadProfiles();
      return true;
    },
    [profileId, run, reloadTheme, reloadProfiles],
  );

  const resetPref = useCallback(
    async (key: string) => {
      const res = await run(() => rpc('settings.resetPreference', { key, profile_id: profileId }), 'Back to the default.');
      if (!res) return;
      setPrefs(res.preferences);
      if (key === 'appearance.websiteAppearance') void reloadTheme();
    },
    [profileId, run, reloadTheme],
  );

  const pulse = useCallback((rowId: string) => {
    const domId = rowId.startsWith('row-') ? rowId : rowDomId(rowId);
    let tries = 0;
    const attempt = () => {
      const el = document.getElementById(domId);
      if (!el) {
        if (tries++ < 20) window.setTimeout(attempt, 60);
        return;
      }
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      setPulsingRow(domId);
      // Blocks that are not Rows (lists, test boxes) pulse through the class.
      el.classList.add('is-pulsing');
      window.setTimeout(() => {
        el.classList.remove('is-pulsing');
        setPulsingRow((cur) => (cur === domId ? null : cur));
      }, 1400);
    };
    window.setTimeout(attempt, 30);
  }, []);

  const navigate = useCallback(
    (target: SectionId, row?: string) => {
      setQuery('');
      if (target !== section) {
        setBack((prev) => [...prev, section]);
        setForward([]);
        setSection(target);
        replacePageRoute(target);
        contentRef.current?.scrollTo({ top: 0 });
      }
      if (row) pulse(row);
    },
    [section, pulse],
  );

  // Deep link to a row (open://settings/shortcuts/<id>).
  useEffect(() => {
    if (pendingRow.current && snapshot) {
      const row = pendingRow.current;
      pendingRow.current = null;
      pulse(row);
    }
  }, [snapshot, pulse]);

  const goBack = useCallback(() => {
    const prev = back[back.length - 1];
    if (!prev) return;
    setBack(back.slice(0, -1));
    setForward([section, ...forward]);
    setSection(prev);
    replacePageRoute(prev);
  }, [back, forward, section]);

  const goForward = useCallback(() => {
    const next = forward[0];
    if (!next) return;
    setForward(forward.slice(1));
    setBack([...back, section]);
    setSection(next);
    replacePageRoute(next);
  }, [back, forward, section]);

  // --- Search -----------------------------------------------------------------------
  const folded = fold(query);
  const changedOnly = folded.includes('is:changed');
  const words = folded.replace(/is:changed/g, ' ').split(/\s+/).filter(Boolean);

  useEffect(() => {
    if (!changedOnly) return;
    // Settings without a preference key (shortcuts, rules, lists).
    void Promise.all([
      rpc('settings.shortcuts.list', {}).catch(() => null),
      rpc('settings.atc.get', {}).catch(() => null),
      rpc('settings.adblock.get', { profile_id: profileId }).catch(() => null),
    ]).then(([shortcuts, atc, adblock]) => setExtras({ shortcuts: shortcuts?.shortcuts ?? [], atc, adblock }));
  }, [changedOnly, profileId]);

  const profile = profiles.find((p) => p.id === profileId);

  const hits = useMemo((): SearchHit[] => {
    if (!folded.trim()) return [];
    const special = (entry: SearchEntry): Pick<SearchHit, 'changed' | 'reset'> => {
      if (entry.prefKey) {
        const key = entry.prefKey;
        return { changed: isChanged(key), reset: () => resetPref(key) };
      }
      switch (entry.id) {
        case 'links/destination':
          return {
            changed: !!extras?.atc && extras.atc.default_destination.kind !== 'little_open',
            reset: async () => {
              const res = await run(() => rpc('settings.atc.setDefaultDestination', { destination: { kind: 'little_open' } }), 'Back to the default.');
              if (res && extras) setExtras({ ...extras, atc: res });
            },
          };
        case 'links/rules':
          return { changed: (extras?.atc?.rules.length ?? 0) > 0 };
        case 'adblock/enabled':
          return { changed: !!extras?.adblock && !extras.adblock.global_enabled };
        case 'adblock/lists':
          return {
            changed: !!extras?.adblock && extras.adblock.lists.some((l) => l.enabled !== l.default_enabled),
            reset: async () => {
              const res = await run(() => rpc('settings.adblock.resetLists', { profile_id: profileId }), 'Block lists are back to the defaults.');
              if (res && extras) setExtras({ ...extras, adblock: res });
            },
          };
        case 'adblock/allowed-sites':
          return { changed: (extras?.adblock?.exclusions.length ?? 0) > 0 };
        case 'profiles/custom-engines':
          return { changed: (profile?.settings.custom_search_engines.length ?? 0) > 0 };
        case 'shortcuts/list':
          return { changed: false };
        default:
          return { changed: false };
      }
    };
    const out: SearchHit[] = [];
    for (const entry of SEARCH_INDEX) {
      const state = special(entry);
      if (changedOnly && !state.changed) continue;
      const hay = fold(`${entry.label} ${entry.help ?? ''} ${entry.aliases ?? ''} ${SECTION_BY_ID[entry.section].title}`);
      if (!words.every((w) => hay.includes(w))) continue;
      out.push({ entry, ...state });
    }
    // Every command is searchable; is:changed lists the rebound ones.
    for (const s of extras?.shortcuts ?? []) {
      if (changedOnly && !s.modified) continue;
      if (!changedOnly && !words.length) continue;
      const hay = fold(`${s.title} ${s.category} ${s.aliases.join(' ')} shortcut`);
      if (!words.every((w) => hay.includes(w))) continue;
      out.push({
        entry: { id: `shortcuts/${s.id}`, section: 'shortcuts', label: s.title, help: s.keys ? `Shortcut ${s.keys}` : 'No shortcut' },
        changed: s.modified,
        reset: async () => {
          const res = await run(() => rpc('settings.shortcuts.reset', { id: s.id }), `${s.title} is back to its default.`);
          if (res && extras) setExtras({ ...extras, shortcuts: res.shortcuts });
        },
      });
    }
    return out;
  }, [folded, changedOnly, words.join(' '), isChanged, resetPref, extras, profile, profileId, run]);

  // Shortcut titles are searchable without is:changed too.
  useEffect(() => {
    if (!words.length || extras) return;
    void rpc('settings.shortcuts.list', {})
      .then((res) => setExtras((cur) => cur ?? { shortcuts: res.shortcuts, atc: null, adblock: null }))
      .catch(() => undefined);
  }, [words.length > 0]);

  useEffect(() => setSelection(0), [query]);

  const openHit = (hit: SearchHit | undefined) => {
    if (!hit) return;
    navigate(hit.entry.section, hit.entry.id);
  };

  // --- Keyboard -------------------------------------------------------------------------
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        searchRef.current?.focus();
        searchRef.current?.select();
        return;
      }
      if (mod && e.key === '[') {
        e.preventDefault();
        goBack();
        return;
      }
      if (mod && e.key === ']') {
        e.preventDefault();
        goForward();
        return;
      }
      // Typing while the rail has focus searches (Swift Settings).
      const target = e.target as HTMLElement | null;
      if (!mod && !e.altKey && e.key.length === 1 && target?.closest?.('.st-rail-nav')) {
        e.preventDefault();
        searchRef.current?.focus();
        setQuery((q) => q + e.key);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [goBack, goForward]);

  const ctxValue: SettingsContext = {
    snapshot,
    prefs,
    defaults,
    theme,
    profileId,
    profile,
    profiles,
    spaces,
    setProfileId,
    reloadProfiles,
    reloadSpaces,
    setPref,
    resetPref,
    isChanged,
    applyPreferences: setPrefs,
    toast: showToast,
    navigate,
    pulsingRow,
    run,
  };

  const renderPane = (): JSX.Element => {
    switch (section) {
      case 'general':
        return <GeneralPane />;
      case 'profiles':
        return <ProfilesPane />;
      case 'spaces':
        return <SpacesPane />;
      case 'links':
        return <LinksPane />;
      case 'appearance':
        return <AppearancePane />;
      case 'tabs':
        return <TabsPane />;
      case 'shortcuts':
        return <ShortcutsPane />;
      case 'extensions':
        return <ExtensionsPane />;
      case 'privacy':
        return <PrivacyPane />;
      case 'adblock':
        return <AdBlockPane />;
      case 'passwords':
        return <PasswordsPane />;
      case 'sync':
        return <SyncPane />;
      case 'import':
        return <ImportPane />;
      case 'advanced':
        return <AdvancedPane />;
      case 'about':
        return <AboutPane />;
    }
  };

  const renderSearch = (): JSX.Element => {
    if (!hits.length) {
      return (
        <div class="st-pane">
          <div class="st-search-empty">
            {changedOnly ? (
              <>
                <div class="st-search-empty-title">Nothing changed</div>
                <div class="st-row-help">Every setting here has its default value.</div>
              </>
            ) : (
              <>
                <div class="st-search-empty-title">No results for “{query.trim()}”</div>
                <div class="st-row-help">Try another word, or type is:changed to see the settings you changed.</div>
              </>
            )}
          </div>
        </div>
      );
    }
    let index = -1;
    return (
      <div class="st-pane">
        <h1 class="st-pane-title st-search-title">{changedOnly ? 'Changed settings' : 'Search results'}</h1>
        {SECTIONS.map((def) => {
          const group = hits.filter((h) => h.entry.section === def.id);
          if (!group.length) return null;
          return (
            <section key={def.id} class="st-group">
              <div class="st-group-head">
                <h2 class="st-group-title st-search-section">
                  <def.icon size={13} /> {def.title}
                  {def.perProfile && profile && <span class="st-search-profile">{profile.name}</span>}
                </h2>
              </div>
              <div class="st-card">
                {group.map((hit) => {
                  index += 1;
                  const i = index;
                  return (
                    <div
                      key={hit.entry.id}
                      class={`st-row st-search-hit${i === selection ? ' is-selected' : ''}`}
                      role="option"
                      aria-selected={i === selection}
                      onMouseEnter={() => setSelection(i)}
                      onClick={() => openHit(hit)}
                    >
                      <div class="st-row-meta">
                        <div class="st-row-label">
                          {hit.changed && <span class="st-changed-dot" />}
                          <Highlight text={hit.entry.label} words={words} />
                        </div>
                        {hit.entry.help && (
                          <div class="st-row-help">
                            <Highlight text={hit.entry.help} words={words} />
                          </div>
                        )}
                      </div>
                      {changedOnly && hit.reset && (
                        <div class="st-row-control">
                          <button
                            type="button"
                            class="st-btn st-btn-default is-small"
                            onClick={(e) => {
                              e.stopPropagation();
                              void hit.reset?.();
                            }}
                          >
                            Reset
                          </button>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
    );
  };

  const version = snapshot?.app_version ?? '';

  return (
    <SettingsCtx.Provider value={ctxValue}>
      <div class="st-root">
        <aside class="st-rail" aria-label="Settings sections">
          <div class="st-search">
            <span class="st-search-glyph" aria-hidden="true">
              <SearchIcon size={13} />
            </span>
            <input
              ref={searchRef}
              class="st-search-input"
              value={query}
              placeholder="Search settings"
              aria-label="Search settings"
              onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') {
                  if (query) {
                    e.preventDefault();
                    setQuery('');
                  } else searchRef.current?.blur();
                } else if (e.key === 'ArrowDown') {
                  e.preventDefault();
                  setSelection((s) => Math.min(s + 1, Math.max(0, hits.length - 1)));
                } else if (e.key === 'ArrowUp') {
                  e.preventDefault();
                  setSelection((s) => Math.max(0, s - 1));
                } else if (e.key === 'Enter') {
                  e.preventDefault();
                  openHit(hits[selection]);
                }
              }}
            />
            {query ? (
              <button type="button" class="st-search-clear" aria-label="Clear search" onClick={() => setQuery('')}>
                <CloseIcon size={11} />
              </button>
            ) : (
              <kbd class="st-search-hint">{primaryModifierLabel() === '⌘' ? '⌘F' : 'Ctrl+F'}</kbd>
            )}
          </div>
          <nav class="st-rail-nav">
            {GROUPS.map((group) => (
              <div key={group} class="st-rail-group">
                <div class="st-rail-group-title">{group}</div>
                {SECTIONS.filter((s) => s.group === group).map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    class={`st-nav-item${!query && section === s.id ? ' is-active' : ''}`}
                    aria-current={!query && section === s.id ? 'page' : undefined}
                    onClick={() => navigate(s.id)}
                  >
                    <span class="st-nav-icon">
                      <s.icon size={16} />
                    </span>
                    <span class="st-nav-label">{s.title}</span>
                    {s.id === 'profiles' && profiles.length > 1 && <span class="st-nav-count">{profiles.length}</span>}
                  </button>
                ))}
              </div>
            ))}
          </nav>
          <div class="st-rail-footer">
            <span>Open {version}</span>
            <button
              type="button"
              class="st-link-btn"
              onClick={async () => {
                const res = await run(() => rpc('settings.about.checkForUpdates', {}));
                if (res) showToast(res.message);
              }}
            >
              Check
            </button>
          </div>
        </aside>
        <main class="st-content" ref={contentRef}>
          {query.trim() ? renderSearch() : renderPane()}
        </main>
        {toast && (
          <div class={`st-toast is-${toast.tone}`} role="status" aria-live="polite">
            {toast.message}
          </div>
        )}
      </div>
    </SettingsCtx.Provider>
  );
}
