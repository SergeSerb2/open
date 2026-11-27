// open://welcome — Open's settled Welcome tab, in Open's own identity: the
// night room tinted by this Space, the doorway-and-sun, and "You're all set.
// Here are the basics." Six try-it cards run the real commands
// (welcome.triggerAction), a checklist remembers what was tried
// (welcome.markStepDone), and the Essential Shortcuts sheet shows the live
// CommandRegistry bindings (open://welcome#shortcuts, /shortcuts or /help).

import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { isNativeWebUI } from '../shared/bridge';
import { rgbaToHex } from '../shared/components';
import { currentPageRoute, replacePageRoute } from '../shared/route';
import { type ShortcutPlatform, shortcutKeycaps } from '../shared/shortcuts';
import { subscribeSettingsTheme } from '../shared/theme';
import { DoorwayArch, DoorwayEmblem, Room } from '../onboarding/art';
import {
  type EssentialShortcut,
  type WelcomeState,
  type WelcomeStep,
  getWelcomeState,
  markWelcomeStep,
  triggerWelcomeAction,
} from '../onboarding/rpc';
import { type DemoId, FeatureDemo } from './demos';

interface FeatureCard {
  id: DemoId;
  step: string;
  title: string;
  body: string;
  /** CommandRegistry id whose binding is shown; or literal keys. */
  shortcutId?: string;
  literalKeys?: { mac: string; other: string };
  action: string;
  actionLabel: string;
  secondary?: { action: string; label: string };
}

const CARDS: readonly FeatureCard[] = [
  {
    id: 'command-bar',
    step: 'command-bar',
    title: 'Open anything',
    body: 'Search, open a site, or jump to a tab you already have. It all starts in the Command Bar.',
    shortcutId: 'new-tab',
    action: 'open-command-bar',
    actionLabel: 'Try it now',
  },
  {
    id: 'sidebar',
    step: 'sidebar',
    title: 'Hide the sidebar',
    body: 'Give a page the whole window. Press the same keys again and your tabs come back.',
    shortcutId: 'toggle-sidebar',
    action: 'toggle-sidebar',
    actionLabel: 'Try it now',
  },
  {
    id: 'spaces',
    step: 'theme',
    title: 'A Space for every part of life',
    body: 'Spaces keep separate tabs for work, projects and home, each with its own color.',
    shortcutId: 'next-space',
    action: 'edit-theme',
    actionLabel: 'Customize Space',
  },
  {
    id: 'peek-split',
    step: 'peek',
    title: 'Peek and Split View',
    body: 'Shift-click a link to look at it without leaving the page. Put two pages side by side with Split View.',
    literalKeys: { mac: 'Shift+Click', other: 'Shift+Click' },
    shortcutId: 'add-split-view',
    action: 'peek',
    actionLabel: 'Try Peek',
    secondary: { action: 'split-view', label: 'Try Split View' },
  },
  {
    id: 'boosts',
    step: 'boosts',
    title: 'Boosts and Zap',
    body: 'Change how any site looks: its colors, its fonts, and the parts you would rather not see.',
    action: 'new-boost',
    actionLabel: 'Try Boosts',
  },
  {
    id: 'library',
    step: 'library',
    title: 'Your Library',
    body: 'Downloads, archived tabs, history, captures and Boosts, all in one place.',
    shortcutId: 'view-library',
    action: 'view-library',
    actionLabel: 'Open Library',
  },
];

const SHORTCUT_GROUPS = ['Navigation', 'Tabs', 'Spaces', 'Split & Peek', 'Boosts & Capture'] as const;

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;
}

function Keycaps({ keys, platform, label }: { keys: string; platform: ShortcutPlatform; label?: string }): JSX.Element {
  const caps =
    keys === 'Shift+Click'
      ? platform === 'mac'
        ? ['⇧', 'Click']
        : ['Shift', 'Click']
      : shortcutKeycaps(keys, platform);
  return (
    <span class="wel-keycaps" aria-label={label ?? caps.join(' ')}>
      {caps.map((cap, i) => (
        <kbd key={`${cap}-${i}`} class="wel-keycap">
          {cap}
        </kbd>
      ))}
    </span>
  );
}

function CheckBadge({ done }: { done: boolean }): JSX.Element {
  return (
    <span class={`wel-check${done ? ' is-done' : ''}`} aria-hidden="true">
      {done && (
        <svg width="10" height="10" viewBox="0 0 10 10">
          <path d="M2 5.2l2 2L8 3" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      )}
    </span>
  );
}

// --- Essential Shortcuts sheet -------------------------------------------------------

function ShortcutsSheet({
  shortcuts,
  platform,
  onClose,
  onAction,
}: {
  shortcuts: readonly EssentialShortcut[];
  platform: ShortcutPlatform;
  onClose: () => void;
  onAction: (action: string) => void;
}): JSX.Element {
  const [query, setQuery] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const q = query.trim().toLowerCase();
  const visible = shortcuts.filter(
    (s) => s.keys && (!q || s.title.toLowerCase().includes(q) || s.keys.toLowerCase().includes(q)),
  );

  return (
    <div class="wel-sheet-scrim" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div class="wel-sheet" role="dialog" aria-modal="true" aria-label="Essential Shortcuts" ref={dialogRef}>
        <header class="wel-sheet-head">
          <DoorwayEmblem size={28} />
          <div class="wel-sheet-title">
            <h2>Essential Shortcuts</h2>
            <p>Your current keys. {platform === 'mac' ? '⌘ Command · ⌥ Option · ⌃ Control · ⇧ Shift' : 'Ctrl · Alt · Shift'}</p>
          </div>
          <button type="button" class="wel-icon-btn" aria-label="Close" onClick={onClose}>
            <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
              <path d="M2.5 2.5l7 7M9.5 2.5l-7 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
        </header>
        <input
          ref={inputRef}
          class="wel-search"
          type="search"
          placeholder="Search shortcuts"
          aria-label="Search shortcuts"
          value={query}
          onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)}
        />
        <div class="wel-sheet-groups">
          {SHORTCUT_GROUPS.map((group) => {
            const rows = visible.filter((s) => s.group === group);
            if (!rows.length) return null;
            return (
              <section key={group} class="wel-sheet-group" aria-label={group}>
                <h3>{group}</h3>
                {rows.map((s) => (
                  <div key={s.id} class="wel-sheet-row">
                    <span>{s.title.replace(/…$/, '')}</span>
                    <Keycaps keys={s.keys} platform={platform} label={`${s.title} shortcut`} />
                  </div>
                ))}
              </section>
            );
          })}
          {visible.length === 0 && <p class="wel-sheet-empty">No shortcut matches “{query}”.</p>}
        </div>
        <footer class="wel-sheet-foot">
          <button type="button" class="wel-btn wel-btn-quiet" onClick={() => onAction('customize-shortcuts')}>
            Customize Shortcuts…
          </button>
          <button type="button" class="wel-btn wel-btn-primary" onClick={onClose}>
            Done
          </button>
        </footer>
      </div>
    </div>
  );
}

// --- Page ----------------------------------------------------------------------------

export function WelcomeApp(): JSX.Element {
  const reduceMotion = useMemo(prefersReducedMotion, []);
  const [state, setState] = useState<WelcomeState | null>(null);
  const [steps, setSteps] = useState<WelcomeStep[]>([]);
  const [sheetOpen, setSheetOpen] = useState(() => {
    const route = currentPageRoute().segments[0];
    return route === 'shortcuts' || route === 'help';
  });
  const [playing, setPlaying] = useState<Set<DemoId>>(new Set());
  const [replayKey, setReplayKey] = useState(0);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [hidden, setHidden] = useState(false);
  const cardRefs = useRef<Map<DemoId, HTMLElement>>(new Map());

  const showToast = useCallback((message: string) => {
    setToast(message);
    window.setTimeout(() => setToast((current) => (current === message ? null : current)), 2600);
  }, []);

  useEffect(() => subscribeSettingsTheme(), []);

  useEffect(() => {
    void getWelcomeState()
      .then((st) => {
        setState(st);
        setSteps(st.steps);
      })
      .catch(() => undefined);
    // Steps tried elsewhere (Command Bar, menus) show up on return.
    const onVisible = () => {
      setHidden(document.hidden);
      if (!document.hidden) {
        void getWelcomeState()
          .then((st) => setSteps(st.steps))
          .catch(() => undefined);
      }
    };
    document.addEventListener('visibilitychange', onVisible);
    const onHash = () => {
      if (currentPageRoute().segments[0] === 'shortcuts') setSheetOpen(true);
    };
    window.addEventListener('hashchange', onHash);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('hashchange', onHash);
    };
  }, []);

  // "?" opens the sheet (outside text fields).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (e.key === '?' && tag !== 'INPUT' && tag !== 'TEXTAREA' && !sheetOpen) {
        e.preventDefault();
        setSheetOpen(true);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [sheetOpen]);

  // Each demo plays once when its card scrolls into view.
  useEffect(() => {
    if (reduceMotion || typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const id = (entry.target as HTMLElement).dataset.demo as DemoId | undefined;
          if (!id) continue;
          observer.unobserve(entry.target);
          window.setTimeout(() => setPlaying((prev) => new Set(prev).add(id)), 700);
        }
      },
      { threshold: 0.55 },
    );
    for (const el of cardRefs.current.values()) observer.observe(el);
    return () => observer.disconnect();
  }, [reduceMotion, replayKey]);

  const replay = (id: DemoId) => {
    setPlaying((prev) => {
      const next = new Set(prev);
      next.delete(id);
      return next;
    });
    window.requestAnimationFrame(() =>
      window.requestAnimationFrame(() => setPlaying((prev) => new Set(prev).add(id))),
    );
  };

  const replayAll = () => {
    setPlaying(new Set());
    setReplayKey((k) => k + 1);
    window.scrollTo({ top: 0, behavior: reduceMotion ? 'auto' : 'smooth' });
    // Replay All only restarts the demos; setup is never reopened.
    void triggerWelcomeAction('replay_all').catch(() => undefined);
  };

  const runAction = async (action: string) => {
    if (action === 'shortcuts') {
      setSheetOpen(true);
      return;
    }
    setBusy(action);
    try {
      const res = await triggerWelcomeAction(action);
      if (res.steps) setSteps(res.steps);
      if (!res.ok && res.message) showToast(res.message);
      else if (!isNativeWebUI() && res.message) showToast(res.message);
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'That did not work. Try again.');
    } finally {
      setBusy(null);
    }
  };

  const toggleStep = async (step: WelcomeStep) => {
    const optimistic = steps.map((s) => (s.id === step.id ? { ...s, done: !s.done } : s));
    setSteps(optimistic);
    try {
      setSteps(await markWelcomeStep(step.id, !step.done));
    } catch {
      setSteps(steps);
    }
  };

  const closeSheet = useCallback(() => {
    setSheetOpen(false);
    const route = currentPageRoute().segments[0];
    if (route === 'shortcuts' || route === 'help') replacePageRoute('');
  }, []);

  const platform: ShortcutPlatform = state?.platform ?? 'mac';
  const shortcuts = state?.shortcuts ?? [];
  const keysFor = (id?: string): string => (id ? (shortcuts.find((s) => s.id === id)?.keys ?? '') : '');
  const tint = state?.space.style ? rgbaToHex(state.space.style.key_color) : '#3139ff';
  const doneCount = steps.filter((s) => s.done).length;
  const total = steps.length || 7;
  const name = state?.user_name.trim() ?? '';
  const stepDone = (id: string) => steps.some((s) => s.id === id && s.done);

  return (
    <Room tint={tint} class={`wel${reduceMotion ? ' is-reduced' : ''}${hidden ? ' is-hidden' : ''}`}>
      <div class="wel-scroll">
        <header class="wel-top">
          <button type="button" class="wel-btn wel-btn-glass" onClick={() => setSheetOpen(true)}>
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
              <rect x="1.5" y="3" width="11" height="8" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.2" />
              <path d="M4 6h1M6.5 6h1M9 6h1M4.5 8.5h5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
            </svg>
            Essential Shortcuts
          </button>
          <button type="button" class="wel-btn wel-btn-glass" onClick={() => void runAction('settings')}>
            Settings
          </button>
        </header>

        <section class="wel-hero">
          <div class="wel-hero-text">
            <h1 class="wel-heading">
              <span>You’re all set{name ? `, ${name}` : ''}.</span>
              <span class="wel-heading-soft">Here are the basics.</span>
            </h1>
            <p class="wel-lede">Six things that make Open feel like yours. Try each one; this page keeps track.</p>
            <div class="wel-progress" aria-label={`${doneCount} of ${total} tried`}>
              <svg width="36" height="36" viewBox="0 0 36 36" aria-hidden="true">
                <circle cx="18" cy="18" r="15" fill="none" stroke="rgba(255,255,255,0.14)" stroke-width="3" />
                <circle
                  cx="18"
                  cy="18"
                  r="15"
                  fill="none"
                  stroke="#ffc982"
                  stroke-width="3"
                  stroke-linecap="round"
                  stroke-dasharray={`${(doneCount / total) * 94.25} 94.25`}
                  transform="rotate(-90 18 18)"
                  class="wel-progress-arc"
                />
              </svg>
              <span>
                <strong>
                  {doneCount} of {total}
                </strong>{' '}
                tried
              </span>
            </div>
          </div>
          <div class="wel-hero-door" aria-hidden="true">
            <DoorwayArch height={150} />
          </div>
        </section>

        <div class="wel-layout">
          <section class="wel-cards" aria-label="The basics">
            {CARDS.map((card, i) => {
              const keys = keysFor(card.shortcutId);
              const done = stepDone(card.step);
              return (
                <article
                  key={`${card.id}-${replayKey}`}
                  class={`wel-card${done ? ' is-done' : ''}`}
                  style={{ '--i': i }}
                  data-demo={card.id}
                  ref={(el) => {
                    if (el) cardRefs.current.set(card.id, el);
                    else cardRefs.current.delete(card.id);
                  }}
                  onMouseEnter={() => {
                    if (!reduceMotion && playing.has(card.id)) replay(card.id);
                  }}
                >
                  <div class="wel-card-demo">
                    <FeatureDemo
                      id={card.id}
                      tint={tint}
                      playing={reduceMotion || playing.has(card.id)}
                      platform={platform}
                    />
                    <button
                      type="button"
                      class="wel-replay"
                      aria-label={`Replay the ${card.title} demo`}
                      onClick={() => replay(card.id)}
                    >
                      <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
                        <path d="M2.2 6a3.8 3.8 0 106.7-2.4M9.2 1.6v2.3H6.9" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
                      </svg>
                    </button>
                  </div>
                  <div class="wel-card-body">
                    <div class="wel-card-title">
                      <CheckBadge done={done} />
                      <h2>{card.title}</h2>
                    </div>
                    <p>{card.body}</p>
                    <div class="wel-card-keys">
                      {card.literalKeys && (
                        <Keycaps
                          keys={platform === 'mac' ? card.literalKeys.mac : card.literalKeys.other}
                          platform={platform}
                        />
                      )}
                      {keys && <Keycaps keys={keys} platform={platform} label={`${card.title} shortcut`} />}
                    </div>
                    <div class="wel-card-actions">
                      <button
                        type="button"
                        class="wel-btn wel-btn-primary"
                        disabled={busy === card.action}
                        onClick={() => void runAction(card.action)}
                      >
                        {card.actionLabel}
                      </button>
                      {card.secondary && (
                        <button
                          type="button"
                          class="wel-btn wel-btn-glass"
                          disabled={busy === card.secondary.action}
                          onClick={() => void runAction(card.secondary!.action)}
                        >
                          {card.secondary.label}
                        </button>
                      )}
                    </div>
                  </div>
                </article>
              );
            })}
          </section>

          <aside class="wel-side">
            <section class="wel-panel" aria-label="First steps">
              <h2>First steps</h2>
              <ul class="wel-steps">
                {steps.map((step) => (
                  <li key={step.id} class={step.done ? 'is-done' : ''}>
                    <button
                      type="button"
                      class="wel-step-check"
                      role="checkbox"
                      aria-checked={step.done}
                      aria-label={`${step.title}: ${step.done ? 'done' : 'not done'}`}
                      onClick={() => void toggleStep(step)}
                    >
                      <CheckBadge done={step.done} />
                    </button>
                    <span class="wel-step-title">{step.title}</span>
                    {!step.done && (
                      <button
                        type="button"
                        class="wel-link"
                        disabled={busy === step.action}
                        onClick={() => void runAction(step.action)}
                      >
                        Try
                      </button>
                    )}
                  </li>
                ))}
              </ul>
            </section>
            <section class="wel-panel" aria-label="More">
              <h2>More</h2>
              <div class="wel-more">
                <button type="button" class="wel-more-row" onClick={() => void runAction('import-from-browser')}>
                  Import from another browser
                </button>
                <button type="button" class="wel-more-row" onClick={() => void runAction('customize-shortcuts')}>
                  Customize shortcuts
                </button>
                <button type="button" class="wel-more-row" onClick={() => void runAction('boost-gallery')}>
                  Boost gallery
                </button>
                <button type="button" class="wel-more-row" onClick={replayAll}>
                  Replay all demos
                </button>
                <button type="button" class="wel-more-row" onClick={() => void runAction('replay-onboarding')}>
                  See the welcome tour again
                </button>
              </div>
            </section>
          </aside>
        </div>
      </div>

      {sheetOpen && (
        <ShortcutsSheet
          shortcuts={shortcuts}
          platform={platform}
          onClose={closeSheet}
          onAction={(action) => void runAction(action)}
        />
      )}
      {toast && (
        <div class="wel-toast" role="status">
          {toast}
        </div>
      )}
    </Room>
  );
}
