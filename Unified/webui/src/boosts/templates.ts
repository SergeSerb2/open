// Starter Boosts for the gallery. Site templates carry their own site; the
// general ones ask for one when used.

import type { Boost } from '../shared/bridge';

export interface BoostTemplate {
  id: string;
  name: string;
  description: string;
  /** Empty: the person picks the site. */
  host_pattern: string;
  /** Card art: page and accent colours of the preview. */
  preview: { page: string; ink: string; accent: string; serif?: boolean };
  boost: Pick<Boost, 'color' | 'font_family' | 'text_zoom' | 'text_transform' | 'custom_css'>;
}

const NO_COLOR: Boost['color'] = {
  enabled: false,
  hue_degrees: 0,
  saturation: 1,
  lightness: 0,
  contrast: 1,
  invert: false,
};

export const BOOST_TEMPLATES: readonly BoostTemplate[] = [
  {
    id: 'minimal-reader',
    name: 'Minimal Reader',
    description: 'One calm column of text. Sidebars, menus and footers step aside.',
    host_pattern: '',
    preview: { page: '#fbfaf7', ink: '#2b2b33', accent: '#c9b79c', serif: true },
    boost: {
      color: NO_COLOR,
      font_family: 'Georgia',
      text_zoom: 1.1,
      text_transform: '',
      custom_css: [
        'body { max-width: 72ch !important; margin: 0 auto !important; line-height: 1.65 !important; }',
        'aside, nav, footer, [role="complementary"], [class*="sidebar"] { display: none !important; }',
      ].join('\n'),
    },
  },
  {
    id: 'high-contrast-dark',
    name: 'High Contrast Dark',
    description: 'Dark pages with crisp contrast. Photos and video keep their colors.',
    host_pattern: '',
    // The preview is the original light page; the Boost's invert darkens it.
    preview: { page: '#f7f7fa', ink: '#18181f', accent: '#8b8bff' },
    boost: {
      color: { enabled: true, hue_degrees: 180, saturation: 1, lightness: 0, contrast: 1.15, invert: true },
      font_family: '',
      text_zoom: 1,
      text_transform: '',
      custom_css: '',
    },
  },
  {
    id: 'warm-sepia',
    name: 'Warm Sepia',
    description: 'Paper tones that are easy on the eyes late in the evening.',
    host_pattern: '',
    preview: { page: '#f4ecd8', ink: '#4a3b28', accent: '#d9a45b', serif: true },
    boost: {
      color: { enabled: true, hue_degrees: -12, saturation: 0.82, lightness: 0.02, contrast: 0.95, invert: false },
      font_family: '',
      text_zoom: 1,
      text_transform: '',
      custom_css: 'html, body { background: #f4ecd8 !important; }',
    },
  },
  {
    id: 'focused-youtube',
    name: 'Focused YouTube',
    description: 'Just the video. Recommendations, Shorts and comments are hidden.',
    host_pattern: 'youtube.com',
    preview: { page: '#0f0f0f', ink: '#f1f1f1', accent: '#ff4e45' },
    boost: {
      color: NO_COLOR,
      font_family: '',
      text_zoom: 1,
      text_transform: '',
      custom_css: [
        '#secondary, #related, #comments, ytd-reel-shelf-renderer, ytd-rich-shelf-renderer,',
        'ytd-rich-section-renderer, #chips-wrapper { display: none !important; }',
      ].join('\n'),
    },
  },
  {
    id: 'clean-wikipedia',
    name: 'Clean Wikipedia',
    description: 'A serif article in the middle of the page, without the chrome.',
    host_pattern: 'wikipedia.org',
    preview: { page: '#ffffff', ink: '#202122', accent: '#3366cc', serif: true },
    boost: {
      color: NO_COLOR,
      font_family: 'Georgia',
      text_zoom: 1.08,
      text_transform: '',
      custom_css: [
        '.vector-header-container, .vector-column-start, .vector-page-toolbar, .mw-footer, #siteNotice { display: none !important; }',
        '.mw-body, .mw-content-container { max-width: 780px !important; margin: 0 auto !important; }',
      ].join('\n'),
    },
  },
  {
    id: 'hn-serif',
    name: 'Hacker News Serif',
    description: 'Larger serif headlines with room to breathe.',
    host_pattern: 'news.ycombinator.com',
    preview: { page: '#f6f6ef', ink: '#222', accent: '#ff6600', serif: true },
    boost: {
      color: NO_COLOR,
      font_family: 'Georgia',
      text_zoom: 1.15,
      text_transform: '',
      custom_css: [
        '.titleline > a { font-size: 1.08em; }',
        'td { line-height: 1.5; }',
        '#hnmain { width: min(900px, 100%) !important; }',
      ].join('\n'),
    },
  },
];
