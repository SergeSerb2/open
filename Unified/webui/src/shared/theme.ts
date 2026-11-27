// Shared explicit light/dark theme synchronization across WebUI pages.
// Pages hosted with OpenSettingsUI (settings, boosts, welcome, onboarding)
// query settings.getTheme and listen for open.stateChanged.
// Pages hosted with OpenDocumentsUI only (note, easel) never call unregistered
// settings.* RPCs on native WebUI; they honor ?theme= overrides and Chromium's
// live prefers-color-scheme updates (driven by ThemeService).

import { isNativeWebUI, RPC_EVENTS, type SettingsTheme, rpc, subscribeEvent } from './bridge';

export function applyThemePreference(preference: string | null | undefined): void {
  const root = document.documentElement;
  if (preference === 'light' || preference === 'dark') {
    root.dataset.theme = preference;
    root.style.colorScheme = preference;
    root.style.setProperty('--open-theme-mode', preference);
    return;
  }
  delete root.dataset.theme;
  root.style.removeProperty('color-scheme');
  const dark = window.matchMedia?.('(prefers-color-scheme: dark)').matches === true;
  root.style.setProperty('--open-theme-mode', dark ? 'dark' : 'light');
}

export function applySettingsTheme(theme: SettingsTheme | null | undefined): void {
  if (!theme) return;
  const root = document.documentElement;
  if (theme.accent) root.style.setProperty('--open-space-accent', theme.accent);
  if (theme.accent_hover) root.style.setProperty('--open-space-accent-hover', theme.accent_hover);
  if (theme.accent_soft) root.style.setProperty('--open-space-accent-soft', theme.accent_soft);
  if (theme.on_accent) root.style.setProperty('--open-space-on-accent', theme.on_accent);
  if (theme.space_bg) root.style.setProperty('--open-space-bg', theme.space_bg);
  applyThemePreference(theme.preference);
  if (theme.mode === 'light' || theme.mode === 'dark') {
    root.style.setProperty('--open-theme-mode', theme.mode);
  }
}

function queryThemeOverride(): 'light' | 'dark' | null {
  if (typeof window === 'undefined') return null;
  const params = new URLSearchParams(window.location.search);
  const raw = params.get('theme') ?? params.get('theme_mode');
  return raw === 'light' || raw === 'dark' ? raw : null;
}

/**
 * Syncs `data-theme` and Space accent vars on pages whose WebUI host registers
 * OpenSettingsUI (`open://boosts`, `open://welcome`, `open://onboarding`).
 */
export function subscribeSettingsTheme(): () => void {
  const override = queryThemeOverride();
  if (override) {
    applyThemePreference(override);
    return () => {};
  }

  let active = true;
  let timer = 0;

  const refresh = () => {
    void rpc('settings.getTheme', {})
      .then((theme) => {
        if (active) applySettingsTheme(theme);
      })
      .catch(() => undefined);
  };

  refresh();

  const off = subscribeEvent(RPC_EVENTS.stateChanged, () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(refresh, 180);
  });

  const media = window.matchMedia?.('(prefers-color-scheme: dark)');
  const onScheme = () => refresh();
  media?.addEventListener?.('change', onScheme);

  return () => {
    active = false;
    off();
    window.clearTimeout(timer);
    media?.removeEventListener?.('change', onScheme);
  };
}

/**
 * Syncs `data-theme` on document pages (`open://note`, `open://easel`) whose
 * WebUI host registers only OpenDocumentsUI (so never sends unregistered
 * `settings.*` RPCs on native WebUI).
 */
export function subscribeDocumentTheme(): () => void {
  const override = queryThemeOverride();
  if (override) {
    applyThemePreference(override);
    return () => {};
  }

  if (!isNativeWebUI()) {
    return subscribeSettingsTheme();
  }

  const syncSystem = () => applyThemePreference(null);
  syncSystem();

  const media = window.matchMedia?.('(prefers-color-scheme: dark)');
  media?.addEventListener?.('change', syncSystem);

  const off = subscribeEvent(RPC_EVENTS.stateChanged, (payload) => {
    if (payload && typeof payload === 'object') {
      const rec = payload as Record<string, unknown>;
      const pref =
        typeof rec.websiteAppearance === 'string'
          ? rec.websiteAppearance
          : typeof rec.theme_preference === 'string'
            ? rec.theme_preference
            : typeof rec.theme === 'string'
              ? rec.theme
              : null;
      if (pref === 'light' || pref === 'dark' || pref === 'automatic') {
        applyThemePreference(pref);
      }
    }
  });

  return () => {
    off();
    media?.removeEventListener?.('change', syncSystem);
  };
}
