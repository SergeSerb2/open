// First-run suggestions: the Favorites grid and the Space theme palette.
// Hosts are canonical (no cross-site redirects), so the favicon prefetch and
// the Favorites hand-off use the same URL.

import type { ImportKind } from './rpc';

export interface FavoriteSite {
  id: string;
  name: string;
  url: string;
  monogram: string;
  /** Monogram plate colour; omitted ones use the OKLCH name hash. */
  color?: string;
  selected?: boolean;
}

export const FAVORITE_SITES: readonly FavoriteSite[] = [
  { id: 'gmail', name: 'Gmail', url: 'https://mail.google.com/', monogram: 'Gm', selected: true },
  { id: 'calendar', name: 'Calendar', url: 'https://calendar.google.com/', monogram: 'Ca', selected: true },
  { id: 'github', name: 'GitHub', url: 'https://github.com/', monogram: 'GH', color: '#3A3E47', selected: true },
  { id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/', monogram: 'YT' },
  { id: 'notion', name: 'Notion', url: 'https://www.notion.com/', monogram: 'N' },
  { id: 'x', name: 'X', url: 'https://x.com/', monogram: 'X', color: '#26272d' },
  { id: 'slack', name: 'Slack', url: 'https://app.slack.com/', monogram: 'Sl' },
  { id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/', monogram: 'Ch' },
  { id: 'spotify', name: 'Spotify', url: 'https://open.spotify.com/', monogram: 'Sp' },
  { id: 'linear', name: 'Linear', url: 'https://linear.app/', monogram: 'Li' },
  { id: 'figma', name: 'Figma', url: 'https://www.figma.com/', monogram: 'Fi' },
  { id: 'reddit', name: 'Reddit', url: 'https://www.reddit.com/', monogram: 'R' },
  { id: 'hn', name: 'Hacker News', url: 'https://news.ycombinator.com/', monogram: 'HN' },
  { id: 'maps', name: 'Google Maps', url: 'https://maps.google.com/', monogram: 'Ma' },
  { id: 'whatsapp', name: 'WhatsApp', url: 'https://web.whatsapp.com/', monogram: 'Wa' },
  { id: 'wikipedia', name: 'Wikipedia', url: 'https://en.wikipedia.org/', monogram: 'W' },
];

export const MAX_FAVORITES = 12;

/** Key colours for the Space theme swatches (Open indigo first). */
export const THEME_SWATCHES: readonly { name: string; hex: string }[] = [
  { name: 'Indigo', hex: '#3139FF' },
  { name: 'Dusk', hex: '#6D4AFF' },
  { name: 'Orchid', hex: '#B84FD8' },
  { name: 'Rose', hex: '#E0457B' },
  { name: 'Ember', hex: '#F0643C' },
  { name: 'Sunrise', hex: '#F29A38' },
  { name: 'Honey', hex: '#E7C24A' },
  { name: 'Fern', hex: '#3FA56B' },
  { name: 'Lagoon', hex: '#14A3A3' },
  { name: 'Sky', hex: '#3B8BEB' },
  { name: 'Slate', hex: '#5B6478' },
  { name: 'Sand', hex: '#C9B79C' },
];

/** What the import step offers, per kind. */
export const IMPORT_KIND_LABELS: Record<ImportKind, { label: string; hint: string }> = {
  spaces: { label: 'Spaces & Tabs', hint: 'Spaces, pinned tabs, folders and splits' },
  favorites: { label: 'Favorites', hint: 'The icons at the top of your sidebar' },
  bookmarks: { label: 'Bookmarks', hint: 'Kept as one pinned folder, nested folders included' },
  history: { label: 'History', hint: 'Pages you visited, for the Command Bar' },
  boosts: { label: 'Boosts', hint: 'Your site styles and Zaps' },
  documents: { label: 'Easels & Notes', hint: 'Canvases and notes with their images' },
  archive: { label: 'Archive', hint: 'Tabs that were archived' },
  preferences: { label: 'Settings', hint: 'App preferences that carry over' },
};

/** Kinds turned on by default when a source is chosen. */
export const DEFAULT_IMPORT_KINDS: readonly ImportKind[] = [
  'spaces',
  'favorites',
  'bookmarks',
  'history',
  'boosts',
  'documents',
];

/** "Mail" for https://mail.google.com/x, used for custom Favorites. */
export function siteNameFromUrl(url: string): string {
  try {
    const host = new URL(url).hostname.replace(/^www\./, '');
    const parts = host.split('.');
    const core = parts.length > 2 ? parts[parts.length - 2]! : parts[0]!;
    return core.charAt(0).toUpperCase() + core.slice(1);
  } catch {
    return url;
  }
}

/** A typed address as an http(s) URL, or null. Adds https:// when missing. */
export function normalizeTypedUrl(raw: string): string | null {
  const text = raw.trim();
  if (!text || /\s/.test(text)) return null;
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text) ? text : `https://${text}`;
  try {
    const url = new URL(withScheme);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    if (!url.hostname.includes('.') && url.hostname !== 'localhost') return null;
    return url.toString();
  } catch {
    return null;
  }
}

/** host + path without www. or a trailing slash (same key as the C++ dedupe). */
export function favoriteKey(url: string): string {
  try {
    const u = new URL(url);
    const host = u.hostname.replace(/^www\./, '');
    const path = u.pathname.replace(/\/+$/, '') || '/';
    return `${host}${path}`;
  } catch {
    return url;
  }
}
