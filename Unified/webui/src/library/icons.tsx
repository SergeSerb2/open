// Monochrome Library glyphs: Open's own vectors (the 28-pt rail set and the
// 16-pt row controls of Packages/OpenKit/Sources/OpenLibrary/LibraryGlyph.swift),
// drawn with currentColor. No emoji, font glyphs or external images.

import type { JSX } from 'preact';

interface GlyphProps {
  size?: number;
  /** Rail tiles fill their shapes more strongly when selected. */
  selected?: boolean;
  class?: string;
}

function Svg({
  size,
  box,
  width,
  children,
  class: className,
}: {
  size: number;
  box: number;
  width: number;
  children: JSX.Element | JSX.Element[];
  class?: string | undefined;
}): JSX.Element {
  return (
    <svg
      class={className}
      width={size}
      height={size}
      viewBox={`0 0 ${box} ${box}`}
      fill="none"
      stroke="currentColor"
      stroke-width={width}
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

const tint = (selected?: boolean) => ({ fill: 'currentColor', 'fill-opacity': selected ? 0.3 : 0.14 });

// --- Rail (28-pt canvas, 1.6 stroke) ------------------------------------------

export function MediaGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <rect x="7.5" y="8.5" width="17" height="13.5" rx="3" {...tint(selected)} />
      <path d="M5 18.5V9c0-1.66 1.34-3 3-3h11" />
      <circle cx="12.6" cy="13" r="1.5" />
      <polyline points="8,20.5 12.6,16.9 15.6,19.1 19,15.5 24,20.1" />
    </Svg>
  );
}

export function DownloadsGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <circle cx="14" cy="14" r="9" {...tint(selected)} />
      <line x1="14" y1="9.5" x2="14" y2="17.9" />
      <polyline points="10.4,14.6 14,18.2 17.6,14.6" />
    </Svg>
  );
}

export function EaselsGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <rect x="5" y="5.5" width="18" height="12.5" rx="2.5" {...tint(selected)} />
      <line x1="14" y1="18" x2="14" y2="23.5" />
      <line x1="9.8" y1="18" x2="7.5" y2="23.5" />
      <line x1="18.2" y1="18" x2="20.5" y2="23.5" />
      <path d="M9.5 13.8C11.2 10.2 12.9 15.4 14.5 12.2C15.5 10.2 16.9 11 18.5 12.4" />
    </Svg>
  );
}

export function SpacesGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <rect x="10" y="6.5" width="12" height="16" rx="3" {...tint(selected)} />
      <path d="M8.6 9.2L6.7 9.7C5.2 10.1 4.5 11.5 4.9 12.9L7.2 21.2C7.6 22.7 9 23.4 10.4 23L11 22.8" />
    </Svg>
  );
}

export function BoostsGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <polygon points="15.5,4.5 7,15.5 13,15.5 11.5,23.5 20.5,12 14.5,12" {...tint(selected)} />
      <line x1="22" y1="5" x2="22" y2="8" />
      <line x1="20.5" y1="6.5" x2="23.5" y2="6.5" />
      <line x1="6" y1="6.5" x2="6" y2="8.5" />
      <line x1="5" y1="7.5" x2="7" y2="7.5" />
    </Svg>
  );
}

export function ArchiveGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <rect x="6.5" y="10.5" width="15" height="11.5" rx="2.5" stroke="none" {...tint(selected)} />
      <rect x="5" y="6" width="18" height="4.5" rx="1.8" />
      <path d="M6.5 10.5V19.5C6.5 20.88 7.62 22 9 22H19C20.38 22 21.5 20.88 21.5 19.5V10.5" />
      <line x1="11.5" y1="14.5" x2="16.5" y2="14.5" />
    </Svg>
  );
}

export function HistoryGlyph({ size = 28, selected, class: c }: GlyphProps): JSX.Element {
  return (
    <Svg size={size} box={28} width={1.6} class={c}>
      <circle cx="14.5" cy="14" r="8.5" stroke="none" {...tint(selected)} />
      <path d="M6.2 12.18A8.5 8.5 0 1 1 6 14" />
      <polyline points="4.2,9.3 6.1,12.4 9.3,10.7" />
      <polyline points="14.5,9.5 14.5,14 17.7,16" />
    </Svg>
  );
}

// --- Controls (16-pt canvas) ----------------------------------------------------

type Small = { size?: number; class?: string };

export function SearchGlyph({ size = 15, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.6} class={c}>
      <circle cx="7" cy="7" r="4.6" />
      <line x1="10.5" y1="10.5" x2="14" y2="14" />
    </Svg>
  );
}

export function FilterGlyph({ size = 15, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <circle cx="8" cy="8" r="6.3" />
      <line x1="4.8" y1="6.3" x2="11.2" y2="6.3" />
      <line x1="5.8" y1="8.3" x2="10.2" y2="8.3" />
      <line x1="6.9" y1="10.3" x2="9.1" y2="10.3" />
    </Svg>
  );
}

export function BackGlyph({ size = 18, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={18} width={1.6} class={c}>
      <line x1="15" y1="9" x2="3.5" y2="9" />
      <polyline points="8,4.3 3.3,9 8,13.7" />
    </Svg>
  );
}

export function DotsGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.6} class={c}>
      <circle cx="3.5" cy="8" r="0.9" fill="currentColor" />
      <circle cx="8" cy="8" r="0.9" fill="currentColor" />
      <circle cx="12.5" cy="8" r="0.9" fill="currentColor" />
    </Svg>
  );
}

export function TrashGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <line x1="3" y1="4.5" x2="13" y2="4.5" />
      <polyline points="6.3,4.5 6.3,3 9.7,3 9.7,4.5" />
      <polyline points="4.3,4.5 4.9,13 11.1,13 11.7,4.5" />
      <line x1="6.8" y1="7" x2="6.8" y2="10.8" />
      <line x1="9.2" y1="7" x2="9.2" y2="10.8" />
    </Svg>
  );
}

export function PauseGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.5} class={c}>
      <line x1="6" y1="4.5" x2="6" y2="11.5" />
      <line x1="10" y1="4.5" x2="10" y2="11.5" />
    </Svg>
  );
}

export function ResumeGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <polygon points="5.8,4.2 11.6,8 5.8,11.8" />
    </Svg>
  );
}

export function CancelGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.4} class={c}>
      <line x1="5" y1="5" x2="11" y2="11" />
      <line x1="11" y1="5" x2="5" y2="11" />
    </Svg>
  );
}

export function RetryGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.4} class={c}>
      <path d="M7.34 4.25A4.2 4.2 0 1 1 5.03 5.43" />
      <polyline points="7.2,2.4 8.6,4.2 6.8,5.4" />
    </Svg>
  );
}

export function UndoGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.4} class={c}>
      <polyline points="6,3.5 3,6.5 6,9.5" />
      <path d="M3.3 6.5H9A3.5 3.5 0 0 1 9 13.5H7" />
    </Svg>
  );
}

export function PeekGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M1.8 8C3.2 5.3 5.4 3.9 8 3.9S12.8 5.3 14.2 8C12.8 10.7 10.6 12.1 8 12.1S3.2 10.7 1.8 8Z" />
      <circle cx="8" cy="8" r="2.1" />
    </Svg>
  );
}

export function RevealGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M2.5 5V11.8C2.5 12.46 3.04 13 3.7 13H12.3C12.96 13 13.5 12.46 13.5 11.8V6.4C13.5 5.74 12.96 5.2 12.3 5.2H8L6.7 3.5H3.7C3.04 3.5 2.5 4.04 2.5 4.7Z" />
      <circle cx="7.6" cy="9" r="1.7" />
      <line x1="8.85" y1="10.25" x2="10.3" y2="11.7" />
    </Svg>
  );
}

export function OpenGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M12.5 9V12C12.5 12.83 11.83 13.5 11 13.5H4C3.17 13.5 2.5 12.83 2.5 12V5C2.5 4.17 3.17 3.5 4 3.5H7" />
      <polyline points="9.5,2.5 13.5,2.5 13.5,6.5" />
      <line x1="13.3" y1="2.7" x2="7.5" y2="8.5" />
    </Svg>
  );
}

export function CopyGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <rect x="5.5" y="5.5" width="8" height="8" rx="1.6" />
      <path d="M10.5 5.5V4C10.5 3.17 9.83 2.5 9 2.5H4C3.17 2.5 2.5 3.17 2.5 4V9C2.5 9.83 3.17 10.5 4 10.5H5.5" />
    </Svg>
  );
}

export function LinkGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M7 9a2.8 2.8 0 0 0 4 0l2-2a2.8 2.8 0 0 0-4-4l-.7.7" />
      <path d="M9 7a2.8 2.8 0 0 0-4 0L3 9a2.8 2.8 0 0 0 4 4l.7-.7" />
    </Svg>
  );
}

export function PlusGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.5} class={c}>
      <line x1="8" y1="3.5" x2="8" y2="12.5" />
      <line x1="3.5" y1="8" x2="12.5" y2="8" />
    </Svg>
  );
}

export function ChevronGlyph({ size = 12, open, class: c }: Small & { open?: boolean }): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.6} class={c}>
      <polyline points={open ? '4,6 8,10 12,6' : '6,4 10,8 6,12'} />
    </Svg>
  );
}

export function CheckGlyph({ size = 14, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.6} class={c}>
      <polyline points="3.5,8.5 6.6,11.5 12.5,4.5" />
    </Svg>
  );
}

export function PencilGlyph({ size = 16, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M10.6 3.2L12.8 5.4L6 12.2L3.2 12.8L3.8 10L10.6 3.2Z" />
      <line x1="9.4" y1="4.4" x2="11.6" y2="6.6" />
    </Svg>
  );
}

export function BrushGlyph({ size = 20, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.2} class={c}>
      <path d="M13.5 2.5L7.6 8.4" />
      <path d="M7.6 8.4L9 9.8L13.5 2.5" />
      <path d="M6.6 9.2C5.3 9.2 4.4 10.1 4.4 11.4C4.4 12.3 3.8 12.9 2.8 13.2C5.6 14.2 8.4 12.8 8 10.6" />
    </Svg>
  );
}

export function FileGlyph({ size = 24, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={24} width={1.3} class={c}>
      <path d="M6.5 3.5H13.5L18 8V19.5C18 20.05 17.55 20.5 17 20.5H6.5C5.95 20.5 5.5 20.05 5.5 19.5V4.5C5.5 3.95 5.95 3.5 6.5 3.5Z" fill="currentColor" fill-opacity="0.08" />
      <path d="M13.5 3.5V8H18" />
      <line x1="8.5" y1="12" x2="15" y2="12" />
      <line x1="8.5" y1="14.5" x2="15" y2="14.5" />
      <line x1="8.5" y1="17" x2="12.5" y2="17" />
    </Svg>
  );
}

export function FolderGlyph({ size = 20, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <path d="M2.5 5V11.8C2.5 12.46 3.04 13 3.7 13H12.3C12.96 13 13.5 12.46 13.5 11.8V6.4C13.5 5.74 12.96 5.2 12.3 5.2H8L6.7 3.5H3.7C3.04 3.5 2.5 4.04 2.5 4.7Z" fill="currentColor" fill-opacity="0.12" />
    </Svg>
  );
}

export function NoteGlyph({ size = 20, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <rect x="3" y="2.5" width="10" height="11" rx="2" fill="currentColor" fill-opacity="0.1" />
      <line x1="5.5" y1="6" x2="10.5" y2="6" />
      <line x1="5.5" y1="8.5" x2="10.5" y2="8.5" />
      <line x1="5.5" y1="11" x2="8.5" y2="11" />
    </Svg>
  );
}

export function PlayGlyph({ size = 22, class: c }: Small): JSX.Element {
  return (
    <svg class={c} width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="11" fill="rgba(0,0,0,0.45)" />
      <polygon points="9.5,7.5 17,12 9.5,16.5" fill="#fff" />
    </svg>
  );
}

export function PersonGlyph({ size = 14, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.3} class={c}>
      <circle cx="8" cy="5.6" r="2.6" />
      <path d="M3 13.5C3.6 10.9 5.6 9.6 8 9.6S12.4 10.9 13 13.5" />
    </Svg>
  );
}

export function CloseGlyph({ size = 14, class: c }: Small): JSX.Element {
  return (
    <Svg size={size} box={16} width={1.5} class={c}>
      <line x1="4.5" y1="4.5" x2="11.5" y2="11.5" />
      <line x1="11.5" y1="4.5" x2="4.5" y2="11.5" />
    </Svg>
  );
}
