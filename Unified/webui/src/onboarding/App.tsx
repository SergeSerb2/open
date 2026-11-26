// open://onboarding — Open's first run, in Open's own identity: the night
// room, the doorway-and-sun, a warm synthesized score. Intro → Import (only
// when another browser is found) → Favorites → Make it yours → Ready.
//
// Nothing is written until Ready: the import choice, Favorites, theme and
// toggles stay in this page and go to onboarding.complete once. The browser
// then turns this tab into open://welcome (or selects an existing Welcome
// tab), so the page never stays on Ready.

import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { type SpaceStyle, isNativeWebUI, subscribeEvent } from '../shared/bridge';
import { computeSpaceGradientCss, hexToRgba, isLightSpaceStyle, rgbaToHex } from '../shared/components';
import { DoorwayArch, DoorwayEmblem, Landscape, MiniBrowser, type MiniFavorite, Room, SiteIcon } from './art';
import {
  DEFAULT_IMPORT_KINDS,
  FAVORITE_SITES,
  type FavoriteSite,
  IMPORT_KIND_LABELS,
  MAX_FAVORITES,
  THEME_SWATCHES,
  favoriteKey,
  normalizeTypedUrl,
  siteNameFromUrl,
} from './catalog';
import {
  type FaviconResult,
  type ImportKind,
  type ImportSource,
  type OnboardingState,
  completeOnboarding,
  getOnboardingState,
  prefetchFavicons,
  probeImportSources,
} from './rpc';
import { isMuted, playHandoff, playIntroScore, playTick, setMuted } from './sound';

type Step = 'intro' | 'import' | 'favorites' | 'theme' | 'ready';

// Intro beats (seconds), after docs/onboarding.md's IntroTimeline, with the
// button brought forward to the end of the identity line.
const BEAT = {
  line: 4.3,
  value1: 5.6,
  value2: 6.8,
  value3: 8.0,
  settle: 9.2,
  button: 5.0,
} as const;

const IDENTITY_LINE = 'A browser that’s yours, and only yours.';
const VALUE_LINES = [
  'Spaces keep work, home and everything else apart.',
  'Ad blocking, Boosts and Split View are built in.',
  'Private by default. Sync is yours to turn on.',
];

const READY_PATTERNS = [
  'radial-gradient(circle at 82% 18%, rgba(255,255,255,0.32), transparent 46%)',
  'radial-gradient(circle at 18% 86%, rgba(255,236,170,0.34), transparent 52%)',
  'repeating-linear-gradient(135deg, rgba(255,255,255,0.07) 0 12px, transparent 12px 26px)',
  'radial-gradient(circle at 50% -10%, rgba(255,255,255,0.3), transparent 58%)',
  'conic-gradient(from 210deg at 78% 78%, rgba(255,255,255,0.18), transparent 38%)',
  'linear-gradient(115deg, rgba(255,255,255,0.2), transparent 55%)',
];

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;
}

function sourceTitle(source: ImportSource): string {
  if (source.family === 'open-legacy') return 'Import from Open (Legacy)';
  return `Import from ${source.browser_name}`;
}

function sourceSubtitle(source: ImportSource): string {
  const parts: string[] = [];
  if (source.profile_name && source.profile_name !== source.browser_name && source.family !== 'open-legacy') {
    parts.push(source.profile_name);
  }
  if (source.access_denied) return parts.join(' · ');
  const items = source.family === 'arc' || source.family === 'open-legacy' ? 'tabs' : 'bookmarks';
  if (source.bookmarks_count) parts.push(`${source.bookmarks_count.toLocaleString()} ${items}`);
  if (source.history_count) parts.push(`${source.history_count.toLocaleString()} history`);
  return parts.join(' · ');
}

const FAMILY_TINT: Record<ImportSource['family'], string> = {
  'open-legacy': 'linear-gradient(160deg, #FFD08A, #F08A4B)',
  arc: 'linear-gradient(160deg, #6b5cff, #d35b8f)',
  safari: 'linear-gradient(160deg, #4aa8ff, #2a6fdb)',
  chromium: 'linear-gradient(160deg, #6aa5ff, #3f6fe0)',
  firefox: 'linear-gradient(160deg, #ffb040, #e0505d)',
  html: 'linear-gradient(160deg, #8f96a8, #5b6478)',
};

function SourceBadge({ source }: { source: ImportSource }): JSX.Element {
  if (source.family === 'open-legacy') {
    return (
      <span class="onb-source-badge is-open" aria-hidden="true">
        <DoorwayEmblem size={22} />
      </span>
    );
  }
  return (
    <span class="onb-source-badge" style={{ background: FAMILY_TINT[source.family] }} aria-hidden="true">
      {source.browser_name.charAt(0).toUpperCase()}
    </span>
  );
}

interface FavoriteTile extends FavoriteSite {
  custom?: boolean;
}

export function OnboardingApp(): JSX.Element {
  const reduceMotion = useMemo(prefersReducedMotion, []);
  const [step, setStep] = useState<Step>('intro');
  const [state, setState] = useState<OnboardingState | null>(null);
  const [sources, setSources] = useState<ImportSource[] | null>(null);
  const [probing, setProbing] = useState(false);
  const [sourceId, setSourceId] = useState<string>('');
  const [kinds, setKinds] = useState<Set<ImportKind>>(() => new Set(DEFAULT_IMPORT_KINDS));
  const [tiles, setTiles] = useState<FavoriteTile[]>(() => [...FAVORITE_SITES]);
  const [selected, setSelected] = useState<Set<string>>(
    () => new Set(FAVORITE_SITES.filter((f) => f.selected).map((f) => f.url)),
  );
  const [icons, setIcons] = useState<Record<string, FaviconResult>>({});
  const [customUrl, setCustomUrl] = useState('');
  const [customError, setCustomError] = useState<string | null>(null);
  const [style, setStyle] = useState<SpaceStyle>({
    math_version: 1,
    key_color: { r: 0.19, g: 0.22, b: 1, a: 1 },
    color_count: 2,
    wheel: 'analogous',
    appearance: 'automatic',
    noise_factor: 0.16,
    texture: 'grain',
    intensity_factor: 0.65,
  });
  const [adblock, setAdblock] = useState(true);
  const [makeDefault, setMakeDefault] = useState(true);
  const [userName, setUserName] = useState('');
  const [applyAgain, setApplyAgain] = useState(false);
  const [pattern, setPattern] = useState(0);
  const [finishing, setFinishing] = useState(false);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<{ message: string; importFailed: boolean } | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [muted, setMutedState] = useState(isMuted);

  // Intro timeline.
  const introStart = useRef(performance.now());
  const [introSkipped, setIntroSkipped] = useState(reduceMotion);
  const [lineIndex, setLineIndex] = useState(-1); // -1 hidden, 0 identity, 1..3 values
  const [buttonReady, setButtonReady] = useState(false);

  const replay = state?.completed === true;

  // --- Load ---------------------------------------------------------------------

  const probe = useCallback(async () => {
    setProbing(true);
    try {
      const list = await probeImportSources();
      setSources(list);
      setSourceId((current) => {
        if (current && list.some((s) => s.id === current && !s.access_denied)) return current;
        const first = list.find((s) => s.recommended && !s.access_denied);
        return first ? first.id : '';
      });
    } catch {
      setSources([]);
    } finally {
      setProbing(false);
    }
  }, []);

  useEffect(() => {
    void getOnboardingState()
      .then((st) => {
        setState(st);
        setStyle(st.default_space_style);
        setAdblock(st.adblock_enabled);
        setMakeDefault(!st.is_default_browser);
        if (st.user_name) setUserName(st.user_name);
      })
      .catch(() => undefined);
    void probe();
    const off = subscribeEvent('open.importProgress', (payload) => {
      const p = (payload ?? {}) as { phase?: string; progress?: number };
      if (p.phase === 'reading') setProgress('Reading your data…');
      else if (p.phase === 'applying') setProgress('Adding it to Open…');
      else if (p.phase === 'done') setProgress('Imported.');
    });
    return off;
  }, [probe]);

  // Favicons: fetched after the intro starts (sellIntro + syncLead).
  useEffect(() => {
    const timer = window.setTimeout(() => {
      void prefetchFavicons(FAVORITE_SITES.map((f) => f.url)).then((results) => {
        setIcons((prev) => {
          const next = { ...prev };
          for (const r of results) next[r.page_url] = r;
          return next;
        });
      });
    }, 3380);
    return () => window.clearTimeout(timer);
  }, []);

  // --- Intro schedule ---------------------------------------------------------------

  useEffect(() => {
    if (step !== 'intro') return;
    if (introSkipped) {
      setLineIndex(0);
      setButtonReady(true);
      return;
    }
    const elapsed = (performance.now() - introStart.current) / 1000;
    const at = (beat: number, fn: () => void) => window.setTimeout(fn, Math.max(0, (beat - elapsed) * 1000));
    const timers = [
      at(BEAT.line, () => setLineIndex(0)),
      at(BEAT.button, () => setButtonReady(true)),
      at(BEAT.value1, () => setLineIndex(1)),
      at(BEAT.value2, () => setLineIndex(2)),
      at(BEAT.value3, () => setLineIndex(3)),
      at(BEAT.settle, () => setLineIndex(0)),
    ];
    return () => timers.forEach((t) => window.clearTimeout(t));
  }, [step, introSkipped]);

  // The score starts with the first gesture (browsers block earlier audio).
  useEffect(() => {
    const start = () => {
      playIntroScore((performance.now() - introStart.current) / 1000);
      window.removeEventListener('pointerdown', start, true);
      window.removeEventListener('keydown', start, true);
    };
    window.addEventListener('pointerdown', start, true);
    window.addEventListener('keydown', start, true);
    return () => {
      window.removeEventListener('pointerdown', start, true);
      window.removeEventListener('keydown', start, true);
    };
  }, []);

  // --- Steps ------------------------------------------------------------------------

  const steps = useMemo<Step[]>(() => {
    const list: Step[] = ['intro'];
    // Import only when another browser has data (or while still looking).
    if (sources === null || sources.length > 0) list.push('import');
    list.push('favorites', 'theme', 'ready');
    return list;
  }, [sources]);

  useEffect(() => {
    if (!steps.includes(step)) setStep('favorites');
  }, [steps, step]);

  const setupSteps = steps.filter((s) => s !== 'intro');
  const stepIndex = steps.indexOf(step);

  const goNext = () => {
    const next = steps[stepIndex + 1];
    if (next) setStep(next);
  };
  const goBack = () => {
    const prev = steps[stepIndex - 1];
    if (prev) setStep(prev);
  };

  const selectedSource = sources?.find((s) => s.id === sourceId && !s.access_denied) ?? null;
  // Sidebar kinds stay idempotent; offer them again even after a run.
  const importKindsForRun = selectedSource
    ? selectedSource.supported_kinds.filter((k) => kinds.has(k))
    : [];

  const existingKeys = useMemo(
    () => new Set((state?.existing_favorite_urls ?? []).map(favoriteKey)),
    [state],
  );

  const selectedTiles = tiles.filter((t) => selected.has(t.url) && !existingKeys.has(favoriteKey(t.url)));
  const miniFavorites: MiniFavorite[] = [
    ...(state?.existing_favorite_urls ?? []).map((url) => ({
      id: `existing-${url}`,
      name: siteNameFromUrl(url),
      monogram: siteNameFromUrl(url).slice(0, 2),
      icon: icons[url]?.icon,
    })),
    ...selectedTiles.map((t) => ({
      id: t.id,
      name: t.name,
      monogram: t.monogram,
      icon: icons[t.url]?.icon,
      color: icons[t.url]?.fallback_color ?? t.color,
    })),
  ];

  const toggleFavorite = (tile: FavoriteTile) => {
    if (existingKeys.has(favoriteKey(tile.url))) return;
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(tile.url)) next.delete(tile.url);
      else if (selectedTiles.length < MAX_FAVORITES) next.add(tile.url);
      return next;
    });
    playTick();
  };

  const addCustom = () => {
    const url = normalizeTypedUrl(customUrl);
    if (!url) {
      setCustomError('Type a site address, like example.com.');
      return;
    }
    const key = favoriteKey(url);
    const existing = tiles.find((t) => favoriteKey(t.url) === key);
    if (existing) {
      setSelected((prev) => new Set(prev).add(existing.url));
    } else {
      const name = siteNameFromUrl(url);
      const tile: FavoriteTile = {
        id: `custom-${key}`,
        name,
        url,
        monogram: name.slice(0, 2),
        custom: true,
      };
      setTiles((prev) => [...prev, tile]);
      setSelected((prev) => new Set(prev).add(url));
      // Local icon only (custom sites never go to a favicon server).
      void prefetchFavicons([url]).then((results) =>
        setIcons((prev) => {
          const next = { ...prev };
          for (const r of results) next[r.page_url] = r;
          return next;
        }),
      );
    }
    setCustomUrl('');
    setCustomError(null);
  };

  const spaceTitle = state?.space_title || (userName.trim() ? `${userName.trim()}’s Space` : 'Your Space');
  const gradient = computeSpaceGradientCss(style);
  const lightArt = isLightSpaceStyle(style);
  const roomTint = rgbaToHex(style.key_color);

  // --- Finish -----------------------------------------------------------------------

  const finish = async (skipImport = false) => {
    if (finishing) return;
    setFinishing(true);
    setError(null);
    const runImport = !skipImport && !replay && selectedSource && importKindsForRun.length > 0;
    setProgress(runImport ? 'Importing…' : null);
    try {
      const result = await completeOnboarding({
        user_name: userName.trim().slice(0, 40),
        favorite_urls: selectedTiles.map((t) => t.url),
        space_style: style,
        adblock_enabled: adblock,
        make_default_browser: makeDefault && !state?.is_default_browser,
        replay: replay && !applyAgain,
        ...(runImport && selectedSource ? { import: { source_id: selectedSource.id, kinds: importKindsForRun } } : {}),
      });
      playHandoff();
      setLeaving(true);
      const target = isNativeWebUI()
        ? result.welcome_url
        : `/welcome.html${window.location.search}`;
      // The browser turns this tab into Welcome (navigated) or closes it
      // (selected_existing). If that does not happen, go there ourselves.
      const wait =
        isNativeWebUI() && (result.handoff === 'navigated' || result.handoff === 'selected_existing') ? 1600 : 650;
      window.setTimeout(() => window.location.replace(target), wait);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Setup could not be saved.';
      setError({ message, importFailed: /^Import failed/i.test(message) });
      setFinishing(false);
      setProgress(null);
    }
  };

  // --- Keyboard ---------------------------------------------------------------------

  const primary = (): void => {
    if (step === 'intro') {
      if (buttonReady) goNext();
      return;
    }
    if (step === 'ready') void finish();
    else goNext();
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      const typing = target?.tagName === 'INPUT' || target?.tagName === 'TEXTAREA';
      if (e.key === 'Escape') {
        if (step === 'intro') setIntroSkipped(true);
        else if (!finishing) goBack();
        e.preventDefault();
        return;
      }
      if (e.key === 'Enter' && !typing && target?.tagName !== 'BUTTON' && target?.tagName !== 'LABEL') {
        e.preventDefault();
        primary();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  // --- Render: intro ------------------------------------------------------------------

  const muteButton = (
    <button
      type="button"
      class="onb-mute"
      aria-pressed={muted}
      aria-label={muted ? 'Turn sound on' : 'Turn sound off'}
      title={muted ? 'Sound off' : 'Sound on'}
      onClick={(e) => {
        e.stopPropagation();
        setMuted(!muted);
        setMutedState(!muted);
      }}
    >
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M2.5 6h2.2L8 3.2v9.6L4.7 10H2.5z" fill="currentColor" />
        {muted ? (
          <path d="M10.5 6l3 4M13.5 6l-3 4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
        ) : (
          <path
            d="M10.4 5.6a3.4 3.4 0 010 4.8M12.2 3.9a5.8 5.8 0 010 8.2"
            fill="none"
            stroke="currentColor"
            stroke-width="1.3"
            stroke-linecap="round"
          />
        )}
      </svg>
    </button>
  );

  if (step === 'intro') {
    const line = lineIndex <= 0 ? IDENTITY_LINE : (VALUE_LINES[lineIndex - 1] ?? IDENTITY_LINE);
    return (
      <Room tint={roomTint} class={`onb-intro${introSkipped ? ' is-skipped' : ''}${reduceMotion ? ' is-reduced' : ''}`}>
        <div class="onb-titlebar" />
        {muteButton}
        <div
          class="onb-intro-stage"
          onClick={() => setIntroSkipped(true)}
          role="presentation"
        >
          <div class="onb-intro-spill" aria-hidden="true" />
          <div class="onb-intro-door">
            <DoorwayArch height={196} />
          </div>
          <h1 class="onb-wordmark">Open</h1>
          <p class="onb-intro-line" aria-live="polite">
            <span key={lineIndex} class={lineIndex >= 0 ? 'is-shown' : ''}>
              {line}
            </span>
          </p>
        </div>
        <div class="onb-intro-cta">
          <button
            type="button"
            class={`onb-continue${buttonReady ? ' is-ready' : ''}`}
            disabled={!buttonReady}
            onClick={goNext}
          >
            {replay ? 'Look around' : 'Get Started'}
          </button>
          {replay && buttonReady && (
            <p class="onb-replay-note">You’ve set up Open before. Nothing changes unless you choose to.</p>
          )}
        </div>
      </Room>
    );
  }

  // --- Render: setup steps --------------------------------------------------------------

  const todayRows: { title: string; active?: boolean; highlight?: boolean }[] = [
    { title: 'Welcome to Open', active: true },
  ];
  if (step === 'import' && selectedSource) {
    todayRows.push({ title: `Imported from ${selectedSource.family === 'open-legacy' ? 'Open' : selectedSource.browser_name}`, highlight: true });
  } else {
    todayRows.push({ title: 'Morning reading' }, { title: 'Trip planning' });
  }

  const formByStep: Record<Exclude<Step, 'intro'>, JSX.Element> = {
    import: (
      <>
        <h1 class="onb-heading">Bring your browser with you.</h1>
        <p class="onb-desc">
          Choose where to start from. Open makes a copy and never changes the original. It imports when you
          finish setup.
        </p>
        <div class="onb-controls onb-sources" role="radiogroup" aria-label="Import source">
          {sources === null && <div class="onb-source-skeleton">Looking for other browsers…</div>}
          {sources?.map((source) => {
            const isSelected = source.id === sourceId;
            return (
              <div
                key={source.id}
                class={`onb-source${isSelected ? ' is-selected' : ''}${source.access_denied ? ' is-blocked' : ''}${
                  source.recommended ? ' is-recommended' : ''
                }`}
              >
                <button
                  type="button"
                  role="radio"
                  aria-checked={isSelected}
                  class="onb-source-head"
                  onClick={() => setSourceId(source.id)}
                >
                  <SourceBadge source={source} />
                  <span class="onb-source-text">
                    <span class="onb-source-title">{sourceTitle(source)}</span>
                    <span class="onb-source-sub">
                      {source.access_denied
                        ? 'Needs Full Disk Access'
                        : sourceSubtitle(source) || 'Ready to import'}
                    </span>
                    {(source.recommended || source.imported_kinds.length > 0) && (
                      <span class="onb-source-tags">
                        {source.recommended && <span class="onb-tag is-warm">Recommended · Safe read-only copy</span>}
                        {source.imported_kinds.length > 0 && <span class="onb-tag">Imported before</span>}
                      </span>
                    )}
                  </span>
                  <span class="onb-radio" aria-hidden="true" />
                </button>
                {isSelected && source.access_denied && (
                  <div class="onb-source-body">
                    <p class="onb-source-help">
                      Open needs Full Disk Access to read {source.browser_name}. Open System Settings › Privacy &amp;
                      Security › Full Disk Access, turn on Open, then check again.
                    </p>
                    <button type="button" class="onb-btn onb-btn-secondary" disabled={probing} onClick={() => void probe()}>
                      {probing ? 'Checking…' : 'Check Again'}
                    </button>
                  </div>
                )}
                {isSelected && !source.access_denied && (
                  <div class="onb-source-body">
                    <div class="onb-kinds">
                      {source.supported_kinds.map((kind) => {
                        const done = source.imported_kinds.includes(kind);
                        const on = kinds.has(kind) && !done;
                        return (
                          <label key={kind} class={`onb-kind${on ? ' is-on' : ''}${done ? ' is-done' : ''}`}>
                            <input
                              type="checkbox"
                              checked={on || done}
                              disabled={done}
                              onChange={() =>
                                setKinds((prev) => {
                                  const next = new Set(prev);
                                  if (next.has(kind)) next.delete(kind);
                                  else next.add(kind);
                                  return next;
                                })
                              }
                            />
                            <span class="onb-kind-label">{IMPORT_KIND_LABELS[kind].label}</span>
                            <span class="onb-kind-hint">
                              {done ? 'Already imported' : IMPORT_KIND_LABELS[kind].hint}
                            </span>
                          </label>
                        );
                      })}
                    </div>
                  </div>
                )}
              </div>
            );
          })}
          <div class={`onb-source is-fresh${sourceId === '' ? ' is-selected' : ''}`}>
            <button
              type="button"
              role="radio"
              aria-checked={sourceId === ''}
              class="onb-source-head"
              onClick={() => setSourceId('')}
            >
              <span class="onb-source-badge is-fresh" aria-hidden="true">
                +
              </span>
              <span class="onb-source-text">
                <span class="onb-source-title">Start fresh</span>
                <span class="onb-source-sub">An empty Space, ready for anything</span>
              </span>
              <span class="onb-radio" aria-hidden="true" />
            </button>
          </div>
        </div>
      </>
    ),
    favorites: (
      <>
        <h1 class="onb-heading">Choose the sites you use most.</h1>
        <p class="onb-desc">They become Favorites at the top of your sidebar, one click away.</p>
        <div class="onb-controls">
          <div class="onb-fav-grid" role="group" aria-label="Suggested Favorites">
            {tiles.map((tile, i) => {
              const already = existingKeys.has(favoriteKey(tile.url));
              const isOn = already || selected.has(tile.url);
              const icon = icons[tile.url];
              return (
                <button
                  key={tile.id}
                  type="button"
                  class={`onb-fav${isOn ? ' is-selected' : ''}${already ? ' is-existing' : ''}`}
                  aria-pressed={isOn}
                  aria-label={already ? `${tile.name}, already a Favorite` : tile.name}
                  style={{ '--i': i }}
                  onClick={() => toggleFavorite(tile)}
                >
                  {isOn && (
                    <span class="onb-fav-check" aria-hidden="true">
                      <svg width="10" height="10" viewBox="0 0 10 10">
                        <path d="M2 5.2l2 2L8 3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
                      </svg>
                    </span>
                  )}
                  <SiteIcon
                    class="onb-fav-icon"
                    name={tile.name}
                    monogram={tile.monogram}
                    icon={icon?.icon}
                    color={icon?.fallback_color ?? tile.color}
                    size={32}
                  />
                  <span class="onb-fav-label">{tile.name}</span>
                </button>
              );
            })}
          </div>
          <form
            class="onb-add-site"
            onSubmit={(e) => {
              e.preventDefault();
              addCustom();
            }}
          >
            <input
              class="onb-input"
              type="text"
              inputMode="url"
              autoComplete="off"
              spellcheck={false}
              placeholder="Add a site, like example.com"
              aria-label="Add a site"
              value={customUrl}
              onInput={(e) => {
                setCustomUrl((e.currentTarget as HTMLInputElement).value);
                setCustomError(null);
              }}
            />
            <button type="submit" class="onb-btn onb-btn-secondary" disabled={!customUrl.trim()}>
              Add
            </button>
          </form>
          <div class="onb-counter" aria-live="polite">
            {customError ??
              (selectedTiles.length >= MAX_FAVORITES
                ? `${MAX_FAVORITES} selected (the most for now)`
                : `${selectedTiles.length} selected`)}
          </div>
        </div>
      </>
    ),
    theme: (
      <>
        <h1 class="onb-heading">Make it yours.</h1>
        <p class="onb-desc">Pick a color for your Space. You can change it any time with Edit Theme.</p>
        <div class="onb-controls">
          <div class="onb-swatches" role="radiogroup" aria-label="Space color">
            {THEME_SWATCHES.map((swatch) => {
              const on = rgbaToHex(style.key_color).toLowerCase() === swatch.hex.toLowerCase();
              return (
                <button
                  key={swatch.hex}
                  type="button"
                  role="radio"
                  aria-checked={on}
                  aria-label={swatch.name}
                  title={swatch.name}
                  class={`onb-swatch${on ? ' is-selected' : ''}`}
                  style={{ '--swatch': swatch.hex }}
                  onClick={() => {
                    setStyle((prev) => ({ ...prev, key_color: hexToRgba(swatch.hex) }));
                    playTick();
                  }}
                />
              );
            })}
            <button
              type="button"
              class="onb-btn onb-btn-secondary onb-shuffle"
              onClick={() => {
                const pick = THEME_SWATCHES[Math.floor(Math.random() * THEME_SWATCHES.length)]!;
                setStyle((prev) => ({
                  ...prev,
                  key_color: hexToRgba(pick.hex),
                  wheel: prev.wheel === 'analogous' ? 'complementary' : 'analogous',
                  color_count: (((prev.color_count % 3) + 1) as 1 | 2 | 3),
                }));
              }}
            >
              Shuffle
            </button>
          </div>
          <div class="onb-field">
            <span class="onb-field-label">Colors</span>
            <div class="onb-segmented" role="radiogroup" aria-label="Number of colors">
              {([1, 2, 3] as const).map((n) => (
                <button
                  key={n}
                  type="button"
                  role="radio"
                  aria-checked={style.color_count === n}
                  class={style.color_count === n ? 'is-on' : ''}
                  onClick={() => setStyle((prev) => ({ ...prev, color_count: n }))}
                >
                  {n === 1 ? 'One' : n === 2 ? 'Two' : 'Three'}
                </button>
              ))}
            </div>
          </div>
          <div class="onb-field">
            <span class="onb-field-label">Appearance</span>
            <div class="onb-segmented" role="radiogroup" aria-label="Appearance">
              {(
                [
                  ['automatic', 'Auto'],
                  ['light', 'Light'],
                  ['dark', 'Dark'],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  role="radio"
                  aria-checked={style.appearance === value}
                  class={style.appearance === value ? 'is-on' : ''}
                  onClick={() => setStyle((prev) => ({ ...prev, appearance: value }))}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
          <div class="onb-switch-card">
            <label class="onb-switch-row">
              <span>
                <span class="onb-switch-title">Block ads and trackers</span>
                <span class="onb-switch-hint">EasyList and EasyPrivacy. Allow any site from Site Controls.</span>
              </span>
              <input
                type="checkbox"
                role="switch"
                class="onb-switch"
                checked={adblock}
                onChange={(e) => setAdblock((e.currentTarget as HTMLInputElement).checked)}
              />
            </label>
            <label class="onb-switch-row">
              <span>
                <span class="onb-switch-title">Make Open your default browser</span>
                <span class="onb-switch-hint">
                  {state?.is_default_browser
                    ? 'Open is already your default browser.'
                    : 'Links from mail and chat open in Open. Your system asks to confirm.'}
                </span>
              </span>
              <input
                type="checkbox"
                role="switch"
                class="onb-switch"
                checked={makeDefault || state?.is_default_browser === true}
                disabled={state?.is_default_browser === true}
                onChange={(e) => setMakeDefault((e.currentTarget as HTMLInputElement).checked)}
              />
            </label>
          </div>
        </div>
      </>
    ),
    ready: (
      <>
        <h1 class="onb-heading">
          Welcome to Open{userName.trim() ? `, ${userName.trim()}` : ''}.
        </h1>
        <p class="onb-desc">Here’s your Open card, made from your color and the day you started.</p>
        <div class="onb-controls">
          <input
            class="onb-input"
            type="text"
            maxLength={40}
            placeholder="Your name (optional)"
            aria-label="Your name"
            value={userName}
            onInput={(e) => setUserName((e.currentTarget as HTMLInputElement).value.slice(0, 40))}
          />
          <ul class="onb-summary">
            <li>
              <span>Import</span>
              <strong>
                {replay && !applyAgain
                  ? 'Nothing new'
                  : selectedSource && importKindsForRun.length
                    ? `${sourceTitle(selectedSource).replace('Import from ', '')} · ${importKindsForRun
                        .map((k) => IMPORT_KIND_LABELS[k].label)
                        .join(', ')}`
                    : 'Starting fresh'}
              </strong>
            </li>
            <li>
              <span>Favorites</span>
              <strong>{selectedTiles.length ? `${selectedTiles.length} new` : 'None for now'}</strong>
            </li>
            <li>
              <span>Space color</span>
              <strong class="onb-summary-swatch">
                <i style={{ background: gradient }} />
                {THEME_SWATCHES.find((s) => s.hex.toLowerCase() === rgbaToHex(style.key_color).toLowerCase())?.name ??
                  'Custom'}
              </strong>
            </li>
            <li>
              <span>Ad blocking</span>
              <strong>{adblock ? 'On' : 'Off'}</strong>
            </li>
            <li>
              <span>Default browser</span>
              <strong>{state?.is_default_browser ? 'Already Open' : makeDefault ? 'Ask when I finish' : 'Not now'}</strong>
            </li>
          </ul>
          {replay && (
            <label class="onb-switch-row onb-replay-row">
              <span>
                <span class="onb-switch-title">Apply these choices again</span>
                <span class="onb-switch-hint">Off: just go back to Open. Existing Favorites are never added twice.</span>
              </span>
              <input
                type="checkbox"
                role="switch"
                class="onb-switch"
                checked={applyAgain}
                onChange={(e) => setApplyAgain((e.currentTarget as HTMLInputElement).checked)}
              />
            </label>
          )}
          {error && (
            <div class="onb-error" role="alert">
              <span>{error.message}</span>
              <div class="onb-error-actions">
                <button type="button" class="onb-btn onb-btn-secondary" onClick={() => void finish()}>
                  Try Again
                </button>
                {error.importFailed && (
                  <button type="button" class="onb-btn onb-btn-ghost" onClick={() => void finish(true)}>
                    Finish Without Importing
                  </button>
                )}
              </div>
            </div>
          )}
          {progress && !error && <div class="onb-progress">{progress}</div>}
        </div>
      </>
    ),
  };

  const formStep = step as Exclude<Step, 'intro'>;
  const nextLabel =
    step === 'ready'
      ? finishing
        ? 'Opening…'
        : replay && !applyAgain
          ? 'Back to Open'
          : 'Open the Door'
      : 'Next';

  return (
    <Room tint={roomTint} class={`onb-setup${leaving ? ' is-leaving' : ''}${reduceMotion ? ' is-reduced' : ''}`}>
      <div class="onb-titlebar" />
      {muteButton}
      <div class="onb-window" role="dialog" aria-label="Set up Open">
        <section class="onb-form">
          <div class="onb-form-top">
            <span class="onb-stepcount">
              Step {setupSteps.indexOf(formStep) + 1} of {setupSteps.length}
            </span>
          </div>
          <div class="onb-form-body" key={step}>
            {formByStep[formStep]}
          </div>
          <footer class="onb-footer">
            <button type="button" class="onb-back" aria-label="Back" onClick={goBack} disabled={finishing}>
              <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
                <path d="M8.5 3L4.5 7l4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </button>
            {step === 'favorites' && (
              <button
                type="button"
                class="onb-skip"
                onClick={() => {
                  setSelected(new Set());
                  goNext();
                }}
              >
                Skip for now
              </button>
            )}
            <span class="onb-footer-spacer" />
            <button
              type="button"
              class="onb-btn onb-btn-primary"
              disabled={finishing}
              onClick={() => (step === 'ready' ? void finish() : goNext())}
            >
              {nextLabel}
            </button>
          </footer>
        </section>

        <aside class={`onb-art${step === 'ready' ? ' is-ready' : ''}`} aria-label="Preview">
          <div class="onb-art-door" aria-hidden="true">
            <DoorwayArch height={118} />
          </div>
          {step === 'ready' ? (
            <div class="onb-ready-stage">
              <div
                class="onb-ready-card"
                aria-hidden="true"
                style={{
                  background: `${READY_PATTERNS[pattern] ?? READY_PATTERNS[0]}, ${gradient}`,
                  color: lightArt ? 'rgba(0,0,0,0.82)' : '#ffffff',
                }}
              >
                {!reduceMotion && (
                  <div class="onb-confetti">
                    {Array.from({ length: 14 }, (_, i) => (
                      <i key={i} style={{ '--k': i }} />
                    ))}
                  </div>
                )}
                <DoorwayEmblem size={40} />
                <div class="onb-ready-name">
                  <strong>{userName.trim() || 'Explorer'}</strong>
                  <span>
                    Since{' '}
                    {new Date().toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })}
                  </span>
                </div>
              </div>
              <button
                type="button"
                class="onb-circle"
                aria-label="Shuffle card pattern"
                onClick={() => setPattern((p) => (p + 1) % READY_PATTERNS.length)}
              >
                <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
                  <path
                    d="M1.5 4h2.2c1.3 0 2.1.6 2.8 1.6l1.4 2.1c.7 1 1.5 1.6 2.8 1.6h1.8M1.5 10h2.2c.9 0 1.5-.3 2-.8M9.6 4.8c.4-.5 1-.8 1.8-.8h1.6M11.4 2.4L13 4l-1.6 1.6M11.4 8.4L13 10l-1.6 1.6"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </button>
            </div>
          ) : (
            <MiniBrowser
              class="onb-mini"
              aria-hidden
              style={style}
              spaceTitle={spaceTitle}
              favorites={miniFavorites}
              todayRows={todayRows}
            >
              <div class="onb-mini-article">
                <strong>Welcome to Open</strong>
                <Landscape class="onb-mini-landscape" />
                <b>Make yourself at home.</b>
                <p>Keep your everyday places close. Leave room for something new.</p>
                {step === 'theme' && !adblock && <div class="onb-mini-ad">Sponsored</div>}
              </div>
            </MiniBrowser>
          )}
          <div class="onb-dots" aria-hidden="true">
            {setupSteps.map((s) => (
              <span key={s} class={s === step ? 'is-active' : ''} />
            ))}
          </div>
        </aside>
      </div>
    </Room>
  );
}
