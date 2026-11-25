import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type BrowserImportSource, type SpaceStyle, rpc } from '../shared/bridge';
import { ONBOARDING_FAVORITES } from '../shared/catalog';
import {
  Badge,
  SpaceThemeEditor,
  Toast,
  Toggle,
  computeSpaceGradientCss,
  hexToRgba,
  isLightSpaceStyle,
} from '../shared/components';
import { CheckIcon, OpenDoorwayMark } from '../shared/icons';

type OnboardingStep = 'intro' | 'name' | 'import' | 'favorites' | 'theme' | 'blocker' | 'default' | 'ready';

const SETUP_STEPS: readonly OnboardingStep[] = [
  'name',
  'import',
  'favorites',
  'theme',
  'blocker',
  'default',
  'ready',
];

const VALUE_LINES = [
  'A calm, fast browser built around Spaces and Tabs.',
  'Built-in ad blocking, Boosts, Split View, and zero-knowledge Sync.',
  'Local-first. No account required. Ready in under a minute.',
];

const SHUFFLE_COLORS = ['#3139FF', '#0D9488', '#D97706', '#DB2777', '#7C3AED', '#2563EB'];

const READY_PATTERNS = [
  'radial-gradient(circle at 80% 20%, rgba(255,255,255,0.28), transparent 45%)',
  'repeating-linear-gradient(135deg, rgba(255,255,255,0.08) 0 12px, transparent 12px 24px)',
  'radial-gradient(circle at 20% 80%, rgba(255,230,150,0.28), transparent 50%)',
  'linear-gradient(120deg, rgba(255,255,255,0.16), transparent 60%)',
  'radial-gradient(circle at 50% 0%, rgba(255,255,255,0.24), transparent 55%)',
  'conic-gradient(from 45deg at 80% 80%, rgba(255,255,255,0.16), transparent 40%)',
];

export function OnboardingApp(): JSX.Element {
  const [step, setStep] = useState<OnboardingStep>('intro');
  const [valueIdx, setValueIdx] = useState(0);
  const [userName, setUserName] = useState('');
  const [importSources, setImportSources] = useState<BrowserImportSource[]>([]);
  const [selectedImportId, setSelectedImportId] = useState<string>('');
  const [importResult, setImportResult] = useState<string | null>(null);
  const [selectedFavIds, setSelectedFavIds] = useState<Set<string>>(
    () => new Set(ONBOARDING_FAVORITES.filter((f) => f.defaultSelected).map((f) => f.id)),
  );
  const [spaceStyle, setSpaceStyle] = useState<SpaceStyle>({
    math_version: 1,
    key_color: { r: 0.19, g: 0.22, b: 1.0, a: 1 },
    color_count: 2,
    wheel: 'analogous',
    appearance: 'automatic',
    noise_factor: 0.16,
    texture: 'grain',
    intensity_factor: 0.65,
  });
  const [adBlockEnabled, setAdBlockEnabled] = useState(true);
  const [wantDefaultBrowser, setWantDefaultBrowser] = useState(true);
  const [isDefaultBrowser, setIsDefaultBrowser] = useState(false);
  const [readyPatternIdx, setReadyPatternIdx] = useState(0);
  const [completing, setCompleting] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2500);
  };

  useEffect(() => {
    void rpc('onboarding.getState', {}).then((st) => {
      setSpaceStyle(st.default_space_style);
      setAdBlockEnabled(st.adblock_enabled);
      setIsDefaultBrowser(st.is_default_browser);
    });
    void rpc('import.probeBrowsers', {}).then((res) => {
      setImportSources(res.sources);
      if (res.sources[0]) setSelectedImportId(res.sources[0].id);
    });
  }, []);

  useEffect(() => {
    if (step !== 'intro') return;
    const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (reduced) return;
    const timer = window.setInterval(() => {
      setValueIdx((i) => (i + 1) % VALUE_LINES.length);
    }, 2400);
    return () => window.clearInterval(timer);
  }, [step]);

  const stepIdx = SETUP_STEPS.indexOf(step);
  const goBack = () => {
    if (stepIdx <= 0) setStep('intro');
    else setStep(SETUP_STEPS[stepIdx - 1]!);
  };
  const goNext = () => {
    if (step === 'intro') setStep('name');
    else if (stepIdx >= 0 && stepIdx < SETUP_STEPS.length - 1) setStep(SETUP_STEPS[stepIdx + 1]!);
  };

  const toggleFav = (id: string) => {
    setSelectedFavIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const selectedFavs = ONBOARDING_FAVORITES.filter((f) => selectedFavIds.has(f.id));
  const spaceTitle = userName.trim() ? `${userName.trim()}'s Space` : 'Personal';
  const artGradient = computeSpaceGradientCss(spaceStyle);
  const artLightText = !isLightSpaceStyle(spaceStyle);

  const handleFinish = async () => {
    setCompleting(true);
    try {
      const res = await rpc('onboarding.complete', {
        user_name: userName.trim().slice(0, 40),
        imported_source_id: importResult ? selectedImportId : undefined,
        favorite_urls: selectedFavs.map((f) => f.url),
        space_style: spaceStyle,
        adblock_enabled: adBlockEnabled,
        make_default_browser: wantDefaultBrowser,
      });
      showToast(`Setup complete! Opening ${res.welcome_url}`);
      if (window.location.protocol !== 'open:') {
        window.location.href = '/welcome.html';
      }
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'Unable to save setup.');
    } finally {
      setCompleting(false);
    }
  };

  return (
    <div class="onb-room">
      <div class="onb-grain" />

      {step === 'intro' ? (
        <section class="onb-intro" aria-label="Welcome to Open">
          <div class="onb-doorway-halo">
            <OpenDoorwayMark size={84} />
          </div>
          <h1 class="onb-wordmark">Open</h1>
          <p class="onb-value-line">{VALUE_LINES[valueIdx]}</p>
          <button
            type="button"
            class="open-btn open-btn-primary"
            style={{ height: '40px', padding: '0 26px', fontSize: '14px', borderRadius: '11px' }}
            onClick={goNext}
          >
            Continue
          </button>
        </section>
      ) : (
        <div class="onb-window">
          <section class="onb-form-pane">
            <div>
              {step === 'name' && (
                <>
                  <h1 class="onb-step-heading">What should we call you?</h1>
                  <p class="onb-step-desc">
                    Optional. Used only on your device to personalize your Space and welcome card.
                  </p>
                  <div class="onb-controls">
                    <input
                      class="open-input"
                      style={{ height: '38px', fontSize: '14px' }}
                      maxLength={40}
                      placeholder="Your first name"
                      aria-label="Your name"
                      value={userName}
                      onInput={(e) => setUserName((e.currentTarget as HTMLInputElement).value.slice(0, 40))}
                    />
                  </div>
                </>
              )}

              {step === 'import' && (
                <>
                  <h1 class="onb-step-heading">Import your browser data</h1>
                  <p class="onb-step-desc">
                    Bring bookmarks, Favorites, history, and extensions from another browser on this machine.
                  </p>
                  <div class="onb-controls">
                    {importSources.map((src) => (
                      <label
                        key={src.id}
                        class={`onb-radio-card${selectedImportId === src.id ? ' is-selected' : ''}`}
                        style={{ height: 'auto', padding: '12px 14px', justifyContent: 'space-between' }}
                      >
                        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                          <input
                            type="radio"
                            name="onb-import"
                            checked={selectedImportId === src.id}
                            onChange={() => setSelectedImportId(src.id)}
                          />
                          <div>
                            <div style={{ fontWeight: 600 }}>
                              {src.browser_name} · {src.profile_name}
                            </div>
                            <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)', fontVariantNumeric: 'tabular-nums' }}>
                              {src.bookmarks_count} bookmarks · {src.history_count} history · {src.favorites_count} Favorites
                            </div>
                          </div>
                        </div>
                      </label>
                    ))}
                    <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                      <button
                        type="button"
                        class="open-btn open-btn-primary"
                        disabled={!selectedImportId}
                        onClick={async () => {
                          const res = await rpc('import.run', {
                            source_id: selectedImportId,
                            kinds: ['bookmarks', 'history', 'favorites'],
                          });
                          setImportResult(
                            `Imported ${res.imported_bookmarks} bookmarks & ${res.imported_favorites} Favorites.`,
                          );
                        }}
                      >
                        Import Now
                      </button>
                      {importResult && <Badge tone="success">{importResult}</Badge>}
                    </div>
                  </div>
                </>
              )}

              {step === 'favorites' && (
                <>
                  <h1 class="onb-step-heading">Pin your everyday Favorites</h1>
                  <p class="onb-step-desc">
                    Favorites stay anchored at the top of your sidebar across every Space in this Profile.
                  </p>
                  <div class="onb-controls">
                    <div class="onb-favorites-grid">
                      {ONBOARDING_FAVORITES.map((fav) => {
                        const selected = selectedFavIds.has(fav.id);
                        return (
                          <button
                            key={fav.id}
                            type="button"
                            class={`onb-fav-tile${selected ? ' is-selected' : ''}`}
                            aria-pressed={selected}
                            onClick={() => toggleFav(fav.id)}
                          >
                            {selected && (
                              <span class="onb-fav-check" aria-hidden="true">
                                <CheckIcon size={10} />
                              </span>
                            )}
                            <span class="onb-fav-icon" style={{ background: fav.hueColor }}>
                              {fav.monogram}
                            </span>
                            <span class="onb-fav-label">{fav.title}</span>
                          </button>
                        );
                      })}
                    </div>
                    <div style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>
                      {selectedFavIds.size} Favorite{selectedFavIds.size === 1 ? '' : 's'} selected
                    </div>
                  </div>
                </>
              )}

              {step === 'theme' && (
                <>
                  <h1 class="onb-step-heading">Pick a look for your Space</h1>
                  <p class="onb-step-desc">
                    Every Space can have its own multi-color OKLab gradient, grain texture, and light/dark appearance.
                  </p>
                  <div class="onb-controls">
                    <SpaceThemeEditor style={spaceStyle} title={spaceTitle} onChange={setSpaceStyle} />
                    <div>
                      <button
                        type="button"
                        class="open-btn"
                        onClick={() => {
                          const nextHex = SHUFFLE_COLORS[Math.floor(Math.random() * SHUFFLE_COLORS.length)]!;
                          setSpaceStyle((prev) => ({
                            ...prev,
                            key_color: hexToRgba(nextHex),
                            wheel: prev.wheel === 'analogous' ? 'complementary' : 'analogous',
                          }));
                        }}
                      >
                        Shuffle Theme
                      </button>
                    </div>
                  </div>
                </>
              )}

              {step === 'blocker' && (
                <>
                  <h1 class="onb-step-heading">Block ads and trackers by default</h1>
                  <p class="onb-step-desc">
                    Open ships with a fast Rust ad-blocker using EasyList and EasyPrivacy. Cookie-banner lists stay off by default, and you can allow any site anytime.
                  </p>
                  <div class="onb-controls">
                    <div
                      class="open-card"
                      style={{
                        padding: '16px',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        gap: '14px',
                      }}
                    >
                      <div>
                        <div style={{ fontWeight: 600 }}>Built-in Ad & Tracker Blocker</div>
                        <div style={{ fontSize: '12px', color: 'var(--text-secondary)', marginTop: '3px' }}>
                          EasyList + EasyPrivacy · Per-site exceptions in Site Control
                        </div>
                      </div>
                      <Toggle
                        label="Enable built-in ad blocker"
                        checked={adBlockEnabled}
                        onChange={setAdBlockEnabled}
                      />
                    </div>
                  </div>
                </>
              )}

              {step === 'default' && (
                <>
                  <h1 class="onb-step-heading">Make Open your default browser?</h1>
                  <p class="onb-step-desc">
                    Links from mail, chat, and terminals will open smoothly in Little Open or your Air Traffic Control Space.
                  </p>
                  <div class="onb-controls">
                    <label class={`onb-radio-card${wantDefaultBrowser ? ' is-selected' : ''}`}>
                      <input
                        type="radio"
                        name="default-browser"
                        checked={wantDefaultBrowser}
                        onChange={() => setWantDefaultBrowser(true)}
                      />
                      <span>Yes, make Open my default browser</span>
                    </label>
                    <label class={`onb-radio-card${!wantDefaultBrowser ? ' is-selected' : ''}`}>
                      <input
                        type="radio"
                        name="default-browser"
                        checked={!wantDefaultBrowser}
                        onChange={() => setWantDefaultBrowser(false)}
                      />
                      <span>Not right now</span>
                    </label>
                  </div>
                </>
              )}

              {step === 'ready' && (
                <>
                  <h1 class="onb-step-heading">You’re ready for Open</h1>
                  <p class="onb-step-desc">
                    Your Space theme, Favorites, and privacy defaults are ready to apply.
                  </p>
                  <div class="onb-controls">
                    <div
                      class="onb-ready-card"
                      style={{
                        background: `${READY_PATTERNS[readyPatternIdx]}, ${artGradient}`,
                        color: artLightText ? '#ffffff' : '#14151f',
                      }}
                    >
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <OpenDoorwayMark size={34} />
                        <span style={{ fontSize: '11.5px', opacity: 0.78 }}>
                          {new Date().toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })}
                        </span>
                      </div>
                      <div>
                        <div style={{ fontSize: '22px', fontWeight: 700 }}>{userName.trim() || 'Open Explorer'}</div>
                        <div style={{ fontSize: '12px', opacity: 0.8 }}>
                          {selectedFavs.length} Favorites · Ad Blocker {adBlockEnabled ? 'On' : 'Off'}
                        </div>
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: '8px' }}>
                      <button
                        type="button"
                        class="open-btn"
                        onClick={() => setReadyPatternIdx((i) => (i + 1) % READY_PATTERNS.length)}
                      >
                        Shuffle Card Pattern
                      </button>
                    </div>
                  </div>
                </>
              )}
            </div>

            <footer class="onb-footer">
              <button type="button" class="open-btn open-btn-ghost" onClick={goBack}>
                Back
              </button>
              <div style={{ display: 'flex', gap: '8px' }}>
                {step === 'import' && (
                  <button type="button" class="open-btn open-btn-ghost" onClick={goNext}>
                    Skip
                  </button>
                )}
                {step === 'ready' ? (
                  <button
                    type="button"
                    class="open-btn open-btn-primary"
                    disabled={completing}
                    onClick={() => void handleFinish()}
                  >
                    {completing ? 'Starting…' : 'Get Started'}
                  </button>
                ) : (
                  <button
                    type="button"
                    class="open-btn open-btn-primary"
                    onClick={async () => {
                      if (step === 'default' && wantDefaultBrowser && !isDefaultBrowser) {
                        const res = await rpc('settings.setDefaultBrowser', {});
                        setIsDefaultBrowser(res.is_default);
                      }
                      goNext();
                    }}
                  >
                    {step === 'default' && wantDefaultBrowser && !isDefaultBrowser ? 'Make Default' : 'Next'}
                  </button>
                )}
              </div>
            </footer>
          </section>

          <aside
            class="onb-art-pane"
            style={{
              background: artGradient,
              color: artLightText ? '#ffffff' : '#14151f',
            }}
          >
            <div class="onb-mini-browser">
              <div class="onb-mini-sidebar">
                <div style={{ fontSize: '11.5px', fontWeight: 700, padding: '2px 4px', opacity: 0.92 }}>
                  {spaceTitle}
                </div>
                <div class="onb-mini-favs">
                  {selectedFavs.slice(0, 8).map((f) => (
                    <div key={f.id} class="onb-mini-fav-cell" style={{ background: f.hueColor }} title={f.title}>
                      {f.monogram}
                    </div>
                  ))}
                </div>
                <div style={{ borderTop: '1px solid rgba(255,255,255,0.2)', paddingTop: '8px', display: 'flex', flexDirection: 'column', gap: '5px', fontSize: '10.5px' }}>
                  <div style={{ padding: '4px 6px', borderRadius: '6px', background: 'rgba(255,255,255,0.18)', fontWeight: 600 }}>
                    Welcome to Open
                  </div>
                  <div style={{ padding: '4px 6px', opacity: 0.8 }}>Today · Reading List</div>
                  {step === 'default' && wantDefaultBrowser && (
                    <div style={{ padding: '4px 6px', borderRadius: '6px', background: 'rgba(255,255,255,0.22)' }}>
                      Mail link → Little Open
                    </div>
                  )}
                </div>
              </div>

              <div class="onb-mini-page">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <strong style={{ fontSize: '12px' }}>Editorial Preview</strong>
                  {adBlockEnabled && <Badge tone="success">Ad Blocked</Badge>}
                </div>
                <div
                  style={{
                    height: '92px',
                    borderRadius: '8px',
                    background: 'linear-gradient(135deg, #3139FF 0%, #FF9B54 100%)',
                    display: 'flex',
                    alignItems: 'flex-end',
                    padding: '8px',
                    color: '#ffffff',
                    fontSize: '11px',
                    fontWeight: 600,
                  }}
                >
                  Open Unified · Calm Browsing
                </div>
                <p style={{ margin: 0, fontSize: '11.5px', color: 'var(--text-secondary)', lineHeight: 1.5 }}>
                  Spaces keep your projects organized while Favorites stay one click away.
                </p>
                {!adBlockEnabled && (
                  <div
                    style={{
                      padding: '8px',
                      borderRadius: '6px',
                      border: '1px dashed var(--open-sun)',
                      fontSize: '10.5px',
                      color: 'var(--open-sun)',
                    }}
                  >
                    Sponsored banner placeholder (blocked when Ad Blocker is on)
                  </div>
                )}
              </div>
            </div>

            <div class="onb-step-dots" aria-label="Setup progress">
              {SETUP_STEPS.map((s) => (
                <span key={s} class={`onb-step-dot${step === s ? ' is-active' : ''}`} />
              ))}
            </div>
          </aside>
        </div>
      )}

      <Toast message={toast} />
    </div>
  );
}
