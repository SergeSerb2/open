// Open's own first-run art: the doorway-and-sun emblem, the night room it
// stands in, a miniature Open window, and site icons. All drawn here (inline
// SVG + CSS); no external or reference-app assets. Shared by open://onboarding
// and open://welcome.

import type { ComponentChildren, JSX } from 'preact';
import { useMemo } from 'preact/hooks';
import type { SpaceStyle } from '../shared/bridge';
import { computeSpaceGradientCss, isLightSpaceStyle } from '../shared/components';

let gradientSeq = 0;
function useIds(prefix: string): (name: string) => string {
  // Stable per element instance: SVG gradient ids must be unique per page.
  const n = useMemo(() => ++gradientSeq, []);
  return (name) => `${prefix}-${name}-${n}`;
}

// --- Doorway ------------------------------------------------------------------

export interface DoorwayProps {
  /** Rendered height in px; width follows the 3:4 arch. */
  height?: number;
  class?: string;
  /** Sun glow strength 0..1 (the intro animates it with CSS). */
  glow?: number;
  title?: string;
}

/** The arch: warm peach light, white edge, a sun disc high on the right. */
export function DoorwayArch({ height = 160, class: className, glow = 1, title = 'Open' }: DoorwayProps): JSX.Element {
  const id = useIds('door');
  const width = Math.round((height * 3) / 4);
  return (
    <svg
      class={className}
      width={width}
      height={height}
      viewBox="0 0 120 160"
      role="img"
      aria-label={title}
    >
      <defs>
        <linearGradient id={id('fill')} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#FFF1CF" />
          <stop offset="38%" stop-color="#FFC982" />
          <stop offset="100%" stop-color="#F08A4B" />
        </linearGradient>
        <linearGradient id={id('inner')} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.55" />
          <stop offset="60%" stop-color="#FFE2B0" stop-opacity="0" />
        </linearGradient>
        <radialGradient id={id('halo')} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0%" stop-color="#FFFBEA" stop-opacity={0.95 * glow} />
          <stop offset="55%" stop-color="#FFD58A" stop-opacity={0.45 * glow} />
          <stop offset="100%" stop-color="#FFB15E" stop-opacity="0" />
        </radialGradient>
      </defs>
      <path
        d="M8 156V62C8 31.072 31.072 6 60 6C88.928 6 112 31.072 112 62V156H8Z"
        fill={`url(#${id('fill')})`}
      />
      <path
        d="M14 152V63C14 35.386 34.6 12 60 12C85.4 12 106 35.386 106 63V152H14Z"
        fill={`url(#${id('inner')})`}
      />
      <circle class="door-sun-halo" cx="80" cy="48" r="26" fill={`url(#${id('halo')})`} />
      <circle class="door-sun" cx="80" cy="48" r="9.5" fill="#FFF8E4" />
      <path
        d="M8 156V62C8 31.072 31.072 6 60 6C88.928 6 112 31.072 112 62V156"
        fill="none"
        stroke="#FFFFFF"
        stroke-width="4.5"
        stroke-linejoin="round"
      />
    </svg>
  );
}

/** Small square emblem (tabs, Ready card, Welcome hero). */
export function DoorwayEmblem({ size = 32, class: className }: { size?: number; class?: string }): JSX.Element {
  const id = useIds('emblem');
  return (
    <svg class={className} width={size} height={size} viewBox="0 0 32 32" role="img" aria-label="Open">
      <defs>
        <linearGradient id={id('fill')} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#FFF1CF" />
          <stop offset="45%" stop-color="#FFC982" />
          <stop offset="100%" stop-color="#F08A4B" />
        </linearGradient>
      </defs>
      <path d="M7 30V14.5C7 9.253 11.03 5 16 5C20.97 5 25 9.253 25 14.5V30H7Z" fill={`url(#${id('fill')})`} />
      <path
        d="M7 30V14.5C7 9.253 11.03 5 16 5C20.97 5 25 9.253 25 14.5V30"
        fill="none"
        stroke="#FFFFFF"
        stroke-width="1.6"
      />
      <circle cx="19.6" cy="12.2" r="2.4" fill="#FFF8E4" />
    </svg>
  );
}

// --- Room ------------------------------------------------------------------------

/**
 * The night room: a Space-tinted far wall, horizon, the doorway's floor
 * spill and three slow orbs. Children render above it.
 */
export function Room({
  tint,
  children,
  class: className,
}: {
  tint?: string;
  children?: ComponentChildren;
  class?: string;
}): JSX.Element {
  return (
    <div class={`room ${className ?? ''}`.trim()} style={tint ? { '--room-tint': tint } : undefined}>
      <div class="room-wall" aria-hidden="true" />
      <div class="room-orb room-orb-blue" aria-hidden="true" />
      <div class="room-orb room-orb-purple" aria-hidden="true" />
      <div class="room-orb room-orb-warm" aria-hidden="true" />
      <div class="room-floor" aria-hidden="true" />
      <div class="room-grain" aria-hidden="true" />
      {children}
    </div>
  );
}

// --- Landscape (the miniature page's picture) ----------------------------------------

export function Landscape({ class: className }: { class?: string }): JSX.Element {
  const id = useIds('land');
  return (
    <svg class={className} viewBox="0 0 320 120" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
      <defs>
        <linearGradient id={id('sky')} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#FFD9A8" />
          <stop offset="55%" stop-color="#F7A6A0" />
          <stop offset="100%" stop-color="#B98CE0" />
        </linearGradient>
      </defs>
      <rect width="320" height="120" fill={`url(#${id('sky')})`} />
      <circle cx="238" cy="44" r="17" fill="#FFF6E3" opacity="0.95" />
      <path d="M0 92C46 70 84 76 128 86C176 97 214 72 262 70C290 69 306 76 320 82V120H0Z" fill="#E98FA4" opacity="0.75" />
      <path d="M0 104C58 88 110 96 160 102C214 108 262 92 320 96V120H0Z" fill="#C677B8" opacity="0.8" />
    </svg>
  );
}

// --- Site icon ----------------------------------------------------------------------

/** OKLCH monogram hue from a stable site-name hash (L 0.545, C 0.11). */
export function monogramColor(name: string, override?: string): string {
  if (override) return override;
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) {
    h ^= name.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const hues = [18, 48, 95, 145, 190, 235, 275, 320];
  return `oklch(0.545 0.11 ${hues[(h >>> 0) % hues.length]})`;
}

export function SiteIcon({
  name,
  monogram,
  icon,
  color,
  size = 32,
  class: className,
}: {
  name: string;
  monogram: string;
  icon?: string | undefined;
  color?: string | undefined;
  size?: number;
  class?: string;
}): JSX.Element {
  return (
    <span
      class={`site-icon${icon ? ' has-icon' : ''} ${className ?? ''}`.trim()}
      style={{ width: `${size}px`, height: `${size}px`, '--mono': monogramColor(name, color) }}
      aria-hidden="true"
    >
      <span class="site-icon-mono" style={{ fontSize: `${monogram.length > 1 ? size * 0.34 : size * 0.47}px` }}>
        {monogram}
      </span>
      {icon && <img class="site-icon-img" src={icon} alt="" draggable={false} />}
    </span>
  );
}

// --- Miniature Open window -------------------------------------------------------------

export interface MiniFavorite {
  id: string;
  name: string;
  monogram: string;
  icon?: string | undefined;
  color?: string | undefined;
}

export function MiniBrowser({
  style,
  spaceTitle,
  favorites,
  todayRows,
  children,
  class: className,
  'aria-hidden': ariaHidden,
}: {
  'aria-hidden'?: boolean;
  style: SpaceStyle;
  spaceTitle: string;
  favorites: readonly MiniFavorite[];
  todayRows: readonly { title: string; active?: boolean; highlight?: boolean }[];
  children?: ComponentChildren;
  class?: string;
}): JSX.Element {
  const light = isLightSpaceStyle(style);
  return (
    <div class={`mini ${className ?? ''}`.trim()} aria-hidden={ariaHidden ? 'true' : undefined}>
      <div
        class={`mini-sidebar${light ? ' is-light' : ' is-dark'}`}
        style={{ background: computeSpaceGradientCss(style) }}
      >
        <div class="mini-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div class="mini-url">open://welcome</div>
        <div class="mini-favs">
          {favorites.slice(0, 8).map((f) => (
            <div key={f.id} class="mini-fav" title={f.name}>
              <SiteIcon name={f.name} monogram={f.monogram} icon={f.icon} color={f.color} size={15} />
            </div>
          ))}
          {favorites.length === 0 && <div class="mini-fav is-empty" />}
        </div>
        <div class="mini-space">
          <DoorwayEmblem size={11} />
          <span>{spaceTitle}</span>
        </div>
        <div class="mini-divider" />
        <div class="mini-row is-new">+ New Tab</div>
        {todayRows.map((row) => (
          <div
            key={row.title}
            class={`mini-row${row.active ? ' is-active' : ''}${row.highlight ? ' is-highlight' : ''}`}
          >
            {row.title}
          </div>
        ))}
      </div>
      <div class="mini-page">{children}</div>
    </div>
  );
}
