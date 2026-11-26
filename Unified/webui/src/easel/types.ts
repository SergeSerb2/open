// Rich Easel canvas data model (superset of shared/bridge.ts EaselDocument).
// Preserved losslessly by OpenDocumentsUI via Easels/<id>/extended.json while
// keeping Easels/<id>/document.json compatible with DocumentStore & Library.

export type EaselItemType =
  | 'text'
  | 'sticky'
  | 'image'
  | 'live_card'
  | 'rect'
  | 'ellipse'
  | 'line'
  | 'arrow'
  | 'freehand'
  | 'frame';

export type ToolKind = 'select' | EaselItemType;

export type CanvasBackground = 'dots' | 'grid' | 'plain';
export type EaselFontFamily = 'clean' | 'mono' | 'fancy' | 'hip';
export type EaselTextAlign = 'left' | 'center' | 'right';

export interface EaselViewport {
  x: number;
  y: number;
  zoom: number;
}

export interface EaselItem {
  id: string;
  type: EaselItemType;
  x: number;
  y: number;
  width: number;
  height: number;
  content: string;
  fill_color: string;
  stroke_color: string;
  stroke_width: number;
  font_size: number;
  z_index: number;
  // Extended properties preserved in extended.json:
  rotation?: number;
  opacity?: number;
  font_family?: EaselFontFamily;
  font_weight?: 'normal' | 'bold';
  font_style?: 'normal' | 'italic';
  text_align?: EaselTextAlign;
  text_color?: string;
  // Relative endpoints for arrow & line (within 0..width, 0..height):
  start_x?: number;
  start_y?: number;
  end_x?: number;
  end_y?: number;
  // Image & Live Capture Card fields:
  asset_id?: string;
  image_url?: string;
  data_url?: string;
  live_url?: string;
  live_title?: string;
  last_refreshed_at?: number;
  // Grouping / frame label:
  group_id?: string;
}

export interface RichEaselDocument {
  format_version: number;
  id: string;
  title: string;
  canvas_width: number;
  canvas_height: number;
  palette: 'vibrant' | 'chill';
  canvas_background?: CanvasBackground;
  viewport?: EaselViewport;
  elements: EaselItem[];
  created_at: number;
  modified_at: number;
}

// 11-color palettes matching Packages/OpenKit/Sources/OpenEasel/EaselPalette.swift.
export const PALETTES: Record<'vibrant' | 'chill', readonly string[]> = {
  vibrant: [
    '#FFFFFF',
    '#FFD335',
    '#FF994E',
    '#F53714',
    '#34E895',
    '#107A00',
    '#14151F',
    '#BBBBBB',
    '#C0009F',
    '#00C7F3',
    '#3139FB',
  ],
  chill: [
    '#FFFFFF',
    '#C2A12A',
    '#F2C2AC',
    '#D74807',
    '#D0D87F',
    '#1D5914',
    '#14151F',
    '#BBBBBB',
    '#A6729D',
    '#55A2BD',
    '#3139FB',
  ],
};

// 6 pastel sticky note colors.
export const STICKY_COLORS: readonly { name: string; bg: string; border: string }[] = [
  { name: 'Butter', bg: '#FFF3B0', border: '#E8D575' },
  { name: 'Blush', bg: '#FFD6E0', border: '#F0AEC0' },
  { name: 'Mint', bg: '#D8F3DC', border: '#A7DEB2' },
  { name: 'Sky', bg: '#D0EBFF', border: '#99D1FA' },
  { name: 'Lavender', bg: '#E5DBFF', border: '#C7B4FA' },
  { name: 'Peach', bg: '#FFE5CC', border: '#F5C496' },
];

export const FONT_FAMILY_CSS: Record<EaselFontFamily, string> = {
  clean: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', system-ui, sans-serif",
  mono: "'SF Mono', 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace",
  fancy: "Georgia, 'Iowan Old Style', 'Times New Roman', serif",
  hip: "'Avenir Next', 'SF Pro Rounded', 'Nunito', system-ui, sans-serif",
};

export const MIN_ZOOM = 0.25;
export const MAX_ZOOM = 4.0;
export const SNAP_THRESHOLD_PX = 6;
