import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type ShortcutBinding, isNativeWebUI, rpc } from '../shared/bridge';
import { Badge, Toast } from '../shared/components';
import { OpenDoorwayMark } from '../shared/icons';
import { currentPageRoute, replacePageRoute } from '../shared/route';
import { isMacPlatform, shortcutKeycaps } from '../shared/shortcuts';

interface WelcomeStepDef {
  index: number;
  id: 'pin' | 'spaces' | 'split' | 'new-tab';
  title: string;
  body: string;
  icon: string;
}

const STEPS: readonly WelcomeStepDef[] = [
  {
    index: 1,
    id: 'pin',
    title: 'Pin',
    icon: '📌',
    body: 'Keep important tabs above the divider. Pinned tabs stay organized and never auto-archive.',
  },
  {
    index: 2,
    id: 'spaces',
    title: 'Spaces',
    icon: '🗂️',
    body: 'Separate work, research, and personal projects into themed Spaces with distinct colors and Profiles.',
  },
  {
    index: 3,
    id: 'split',
    title: 'Split',
    icon: '◫',
    body: 'Open up to four live web pages side by side in one Space tab to compare docs, code, and previews.',
  },
  {
    index: 4,
    id: 'new-tab',
    title: 'New tab',
    icon: isMacPlatform() ? '⌘' : '⌨️',
    body: 'Open the zero-latency Command Bar anytime to search, jump to tabs, run actions, or open URLs.',
  },
];

const CLIP_DURATION_MS = 8500;

// Help & Resources (open://welcome/help): the essential shortcuts with the
// user's live bindings. Each row lists the command ids that may carry it
// (C++ CommandRegistry ids first) and the default binding.
interface HelpShortcutDef {
  label: string;
  ids: readonly string[];
  fallback: string;
}

const HELP_SHORTCUTS: readonly HelpShortcutDef[] = [
  { label: 'New tab (Command Bar)', ids: ['new-tab'], fallback: 'Mod+T' },
  { label: 'Edit the current URL', ids: ['open-command-bar'], fallback: 'Mod+L' },
  { label: 'Show or hide the sidebar', ids: ['toggle-sidebar'], fallback: 'Mod+S' },
  { label: 'Find on page', ids: ['find'], fallback: 'Mod+F' },
  { label: 'Copy the current URL', ids: ['copy-url'], fallback: 'Mod+Shift+C' },
  { label: 'Add Split View', ids: ['add-split-view'], fallback: 'Ctrl+Shift+=' },
  { label: 'Switch to a recent tab', ids: ['tab-switcher-forward'], fallback: 'Ctrl+Tab' },
  { label: 'New Little Open window', ids: ['new-little-open-window', 'new-little-open'], fallback: 'Mod+Alt+N' },
  { label: 'Next Space', ids: ['next-space'], fallback: 'Mod+Alt+Right' },
];

function helpKeys(def: HelpShortcutDef, bindings: readonly ShortcutBinding[]): string {
  for (const id of def.ids) {
    const binding = bindings.find((b) => b.id === id);
    if (binding) return binding.keys;
  }
  return def.fallback;
}

function Keycaps({ keys, label }: { keys: string; label: string }): JSX.Element {
  return (
    <span class="welcome-keycaps" aria-label={label}>
      {shortcutKeycaps(keys).map((cap, i) => (
        <span key={`${cap}-${i}`} class="welcome-keycap">
          {cap}
        </span>
      ))}
    </span>
  );
}

function HelpView({ onBack }: { onBack: () => void }): JSX.Element {
  const [bindings, setBindings] = useState<ShortcutBinding[]>([]);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    rpc('settings.getShortcuts', {})
      .then((res) => {
        if (active) setBindings(res.shortcuts);
      })
      .catch(() => {
        // Defaults stay on screen.
      });
    return () => {
      active = false;
    };
  }, []);

  return (
    <section class="welcome-help" aria-label="Help and resources">
      <div class="welcome-help-header">
        <OpenDoorwayMark size={36} />
        <div>
          <h1 class="welcome-heading">Help &amp; Resources</h1>
          <p class="welcome-help-lede">The shortcuts that make Open fast, with your current bindings.</p>
        </div>
      </div>

      <div class="welcome-help-card" role="list" aria-label="Essential shortcuts">
        {HELP_SHORTCUTS.map((def) => {
          const keys = helpKeys(def, bindings);
          if (!keys) return null;
          return (
            <div key={def.label} class="welcome-help-row" role="listitem">
              <span>{def.label}</span>
              <Keycaps keys={keys} label={`${def.label} shortcut`} />
            </div>
          );
        })}
      </div>

      <div class="welcome-help-actions">
        <button
          type="button"
          class="open-btn open-btn-primary"
          onClick={async () => {
            try {
              const res = await rpc('welcome.triggerAction', { action: 'shortcuts' });
              if (res.message) setMessage(res.message);
            } catch (err) {
              setMessage(err instanceof Error ? err.message : 'Cannot open shortcut settings.');
            }
          }}
        >
          Customize Shortcuts
        </button>
        <button type="button" class="open-btn" onClick={onBack}>
          Back to the Basics
        </button>
      </div>
      {message && <p class="welcome-help-lede">{message}</p>}
    </section>
  );
}

export function WelcomeApp(): JSX.Element {
  const [view, setView] = useState<'basics' | 'help'>(() =>
    currentPageRoute().segments[0] === 'help' ? 'help' : 'basics',
  );
  const [reduceMotion, setReduceMotion] = useState<boolean>(() =>
    typeof window !== 'undefined' && window.matchMedia
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false,
  );
  const [activeIndex, setActiveIndex] = useState(0);
  const [playingPlaylist, setPlayingPlaylist] = useState<boolean>(() => !reduceMotion);
  const [ended, setEnded] = useState(false);
  const [progress, setProgress] = useState(0);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2200);
  };

  useEffect(() => {
    const mq = window.matchMedia?.('(prefers-reduced-motion: reduce)');
    if (!mq) return;
    const onChange = () => {
      setReduceMotion(mq.matches);
      if (mq.matches) {
        setPlayingPlaylist(false);
        setProgress(1);
      }
    };
    mq.addEventListener?.('change', onChange);
    return () => mq.removeEventListener?.('change', onChange);
  }, []);

  // Playlist timer (8.5s per step, pauses when tab hidden, disabled under Reduce Motion)
  useEffect(() => {
    if (reduceMotion || ended || !playingPlaylist) return;
    let rafId = 0;
    let start = performance.now();

    const tick = (now: number) => {
      if (document.hidden) {
        start = now - progress * CLIP_DURATION_MS;
        rafId = requestAnimationFrame(tick);
        return;
      }
      const elapsed = now - start;
      const pct = Math.min(1, elapsed / CLIP_DURATION_MS);
      setProgress(pct);
      if (pct >= 1) {
        if (activeIndex < STEPS.length - 1) {
          setActiveIndex((i) => i + 1);
          setProgress(0);
        } else {
          setEnded(true);
          setPlayingPlaylist(false);
        }
        return;
      }
      rafId = requestAnimationFrame(tick);
    };

    rafId = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(rafId);
  }, [activeIndex, playingPlaylist, ended, reduceMotion]);

  const selectStep = (idx: number) => {
    setActiveIndex(idx);
    setEnded(false);
    setProgress(reduceMotion ? 1 : 0);
    setPlayingPlaylist(!reduceMotion);
  };

  const handleReplayAll = async () => {
    setActiveIndex(0);
    setEnded(false);
    setProgress(0);
    setPlayingPlaylist(!reduceMotion);
    await rpc('welcome.triggerAction', { action: 'replay_all' });
  };

  const activeStep = STEPS[activeIndex] ?? STEPS[0]!;

  if (view === 'help') {
    return (
      <div class="welcome-shell">
        <HelpView
          onBack={() => {
            replacePageRoute('');
            setView('basics');
          }}
        />
        <Toast message={toast} />
      </div>
    );
  }

  return (
    <div class="welcome-shell">
      <div class="welcome-top-links">
        <button
          type="button"
          class="open-btn"
          onClick={async () => {
            await rpc('welcome.triggerAction', { action: 'shortcuts' });
            showToast('Opened Essential Shortcuts.');
          }}
        >
          Learn Essential Shortcuts
        </button>
        <button
          type="button"
          class="open-btn"
          onClick={async () => {
            await rpc('welcome.triggerAction', { action: 'help' });
            // In Chromium the browser opens open://welcome/help in a new tab;
            // the standalone preview shows the view in place.
            if (!isNativeWebUI()) {
              setView('help');
              return;
            }
            showToast('Opened Help & Resources.');
          }}
        >
          Help &amp; Resources
        </button>
      </div>

      <div class="welcome-layout">
        <section class="welcome-left" aria-label="Open basics guide">
          <OpenDoorwayMark size={44} />
          <h1 class="welcome-heading">
            You’re all set.
            <br />
            Here are the basics.
          </h1>

          <div class="welcome-accordion" role="tablist" aria-label="Basics steps">
            {STEPS.map((st, idx) => {
              const isActive = idx === activeIndex;
              return (
                <button
                  key={st.id}
                  type="button"
                  role="tab"
                  aria-selected={isActive}
                  class={`welcome-step${isActive ? ' is-active' : ''}`}
                  onClick={() => selectStep(idx)}
                >
                  <div class="welcome-step-header">
                    <span class="welcome-step-num">{st.index}</span>
                    <span class="welcome-step-title">
                      {isActive ? `${st.icon} ` : ''}
                      {st.title}
                    </span>
                  </div>
                  {isActive && (
                    <>
                      <p class="welcome-step-body">{st.body}</p>
                      {st.id === 'new-tab' && <Keycaps keys="Mod+T" label="New tab shortcut" />}
                      <div class="welcome-progress-track">
                        <div
                          class="welcome-progress-fill"
                          style={{ transform: `scaleX(${reduceMotion ? 1 : progress})` }}
                        />
                      </div>
                    </>
                  )}
                </button>
              );
            })}
          </div>
        </section>

        <section class="welcome-stage-panel" aria-label={`Interactive preview for ${activeStep.title}`}>
          <div class={`welcome-stage-canvas${ended ? ' is-ended' : ''}`}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: '8px', borderRight: '1px solid rgba(255,255,255,0.12)', paddingRight: '12px' }}>
              <div style={{ fontSize: '11px', fontWeight: 700, opacity: 0.75 }}>
                {activeStep.id === 'spaces' ? '⚡ Engineering Space' : '☀️ Home Space'}
              </div>
              <div
                style={{
                  padding: '8px',
                  borderRadius: '8px',
                  background: activeStep.id === 'pin' ? 'rgba(85,97,255,0.45)' : 'rgba(255,255,255,0.08)',
                  border: activeStep.id === 'pin' ? '1px solid #8c95ff' : '1px solid transparent',
                  fontSize: '11.5px',
                  fontWeight: 600,
                }}
              >
                📌 Pinned: Docs
              </div>
              <div style={{ padding: '7px 8px', borderRadius: '8px', background: 'rgba(255,255,255,0.06)', fontSize: '11px', opacity: 0.85 }}>
                Today: Design Spec
              </div>
              <div style={{ marginTop: 'auto', display: 'flex', gap: '6px' }}>
                <span style={{ padding: '3px 7px', borderRadius: '999px', fontSize: '10px', background: activeStep.id === 'spaces' ? 'rgba(255,255,255,0.12)' : '#3139FF' }}>
                  Home
                </span>
                <span style={{ padding: '3px 7px', borderRadius: '999px', fontSize: '10px', background: activeStep.id === 'spaces' ? '#FF5C35' : 'rgba(255,255,255,0.12)' }}>
                  Work
                </span>
              </div>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: '10px', position: 'relative' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <Badge tone="accent">Step {activeStep.index} of 4 · {activeStep.title}</Badge>
                {reduceMotion && <Badge>Reduce Motion</Badge>}
              </div>

              {activeStep.id === 'split' ? (
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px', flex: 1 }}>
                  <div style={{ borderRadius: '10px', background: 'rgba(255,255,255,0.08)', padding: '14px' }}>
                    <div style={{ fontWeight: 700, fontSize: '13px', marginBottom: '6px' }}>Pane 1 · Reference</div>
                    <div style={{ fontSize: '11.5px', opacity: 0.78 }}>Read documentation side by side without switching windows.</div>
                  </div>
                  <div style={{ borderRadius: '10px', background: 'rgba(49,57,255,0.28)', border: '1px solid rgba(120,130,255,0.5)', padding: '14px' }}>
                    <div style={{ fontWeight: 700, fontSize: '13px', marginBottom: '6px' }}>Pane 2 · Live App</div>
                    <div style={{ fontSize: '11.5px', opacity: 0.85 }}>Drag any tab onto a pane to build 2–4 pane Split Views.</div>
                  </div>
                </div>
              ) : activeStep.id === 'new-tab' ? (
                <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <div
                    style={{
                      width: '88%',
                      borderRadius: '14px',
                      background: '#1d1d27',
                      border: '1px solid rgba(255,255,255,0.22)',
                      padding: '14px 16px',
                      boxShadow: '0 24px 48px rgba(0,0,0,0.45)',
                    }}
                  >
                    <div style={{ fontSize: '14px', fontWeight: 600, marginBottom: '10px' }}>
                      ⌘T · Search or enter URL…
                    </div>
                    <div style={{ fontSize: '11.5px', opacity: 0.75 }}>
                      Switch to tab · Open Settings · New Easel · Boost this site
                    </div>
                  </div>
                </div>
              ) : (
                <div
                  style={{
                    flex: 1,
                    borderRadius: '12px',
                    background:
                      activeStep.id === 'spaces'
                        ? 'linear-gradient(135deg, rgba(255,92,53,0.42), rgba(49,57,255,0.42))'
                        : 'linear-gradient(135deg, rgba(49,57,255,0.38), rgba(0,184,124,0.32))',
                    padding: '20px',
                    display: 'flex',
                    flexDirection: 'column',
                    justifyContent: 'center',
                    gap: '8px',
                  }}
                >
                  <div style={{ fontSize: '20px', fontWeight: 800 }}>
                    {activeStep.icon} {activeStep.title}
                  </div>
                  <div style={{ fontSize: '13px', opacity: 0.9, maxWidth: '380px', lineHeight: 1.55 }}>
                    {activeStep.body}
                  </div>
                </div>
              )}
            </div>
          </div>

          {ended && (
            <div class="welcome-replay-overlay">
              <button
                type="button"
                class="open-btn open-btn-primary"
                style={{ height: '38px', padding: '0 20px', fontSize: '13.5px' }}
                onClick={() => void handleReplayAll()}
              >
                Replay All
              </button>
            </div>
          )}
        </section>
      </div>

      <Toast message={toast} />
    </div>
  );
}
