// Boost calls beyond shared/bridge.ts (C++: open_boosts_ui.{h,cc}) and the
// Boost share-card format (.json export/import).

import { type Boost, isNativeWebUI, rpc } from '../shared/bridge';

type RawRpc = (method: string, payload?: unknown) => Promise<unknown>;
const rawRpc = rpc as unknown as RawRpc;

export const BOOSTS_EDIT_ON_SITE = 'boosts.editOnSite' as const;

export interface EditOnSiteResult {
  ok: boolean;
  tab_id?: string;
  opened_new_tab?: boolean;
  zap_armed?: boolean;
  message: string;
}

/** Selects or opens the Boost's site and asks for the floating editor there. */
export async function editOnSite(boost: Boost, zap = false): Promise<EditOnSiteResult> {
  if (!isNativeWebUI()) {
    return {
      ok: true,
      opened_new_tab: true,
      message: `Preview: would open ${boost.host_pattern} with the floating Boost editor.`,
    };
  }
  const raw = (await rawRpc(BOOSTS_EDIT_ON_SITE, {
    id: boost.id,
    profile_id: boost.profile_id,
    zap,
  })) as Record<string, unknown>;
  return {
    ok: raw.ok !== false,
    tab_id: typeof raw.tab_id === 'string' ? raw.tab_id : undefined,
    opened_new_tab: raw.opened_new_tab === true,
    zap_armed: raw.zap_armed === true,
    message: typeof raw.message === 'string' ? raw.message : '',
  };
}

// --- Share cards ----------------------------------------------------------------

export const SHARE_FORMAT = 'open-boost';
export const SHARE_VERSION = 1;

export interface BoostShareCard {
  format: typeof SHARE_FORMAT;
  version: number;
  exported_at: string;
  boost: Pick<
    Boost,
    | 'name'
    | 'host_pattern'
    | 'color'
    | 'font_family'
    | 'text_zoom'
    | 'text_transform'
    | 'custom_css'
    | 'custom_js'
    | 'zapped_elements'
  >;
}

export function toShareCard(boost: Boost): BoostShareCard {
  return {
    format: SHARE_FORMAT,
    version: SHARE_VERSION,
    exported_at: new Date().toISOString(),
    boost: {
      name: boost.name,
      host_pattern: boost.host_pattern,
      color: { ...boost.color },
      font_family: boost.font_family ?? '',
      text_zoom: boost.text_zoom,
      text_transform: boost.text_transform,
      custom_css: boost.custom_css,
      custom_js: boost.custom_js,
      zapped_elements: boost.zapped_elements.map((z) => ({ ...z })),
    },
  };
}

export function shareFileName(boost: Boost): string {
  const slug = `${boost.name || boost.host_pattern}`
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
  return `${slug || 'boost'}.open-boost.json`;
}

/** Saves |card| as a file (the browser's download flow). */
export function downloadShareCard(boost: Boost): void {
  const blob = new Blob([JSON.stringify(toShareCard(boost), null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = shareFileName(boost);
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 4000);
}

function clamp(v: unknown, min: number, max: number, fallback: number): number {
  return typeof v === 'number' && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback;
}
function text(v: unknown, max: number): string {
  return typeof v === 'string' ? v.slice(0, max) : '';
}

/**
 * Parses a share card (ours, or a bare Boost object). Throws with a short
 * reason for anything else. Values are clamped like the C++ validation.
 */
export function parseShareCard(json: string): BoostShareCard['boost'] {
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    throw new Error('That file is not a Boost (it is not JSON).');
  }
  const obj = (raw && typeof raw === 'object' ? raw : null) as Record<string, unknown> | null;
  const b = (obj && obj.format === SHARE_FORMAT ? obj.boost : obj) as Record<string, unknown> | null;
  if (!b || typeof b !== 'object' || typeof b.host_pattern !== 'string' || !b.host_pattern.trim()) {
    throw new Error('That file is not a Boost (no site in it).');
  }
  const color = (b.color && typeof b.color === 'object' ? b.color : {}) as Record<string, unknown>;
  const transform = text(b.text_transform, 16);
  const zaps = Array.isArray(b.zapped_elements) ? b.zapped_elements : [];
  return {
    name: text(b.name, 80) || `${b.host_pattern} Boost`,
    host_pattern: text(b.host_pattern, 253).trim().toLowerCase(),
    color: {
      enabled: color.enabled === true,
      hue_degrees: clamp(color.hue_degrees, -180, 180, 0),
      saturation: clamp(color.saturation, 0, 2, 1),
      lightness: clamp(color.lightness, -0.5, 0.5, 0),
      contrast: clamp(color.contrast, 0.5, 2, 1),
      invert: color.invert === true,
    },
    font_family: text(b.font_family, 120),
    text_zoom: clamp(b.text_zoom, 0.5, 2, 1),
    text_transform: (['', 'uppercase', 'lowercase', 'capitalize'] as const).includes(
      transform as Boost['text_transform'],
    )
      ? (transform as Boost['text_transform'])
      : '',
    custom_css: text(b.custom_css, 200_000),
    custom_js: text(b.custom_js, 200_000),
    zapped_elements: zaps.flatMap((z, i) => {
      if (!z || typeof z !== 'object') return [];
      const r = z as Record<string, unknown>;
      const selector = text(r.selector, 2000);
      if (!selector) return [];
      return [{ id: text(r.id, 64) || `zap-${i}`, selector, label: text(r.label, 120) || selector }];
    }),
  };
}
