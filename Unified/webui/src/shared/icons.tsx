// Lightweight inline SVG icons & Open's original doorway-and-sun emblem.
// Zero third-party icon pack dependencies.

import type { JSX } from 'preact';

interface IconProps {
  size?: number;
  class?: string;
}

export function OpenDoorwayMark({ size = 40, class: className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      fill="none"
      class={className}
      aria-label="Open"
    >
      <defs>
        <linearGradient id="openDoorBg" x1="10" y1="6" x2="54" y2="58" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stop-color="#3139FF" />
          <stop offset="55%" stop-color="#6052FF" />
          <stop offset="100%" stop-color="#FF9B54" />
        </linearGradient>
        <radialGradient id="openSunGlow" cx="50%" cy="62%" r="48%">
          <stop offset="0%" stop-color="#FFF4C8" />
          <stop offset="60%" stop-color="#FFBB66" stop-opacity="0.8" />
          <stop offset="100%" stop-color="#FF9B54" stop-opacity="0" />
        </radialGradient>
      </defs>
      <rect x="4" y="4" width="56" height="56" rx="16" fill="url(#openDoorBg)" />
      <path
        d="M20 52V28C20 21.373 25.373 16 32 16C38.627 16 44 21.373 44 28V52H20Z"
        fill="rgba(255,255,255,0.16)"
        stroke="#FFFFFF"
        stroke-width="2.4"
      />
      <circle cx="32" cy="36" r="10" fill="url(#openSunGlow)" />
      <circle cx="32" cy="36" r="5.5" fill="#FFF8DC" />
    </svg>
  );
}

export function SearchIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
      <circle cx="7" cy="7" r="4.6" />
      <path d="M10.5 10.5L14 14" />
    </svg>
  );
}

export function CloseIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
      <path d="M4 4l8 8M12 4l-8 8" />
    </svg>
  );
}

export function PlusIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round">
      <path d="M8 3v10M3 8h10" />
    </svg>
  );
}

export function TrashIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <path d="M2.5 4h11M6 4V2.5h4V4M4.5 4l.7 9.2a1 1 0 0 0 1 .8h3.6a1 1 0 0 0 1-.8L11.5 4" />
    </svg>
  );
}

export function CheckIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3.2 8.4l3 3 6.6-6.8" />
    </svg>
  );
}

export function ExternalIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9.5 2.5h4v4M13.5 2.5L7 9M12 9.5v3a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3" />
    </svg>
  );
}

export function ZapIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9 1.5L3 9h4.5L7 14.5 13 7H8.5L9 1.5z" />
    </svg>
  );
}

export function ShieldIcon({ size = 15 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round">
      <path d="M8 1.5l5.5 2v4.3c0 3.3-2.3 5.5-5.5 6.7-3.2-1.2-5.5-3.4-5.5-6.7V3.5L8 1.5z" />
    </svg>
  );
}

export function SyncIcon({ size = 15 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <path d="M13.5 8a5.5 5.5 0 0 1-9.6 3.6M2.5 8a5.5 5.5 0 0 1 9.6-3.6" />
      <path d="M12.5 2v3h-3M3.5 14v-3h3" />
    </svg>
  );
}

export function DownloadIcon({ size = 15 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 2.5v7.5M5 7.5L8 10.5l3-3M2.5 12.5h11" />
    </svg>
  );
}

export function UndoIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
      <path d="M5 4L2 7l3 3" />
      <path d="M2 7h7.5a3.5 3.5 0 1 1 0 7H7" />
    </svg>
  );
}

export function RedoIcon({ size = 14 }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
      <path d="M11 4l3 3-3 3" />
      <path d="M14 7H6.5a3.5 3.5 0 1 0 0 7H9" />
    </svg>
  );
}
