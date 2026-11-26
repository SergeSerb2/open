// Space tint of the Library drawer: --open-space-{bg,fg,accent,surface} and
// --open-theme-mode on <html>. Sources, later wins: URL query (?bg=&fg=
// &accent=&surface=&mode=, set by the host when it opens the drawer),
// library.theme.get, and library.setSpaceTheme push events.

import type { SpaceThemeVars } from './types';

const COLOR = /^(#[0-9a-f]{3,8}|rgba?\(\s*[\d.]+%?\s*,?\s*[\d.]+%?\s*,?\s*[\d.]+%?\s*([,/]\s*[\d.]+%?\s*)?\))$/i;

function safeColor(value: unknown): string | null {
  return typeof value === 'string' && value.length < 64 && COLOR.test(value.trim()) ? value.trim() : null;
}

/** Validated theme fields from an untrusted object (query, event payload). */
export function parseTheme(raw: unknown): Partial<SpaceThemeVars> {
  if (!raw || typeof raw !== 'object') return {};
  const r = raw as Record<string, unknown>;
  const out: Partial<SpaceThemeVars> = {};
  const bg = safeColor(r.bg);
  const fg = safeColor(r.fg);
  const accent = safeColor(r.accent);
  const surface = safeColor(r.surface);
  if (bg) out.bg = bg;
  if (fg) out.fg = fg;
  if (accent) out.accent = accent;
  if (surface) out.surface = surface;
  if (r.mode === 'light' || r.mode === 'dark') out.mode = r.mode;
  if (typeof r.space_id === 'string') out.space_id = r.space_id;
  return out;
}

export function themeFromQuery(search: string = window.location.search): Partial<SpaceThemeVars> {
  const params = new URLSearchParams(search);
  const raw: Record<string, string> = {};
  for (const key of ['bg', 'fg', 'accent', 'surface', 'mode']) {
    const v = params.get(key);
    if (v) raw[key] = v;
  }
  return parseTheme(raw);
}

export function applyTheme(theme: Partial<SpaceThemeVars>): void {
  const root = document.documentElement;
  const set = (name: string, value: string | undefined) => {
    if (value) root.style.setProperty(name, value);
  };
  set('--open-space-bg', theme.bg);
  set('--open-space-fg', theme.fg);
  set('--open-space-accent', theme.accent);
  set('--open-space-surface', theme.surface);
  if (theme.mode) {
    root.style.setProperty('--open-theme-mode', theme.mode);
    // Shared tokens (modals, toasts) follow the Space's appearance.
    root.dataset.theme = theme.mode;
    root.style.colorScheme = theme.mode;
  }
}
