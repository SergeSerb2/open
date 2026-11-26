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

// --- Settings rail and control glyphs ---------------------------------------
// Original monochrome line icons drawn on a 16×16 grid in the SF Symbols
// manner (1.4 stroke, round caps). They inherit `currentColor`.

function LineIcon({ size = 16, class: className, children }: IconProps & { children: JSX.Element | JSX.Element[] }): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export function GeneralIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <circle cx="8" cy="8" r="2.6" />
      <path d="M8 1.6v1.6M8 12.8v1.6M1.6 8h1.6M12.8 8h1.6M3.5 3.5l1.1 1.1M11.4 11.4l1.1 1.1M3.5 12.5l1.1-1.1M11.4 4.6l1.1-1.1" />
    </LineIcon>
  );
}

export function PersonIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <circle cx="8" cy="5.2" r="2.7" />
      <path d="M2.8 14c.5-2.8 2.6-4.3 5.2-4.3s4.7 1.5 5.2 4.3" />
    </LineIcon>
  );
}

export function SpacesIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="2" y="2" width="5" height="5" rx="1.4" />
      <rect x="9" y="2" width="5" height="5" rx="1.4" />
      <rect x="2" y="9" width="5" height="5" rx="1.4" />
      <rect x="9" y="9" width="5" height="5" rx="1.4" />
    </LineIcon>
  );
}

export function LinkIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M6.6 9.4l2.8-2.8" />
      <path d="M7.4 4.6l1.3-1.3a2.8 2.8 0 014 4l-1.3 1.3" />
      <path d="M8.6 11.4l-1.3 1.3a2.8 2.8 0 01-4-4l1.3-1.3" />
    </LineIcon>
  );
}

export function AppearanceIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="1.8" y="2.6" width="12.4" height="10.8" rx="2.2" />
      <path d="M6 2.6v10.8" />
    </LineIcon>
  );
}

export function TabsIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="2" y="3" width="12" height="4" rx="1.4" />
      <rect x="2" y="9" width="12" height="4" rx="1.4" />
    </LineIcon>
  );
}

export function KeyboardIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="1.6" y="3.6" width="12.8" height="8.8" rx="2" />
      <path d="M4.4 6.4h.01M6.8 6.4h.01M9.2 6.4h.01M11.6 6.4h.01M5.2 9.6h5.6" />
    </LineIcon>
  );
}

export function ExtensionsIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M3 4.4h3.1V3.6a1.4 1.4 0 012.8 0v.8H12v3.1h-.8a1.4 1.4 0 000 2.8h.8V13H3z" />
    </LineIcon>
  );
}

export function LockIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="3" y="7" width="10" height="7" rx="1.8" />
      <path d="M5.2 7V5.2a2.8 2.8 0 015.6 0V7" />
    </LineIcon>
  );
}

export function ShieldLineIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M8 1.8l5 1.9v3.9c0 3.1-2.1 5.5-5 6.6-2.9-1.1-5-3.5-5-6.6V3.7z" />
    </LineIcon>
  );
}

export function KeyIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <circle cx="5" cy="11" r="2.6" />
      <path d="M6.9 9.1L13.6 2.4M11.2 4.8l1.6 1.6M9.6 6.4l1.2 1.2" />
    </LineIcon>
  );
}

export function CloudIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M4.6 12.6h7a2.8 2.8 0 00.4-5.6 3.9 3.9 0 00-7.5-.8A3.2 3.2 0 004.6 12.6z" />
    </LineIcon>
  );
}

export function ImportIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M8 2v7.4M5 6.6L8 9.6l3-3" />
      <path d="M2.4 10.4v1.8c0 .9.7 1.6 1.6 1.6h8c.9 0 1.6-.7 1.6-1.6v-1.8" />
    </LineIcon>
  );
}

export function SlidersIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M2 4.4h12M2 8h12M2 11.6h12" />
      <circle cx="5" cy="4.4" r="1.4" fill="var(--bg-sidebar, #fff)" />
      <circle cx="10.6" cy="8" r="1.4" fill="var(--bg-sidebar, #fff)" />
      <circle cx="6.4" cy="11.6" r="1.4" fill="var(--bg-sidebar, #fff)" />
    </LineIcon>
  );
}

export function InfoIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <circle cx="8" cy="8" r="6.2" />
      <path d="M8 7.2v3.8M8 4.9h.01" />
    </LineIcon>
  );
}

export function WarningIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M8 2.2l6.2 11H1.8z" />
      <path d="M8 6.6v3M8 11.4h.01" />
    </LineIcon>
  );
}

export function ChevronRightIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M6 3.6L10.4 8 6 12.4" />
    </LineIcon>
  );
}

export function ChevronDownIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M3.6 6L8 10.4 12.4 6" />
    </LineIcon>
  );
}

export function ArrowUpIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M8 13V3M4 7l4-4 4 4" />
    </LineIcon>
  );
}

export function ArrowDownIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M8 3v10M4 9l4 4 4-4" />
    </LineIcon>
  );
}

export function CopyIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <rect x="5.4" y="5.4" width="8" height="8" rx="1.6" />
      <path d="M10.6 5.4V4.2c0-.9-.7-1.6-1.6-1.6H4.2c-.9 0-1.6.7-1.6 1.6V9c0 .9.7 1.6 1.6 1.6h1.2" />
    </LineIcon>
  );
}

export function FolderIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M2 4.6c0-.9.7-1.6 1.6-1.6h2.8l1.4 1.6h4.6c.9 0 1.6.7 1.6 1.6v5.2c0 .9-.7 1.6-1.6 1.6H3.6c-.9 0-1.6-.7-1.6-1.6z" />
    </LineIcon>
  );
}

export function RefreshIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M13 8a5 5 0 11-1.5-3.6" />
      <path d="M13 2.6v2.6h-2.6" />
    </LineIcon>
  );
}

export function GlobeIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <circle cx="8" cy="8" r="6.2" />
      <path d="M1.8 8h12.4M8 1.8c1.7 1.8 2.5 3.9 2.5 6.2S9.7 12.4 8 14.2C6.3 12.4 5.5 10.3 5.5 8S6.3 3.6 8 1.8z" />
    </LineIcon>
  );
}

export function DragHandleIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M6 4h.01M10 4h.01M6 8h.01M10 8h.01M6 12h.01M10 12h.01" stroke-width="2" />
    </LineIcon>
  );
}

export function PencilIcon(props: IconProps): JSX.Element {
  return (
    <LineIcon {...props}>
      <path d="M10.6 2.8l2.6 2.6-7.4 7.4-3 .4.4-3z" />
    </LineIcon>
  );
}

/** Open's doorway-and-sun mark as a white line drawing for dark surfaces (hero cards). */
export function DoorwayLineMark({ size = 44, class: className }: IconProps): JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 44 44" fill="none" class={className} aria-hidden="true">
      <defs>
        <linearGradient id="openDoorwayFill" x1="10" y1="10" x2="30" y2="40" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stop-color="#6E5FB0" stop-opacity="0.55" />
          <stop offset="100%" stop-color="#2A2260" stop-opacity="0.15" />
        </linearGradient>
        <radialGradient id="openDoorwaySun" cx="35%" cy="35%" r="70%">
          <stop offset="0%" stop-color="#FFD58A" />
          <stop offset="100%" stop-color="#F59E0B" />
        </radialGradient>
      </defs>
      <path
        d="M7 40V19.5C7 13.7 11.5 9 17 9s10 4.7 10 10.5V40z"
        fill="url(#openDoorwayFill)"
        stroke="#FFFFFF"
        stroke-width="2.4"
        stroke-linejoin="round"
      />
      <circle cx="29.5" cy="9.5" r="6.5" fill="url(#openDoorwaySun)" />
    </svg>
  );
}
