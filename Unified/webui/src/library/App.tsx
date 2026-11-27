import type { ComponentType, JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { RPC_EVENTS, type ProfileSummary } from '../shared/bridge';
import { currentPageRoute } from '../shared/route';
import { isMacPlatform } from '../shared/shortcuts';
import { call, errorText, LIBRARY_EVENTS, onEvent } from './api';
import { ArchiveSection } from './ArchiveSection';
import { BoostsSection } from './BoostsSection';
import { DocumentsSection } from './DocumentsSection';
import { DownloadsSection } from './DownloadsSection';
import { HistorySection } from './HistorySection';
import {
  ArchiveGlyph,
  BackGlyph,
  BoostsGlyph,
  CheckGlyph,
  CloseGlyph,
  DownloadsGlyph,
  EaselsGlyph,
  FilterGlyph,
  HistoryGlyph,
  MediaGlyph,
  PersonGlyph,
  SearchGlyph,
  SpacesGlyph,
} from './icons';
import { MediaSection } from './MediaSection';
import { SpacesSection } from './SpacesSection';
import { applyTheme, parseTheme } from './theme';
import type { SectionId } from './types';
import {
  ConfirmSheet,
  Menu,
  NavContext,
  modKey,
  overlayOpen,
  popEscape,
  useMenu,
  type ConfirmRequest,
  type NavRow,
  type NavState,
  type SectionProps,
} from './ui';

interface SectionDef {
  id: SectionId;
  tile: string;
  title: string;
  placeholder: string;
  hasFilter: boolean;
  hasSearch: boolean;
  Glyph: ComponentType<{ size?: number; selected?: boolean }>;
  View: ComponentType<SectionProps>;
}

// Presentation order of the rail (Packages/OpenKit/Sources/OpenLibrary/LibrarySection.swift).
const SECTIONS: readonly SectionDef[] = [
  { id: 'media', tile: 'Media', title: 'Media', placeholder: 'Search Media…', hasFilter: false, hasSearch: true, Glyph: MediaGlyph, View: MediaSection },
  { id: 'downloads', tile: 'Downloads', title: 'Downloads', placeholder: 'Search Downloads…', hasFilter: true, hasSearch: true, Glyph: DownloadsGlyph, View: DownloadsSection },
  { id: 'easels', tile: 'Easels', title: 'Easels & Notes', placeholder: 'Search Easels & Notes…', hasFilter: false, hasSearch: true, Glyph: EaselsGlyph, View: DocumentsSection },
  { id: 'spaces', tile: 'Spaces', title: 'Spaces', placeholder: 'Search Spaces…', hasFilter: false, hasSearch: false, Glyph: SpacesGlyph, View: SpacesSection },
  { id: 'boosts', tile: 'Boosts', title: 'Boosts', placeholder: 'Search Boosts…', hasFilter: false, hasSearch: true, Glyph: BoostsGlyph, View: BoostsSection },
  { id: 'archive', tile: 'Archived Tabs', title: 'Archived Tabs', placeholder: 'Search Archive…', hasFilter: true, hasSearch: true, Glyph: ArchiveGlyph, View: ArchiveSection },
  { id: 'history', tile: 'History', title: 'History', placeholder: 'Search History…', hasFilter: true, hasSearch: true, Glyph: HistoryGlyph, View: HistorySection },
];

const SECTION_KEY = 'open.library.section';
const ALIASES: Record<string, SectionId> = { captures: 'media', notes: 'easels', archived: 'archive' };

function initialSection(): SectionId {
  const raw = currentPageRoute().segments[0]?.toLowerCase() ?? '';
  const routed = (ALIASES[raw] ?? raw) as SectionId;
  if (SECTIONS.some((s) => s.id === routed)) return routed;
  try {
    const saved = window.localStorage.getItem(SECTION_KEY) as SectionId | null;
    if (saved && SECTIONS.some((s) => s.id === saved)) return saved;
  } catch {
    // Storage is optional.
  }
  return 'downloads';
}

function isDrawerMode(): boolean {
  const mode = new URLSearchParams(window.location.search).get('mode') ?? currentPageRoute().params.get('mode');
  return mode === 'drawer';
}

function isTextField(el: EventTarget | null): el is HTMLInputElement | HTMLTextAreaElement {
  return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || (el instanceof HTMLElement && el.isContentEditable);
}

export function LibraryApp(): JSX.Element {
  const drawer = useMemo(isDrawerMode, []);
  const nonMac = useMemo(() => !isMacPlatform(), []);
  const [section, setSection] = useState<SectionId>(initialSection);
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [profileId, setProfileId] = useState<string>('all');
  const [queries, setQueries] = useState<Partial<Record<SectionId, string>>>({});
  const [filterOpen, setFilterOpen] = useState(false);
  const [filterActive, setFilterActive] = useState<Partial<Record<SectionId, boolean>>>({});
  const [refreshKey, setRefreshKey] = useState(0);
  const [toastText, setToastText] = useState<string | null>(null);
  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null);
  const [focusKey, setFocusKey] = useState<string | null>(null);
  const [keyboard, setKeyboard] = useState(false);
  const rowsRef = useRef<NavRow[]>([]);
  const searchRef = useRef<HTMLInputElement>(null);
  const railRef = useRef<HTMLElement>(null);
  const toastTimer = useRef(0);
  const { menu, openMenu, closeMenu } = useMenu();

  const def = SECTIONS.find((s) => s.id === section) ?? SECTIONS[1]!;
  const query = queries[section] ?? '';

  const toast = useCallback((message: string) => {
    setToastText(message);
    window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToastText(null), 2600);
  }, []);

  const closeLibrary = useCallback(() => {
    void call('library.close', {}).catch((err) => toast(errorText(err, 'The Library could not be closed.')));
  }, [toast]);

  const choose = (id: SectionId) => {
    if (id === section) return;
    setSection(id);
    setFilterOpen(false);
    setFocusKey(null);
    try {
      window.localStorage.setItem(SECTION_KEY, id);
    } catch {
      // Storage is optional.
    }
    // open://library/<section> keeps the address bar in step (tab mode).
    if (!drawer) {
      const url = new URL(window.location.href);
      url.pathname = `/${id}`;
      window.history.replaceState(null, '', url.toString());
    }
  };

  // Profiles (names for "all" rows and the Profile filter).
  useEffect(() => {
    void call('settings.listProfiles', {})
      .then((res) => setProfiles(res.profiles ?? []))
      .catch(() => setProfiles([]));
  }, [refreshKey]);

  // Space tint: the host's query wins first paint (main.tsx); then the
  // focused Space, then pushes.
  useEffect(() => {
    let live = true;
    const load = () =>
      call('library.theme.get', {})
        .then((res) => live && applyTheme(parseTheme(res.theme)))
        .catch(() => {});
    void load();
    let timer = 0;
    const offState = onEvent(RPC_EVENTS.stateChanged, () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => void load(), 200);
    });
    const offTheme = onEvent(LIBRARY_EVENTS.setSpaceTheme, (payload) => applyTheme(parseTheme(payload)));
    const media = window.matchMedia?.('(prefers-color-scheme: dark)');
    const onScheme = () => void load();
    media?.addEventListener('change', onScheme);
    return () => {
      live = false;
      offState();
      offTheme();
      media?.removeEventListener('change', onScheme);
      window.clearTimeout(timer);
    };
  }, []);

  // Keyboard: Escape layers, ⌘F, arrows, Return, ⌘⌫.
  useEffect(() => {
    const move = (delta: number) => {
      const rows = rowsRef.current;
      if (rows.length === 0) return;
      const at = rows.findIndex((r) => r.key === focusKey);
      const next = at < 0 ? (delta > 0 ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, at + delta));
      const key = rows[next]?.key ?? null;
      setFocusKey(key);
      setKeyboard(true);
      if (key) {
        const el = document.querySelector(`[data-nav-key="${CSS.escape(key)}"]`);
        el?.scrollIntoView({ block: 'nearest' });
      }
    };
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (e.key === 'Escape') {
        e.preventDefault();
        if (popEscape()) return;
        if (filterOpen) {
          setFilterOpen(false);
          return;
        }
        if (query) {
          setQueries((q) => ({ ...q, [section]: '' }));
          return;
        }
        closeLibrary();
        return;
      }
      if (overlayOpen()) return; // Menus and sheets own the keyboard.
      if (mod && e.key.toLowerCase() === 'f' && def.hasSearch) {
        e.preventDefault();
        searchRef.current?.focus();
        searchRef.current?.select();
        return;
      }
      const inRail = railRef.current?.contains(document.activeElement) ?? false;
      if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && inRail) {
        e.preventDefault();
        const i = SECTIONS.findIndex((s) => s.id === section);
        const next = SECTIONS[(i + (e.key === 'ArrowDown' ? 1 : SECTIONS.length - 1)) % SECTIONS.length]!;
        choose(next.id);
        railRef.current?.querySelector<HTMLElement>(`[data-section="${next.id}"]`)?.focus();
        return;
      }
      const typing = isTextField(e.target) && e.target !== searchRef.current;
      if (typing) return;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        move(e.key === 'ArrowDown' ? 1 : -1);
      } else if (e.key === 'Enter' && focusKey) {
        const row = rowsRef.current.find((r) => r.key === focusKey);
        if (row) {
          e.preventDefault();
          row.activate();
        }
      } else if (mod && (e.key === 'Backspace' || e.key === 'Delete') && focusKey && e.target !== searchRef.current) {
        const row = rowsRef.current.find((r) => r.key === focusKey);
        if (row?.remove) {
          e.preventDefault();
          const at = rowsRef.current.indexOf(row);
          row.remove();
          const after = rowsRef.current[at + 1] ?? rowsRef.current[at - 1];
          setFocusKey(after?.key ?? null);
        }
      }
    };
    const onPointer = () => setKeyboard(false);
    window.addEventListener('keydown', onKey);
    window.addEventListener('mousedown', onPointer, true);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('mousedown', onPointer, true);
    };
  }, [focusKey, filterOpen, query, section, def.hasSearch, closeLibrary]);

  // Push events from other windows (Archive, History and Spaces changes).
  useEffect(() => {
    let timer = 0;
    const off = onEvent(RPC_EVENTS.stateChanged, (payload) => {
      const scope = (payload as { scope?: string } | null)?.scope;
      if (scope && scope !== 'archive' && scope !== 'profiles' && scope !== 'documents') return;
      window.clearTimeout(timer);
      timer = window.setTimeout(() => setRefreshKey((k) => k + 1), 400);
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, []);

  const nav: NavState = useMemo(
    () => ({
      focusKey,
      keyboard,
      setFocusKey,
      setRows: (rows: NavRow[]) => {
        rowsRef.current = rows;
      },
    }),
    [focusKey, keyboard],
  );

  const profileNames = useMemo(() => Object.fromEntries(profiles.map((p) => [p.id, p.name])), [profiles]);
  const multiProfile = profiles.length > 1;
  const selectedProfile = profiles.find((p) => p.id === profileId);

  const sectionProps: SectionProps = {
    profileId,
    query: query.trim(),
    profileNames,
    multiProfile,
    drawer,
    refreshKey,
    toast,
    confirm: setConfirmReq,
    closeLibrary,
    filterOpen: filterOpen && def.hasFilter,
    setFilterActive: (active: boolean) => setFilterActive((prev) => (prev[section] === active ? prev : { ...prev, [section]: active })),
  };

  const profileMenu = (e: MouseEvent) =>
    openMenu(e, 'Profile', [
      { label: 'All Profiles', checked: profileId === 'all', icon: <span />, onSelect: () => setProfileId('all') },
      ...profiles.map((p, i) => ({
        label: p.name,
        checked: profileId === p.id,
        separatorBefore: i === 0,
        icon: <span />,
        onSelect: () => setProfileId(p.id),
      })),
    ]);

  const View = def.View;
  return (
    <NavContext.Provider value={nav}>
      <div class={`lib-shell${drawer ? ' is-drawer' : ' is-tab'}${nonMac ? ' is-non-mac' : ''} is-${section}`}>
        <nav ref={railRef} class="lib-rail" aria-label="Library sections">
          <div class="lib-rail-tiles" role="tablist" aria-orientation="vertical">
            {SECTIONS.map((s) => {
              const selected = s.id === section;
              return (
                <button
                  key={s.id}
                  type="button"
                  role="tab"
                  data-section={s.id}
                  aria-selected={selected}
                  tabIndex={selected ? 0 : -1}
                  class={`lib-tile${selected ? ' is-selected' : ''}`}
                  onClick={() => choose(s.id)}
                >
                  <s.Glyph size={28} selected={selected} />
                  <span class="lib-tile-label">{s.tile}</span>
                </button>
              );
            })}
          </div>
          <div class="lib-rail-foot">
            <button type="button" class="lib-back" title={`Close Library (Esc)`} aria-label="Close Library" onClick={closeLibrary}>
              <BackGlyph />
            </button>
            {multiProfile && (
              <button
                type="button"
                class={`lib-profile-pill${profileId !== 'all' ? ' is-filtered' : ''}`}
                title="Show items from"
                aria-label={`Profile: ${selectedProfile?.name ?? 'All Profiles'}`}
                onClick={profileMenu}
              >
                <PersonGlyph size={12} />
                <span>{selectedProfile?.name ?? 'All'}</span>
              </button>
            )}
          </div>
        </nav>

        <main class="lib-pane" aria-label={def.title}>
          {def.hasSearch && (
            <header class="lib-header">
              <label class={`lib-search${def.hasFilter ? ' has-filter' : ''}`}>
                <SearchGlyph />
                <input
                  ref={searchRef}
                  type="search"
                  value={query}
                  placeholder={def.placeholder}
                  aria-label={def.placeholder.replace('…', '')}
                  spellcheck={false}
                  autoComplete="off"
                  onInput={(e) => setQueries((q) => ({ ...q, [section]: (e.currentTarget as HTMLInputElement).value }))}
                />
                {query && (
                  <button type="button" class="lib-search-clear" aria-label="Clear search" onClick={() => setQueries((q) => ({ ...q, [section]: '' }))}>
                    <CloseGlyph size={10} />
                  </button>
                )}
              </label>
              {def.hasFilter && (
                <button
                  type="button"
                  class={`lib-filter-btn${filterOpen ? ' is-open' : ''}`}
                  aria-expanded={filterOpen}
                  onClick={() => setFilterOpen((o) => !o)}
                >
                  <FilterGlyph />
                  <span>Filter</span>
                  {filterActive[section] && <span class="lib-filter-dot" aria-label="Filter on" />}
                </button>
              )}
            </header>
          )}
          {profileId !== 'all' && multiProfile && (
            <div class="lib-profile-note">
              <CheckGlyph size={12} /> {selectedProfile?.name ?? 'Profile'} only
              <button type="button" class="lib-link-btn" onClick={() => setProfileId('all')}>
                Show All
              </button>
            </div>
          )}
          <div class="lib-pane-body" key={section}>
            <View {...sectionProps} />
          </div>
          <div class="lib-hint" aria-hidden="true">
            {def.hasSearch ? `${modKey()}F Search · ` : ''}↑↓ Move · Return Open · {modKey()}⌫ Delete · Esc Close
          </div>
        </main>

        {confirmReq && <ConfirmSheet request={confirmReq} onClose={() => setConfirmReq(null)} />}
        {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
        {toastText && (
          <div class="lib-toast" role="status" aria-live="polite">
            {toastText}
          </div>
        )}
      </div>
    </NavContext.Provider>
  );
}
