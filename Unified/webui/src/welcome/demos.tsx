// Feature mini-demos for open://welcome: small animated drawings of a real
// Open window (sidebar + page). Each plays once when its card is revealed
// (or on hover / Replay) and then holds its end state, so an idle Welcome
// tab runs no animation. Drawn here; no recorded clips or external assets.

import type { JSX } from 'preact';

export type DemoId = 'command-bar' | 'sidebar' | 'spaces' | 'peek-split' | 'boosts' | 'library';

interface DemoProps {
  tint: string;
}

function Frame({ tint, children, sidebar = true }: DemoProps & { children?: JSX.Element | JSX.Element[]; sidebar?: boolean }): JSX.Element {
  return (
    <>
      <rect x="0" y="0" width="320" height="200" rx="14" fill="rgba(255,255,255,0.06)" />
      {sidebar && (
        <g class="demo-side">
          <rect x="8" y="8" width="84" height="184" rx="9" fill={tint} opacity="0.9" />
          <circle cx="19" cy="19" r="2.6" fill="#ff5f57" />
          <circle cx="27" cy="19" r="2.6" fill="#febc2e" />
          <circle cx="35" cy="19" r="2.6" fill="rgba(255,255,255,0.5)" />
          <rect x="15" y="30" width="70" height="11" rx="4" fill="rgba(255,255,255,0.2)" />
          <rect x="15" y="48" width="15" height="13" rx="3.5" fill="rgba(255,255,255,0.26)" />
          <rect x="33" y="48" width="15" height="13" rx="3.5" fill="rgba(255,255,255,0.26)" />
          <rect x="51" y="48" width="15" height="13" rx="3.5" fill="rgba(255,255,255,0.26)" />
          <rect x="69" y="48" width="15" height="13" rx="3.5" fill="rgba(255,255,255,0.26)" />
          <rect x="15" y="74" width="70" height="1" fill="rgba(255,255,255,0.25)" />
          <rect x="15" y="82" width="70" height="10" rx="4" fill="rgba(255,255,255,0.32)" />
          <rect x="15" y="97" width="56" height="7" rx="3" fill="rgba(255,255,255,0.2)" />
          <rect x="15" y="110" width="62" height="7" rx="3" fill="rgba(255,255,255,0.2)" />
          <rect x="15" y="123" width="44" height="7" rx="3" fill="rgba(255,255,255,0.2)" />
        </g>
      )}
      {children}
    </>
  );
}

function Page({ x = 98, width = 214 }: { x?: number; width?: number }): JSX.Element {
  return (
    <g class="demo-page">
      <rect x={x} y="8" width={width} height="184" rx="9" fill="#fbfaf8" />
      <rect x={x + 14} y="22" width={width * 0.42} height="8" rx="3" fill="#20212b" opacity="0.85" />
      <rect x={x + 14} y="38" width={width - 28} height="58" rx="7" fill="url(#demo-sky)" />
      <circle cx={x + width - 44} cy="58" r="9" fill="#fff6e3" />
      <rect x={x + 14} y="106" width={width * 0.62} height="6" rx="3" fill="#20212b" opacity="0.6" />
      <rect x={x + 14} y="118" width={width - 40} height="5" rx="2.5" fill="#20212b" opacity="0.25" />
      <rect x={x + 14} y="128" width={width - 60} height="5" rx="2.5" fill="#20212b" opacity="0.25" />
      <rect x={x + 14} y="138" width={width - 50} height="5" rx="2.5" fill="#20212b" opacity="0.25" />
    </g>
  );
}

function Defs(): JSX.Element {
  return (
    <defs>
      <linearGradient id="demo-sky" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0%" stop-color="#ffd9a8" />
        <stop offset="55%" stop-color="#f7a6a0" />
        <stop offset="100%" stop-color="#b98ce0" />
      </linearGradient>
    </defs>
  );
}

function CommandBarDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <Page />
      </Frame>
      <rect class="cb-scrim" x="0" y="0" width="320" height="200" rx="14" fill="rgba(6,6,14,0.55)" />
      <g class="cb-bar">
        <rect x="50" y="46" width="220" height="104" rx="12" fill="#1e1e29" stroke="rgba(255,255,255,0.18)" />
        <rect x="64" y="60" width="140" height="9" rx="3" fill="rgba(255,255,255,0.85)" class="cb-typed" />
        <rect x="205" y="58" width="1.6" height="13" fill="#9c96ff" class="cb-caret" />
        <rect x="58" y="82" width="204" height="18" rx="6" fill="rgba(124,116,255,0.45)" class="cb-row cb-row-1" />
        <rect x="66" y="88" width="90" height="6" rx="3" fill="rgba(255,255,255,0.8)" class="cb-row cb-row-1" />
        <rect x="66" y="108" width="120" height="6" rx="3" fill="rgba(255,255,255,0.4)" class="cb-row cb-row-2" />
        <rect x="66" y="126" width="74" height="6" rx="3" fill="rgba(255,255,255,0.4)" class="cb-row cb-row-3" />
      </g>
    </>
  );
}

function SidebarDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <g class="sb-page">
          <Page />
        </g>
      </Frame>
    </>
  );
}

function SpacesDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <Page />
      </Frame>
      <rect class="sp-second" x="8" y="8" width="84" height="184" rx="9" fill="#e0457b" />
      <g class="sp-second-rows">
        <rect x="15" y="30" width="70" height="11" rx="4" fill="rgba(255,255,255,0.22)" />
        <rect x="15" y="82" width="70" height="10" rx="4" fill="rgba(255,255,255,0.34)" />
        <rect x="15" y="97" width="40" height="7" rx="3" fill="rgba(255,255,255,0.2)" />
      </g>
      <g class="sp-dots">
        <circle cx="38" cy="180" r="2.6" fill="rgba(255,255,255,0.55)" />
        <circle cx="50" cy="180" r="2.6" fill="rgba(255,255,255,0.55)" />
        <circle cx="62" cy="180" r="2.6" fill="rgba(255,255,255,0.55)" />
        <circle class="sp-dot-active" cx="38" cy="180" r="3.4" fill="#fff" />
      </g>
    </>
  );
}

function PeekSplitDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <Page />
      </Frame>
      <rect class="pk-link" x="112" y="104" width="78" height="8" rx="3" fill="#4f46e5" />
      <g class="pk-card">
        <rect x="0" y="0" width="320" height="200" rx="14" fill="rgba(6,6,14,0.5)" class="pk-scrim" />
        <rect x="118" y="22" width="176" height="160" rx="10" fill="#ffffff" />
        <rect x="132" y="38" width="80" height="7" rx="3" fill="#20212b" opacity="0.8" />
        <rect x="132" y="54" width="148" height="44" rx="6" fill="#d7e6ff" />
        <rect x="132" y="108" width="120" height="5" rx="2.5" fill="#20212b" opacity="0.3" />
        <rect x="132" y="118" width="134" height="5" rx="2.5" fill="#20212b" opacity="0.3" />
      </g>
      <g class="pk-split">
        <rect x="98" y="8" width="105" height="184" rx="9" fill="#fbfaf8" />
        <rect x="207" y="8" width="105" height="184" rx="9" fill="#ffffff" />
        <rect x="110" y="22" width="60" height="7" rx="3" fill="#20212b" opacity="0.8" />
        <rect x="110" y="38" width="81" height="44" rx="6" fill="url(#demo-sky)" />
        <rect x="219" y="22" width="60" height="7" rx="3" fill="#20212b" opacity="0.8" />
        <rect x="219" y="38" width="81" height="44" rx="6" fill="#d7e6ff" />
        <rect x="110" y="92" width="70" height="5" rx="2.5" fill="#20212b" opacity="0.3" />
        <rect x="219" y="92" width="70" height="5" rx="2.5" fill="#20212b" opacity="0.3" />
        <rect x="203" y="80" width="4" height="40" rx="2" fill="#4f46e5" opacity="0.6" />
      </g>
    </>
  );
}

function BoostsDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <g class="bo-page">
          <Page />
        </g>
      </Frame>
      <rect class="bo-zapped" x="112" y="150" width="186" height="30" rx="6" fill="#f08a4b" opacity="0.8" />
      <g class="bo-bolt">
        <circle cx="0" cy="0" r="13" fill="#1e1e29" stroke="rgba(255,255,255,0.4)" />
        <path d="M2 -8 L-5 2 L0 2 L-2 8 L5 -2 L0 -2 Z" fill="#ffd36a" />
      </g>
    </>
  );
}

function LibraryDemo({ tint }: DemoProps): JSX.Element {
  return (
    <>
      <Frame tint={tint}>
        <g class="lb-page">
          <Page />
        </g>
      </Frame>
      <g class="lb-drawer">
        <rect x="8" y="8" width="190" height="184" rx="9" fill="#1a1a24" />
        <rect x="8" y="8" width="30" height="184" rx="9" fill="#23232f" />
        <circle cx="23" cy="34" r="5" fill="rgba(255,255,255,0.55)" />
        <circle cx="23" cy="54" r="5" fill="rgba(255,255,255,0.3)" />
        <circle cx="23" cy="74" r="5" fill="rgba(255,255,255,0.3)" />
        <circle cx="23" cy="94" r="5" fill="rgba(255,255,255,0.3)" />
        <rect x="48" y="24" width="70" height="8" rx="3" fill="rgba(255,255,255,0.8)" />
        <rect x="48" y="44" width="62" height="40" rx="6" fill="url(#demo-sky)" class="lb-item" />
        <rect x="116" y="44" width="62" height="40" rx="6" fill="#3b8beb" opacity="0.7" class="lb-item" />
        <rect x="48" y="92" width="62" height="40" rx="6" fill="#3fa56b" opacity="0.7" class="lb-item" />
        <rect x="116" y="92" width="62" height="40" rx="6" fill="#e0457b" opacity="0.7" class="lb-item" />
        <rect x="48" y="142" width="130" height="7" rx="3" fill="rgba(255,255,255,0.3)" />
        <rect x="48" y="156" width="100" height="7" rx="3" fill="rgba(255,255,255,0.3)" />
      </g>
    </>
  );
}

const DEMOS: Record<DemoId, (props: DemoProps) => JSX.Element> = {
  'command-bar': CommandBarDemo,
  sidebar: SidebarDemo,
  spaces: SpacesDemo,
  'peek-split': PeekSplitDemo,
  boosts: BoostsDemo,
  library: LibraryDemo,
};

export function FeatureDemo({ id, tint, playing }: { id: DemoId; tint: string; playing: boolean }): JSX.Element {
  const Demo = DEMOS[id];
  return (
    <svg
      class={`demo demo-${id}${playing ? ' is-playing' : ''}`}
      viewBox="0 0 320 200"
      role="img"
      aria-label=""
      aria-hidden="true"
    >
      <Defs />
      <Demo tint={tint} />
    </svg>
  );
}
