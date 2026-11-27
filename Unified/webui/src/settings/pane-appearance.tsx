import type { JSX } from 'preact';
import { SegmentedControl } from '../shared/components';
import { isMacPlatform } from '../shared/shortcuts';
import { useSettings } from './context';
import { Group, PaneHeader, PrefSelect, PrefToggle, Row } from './ui';

const THEMES = [
  { value: 'automatic', label: 'Match System' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
] as const;

/** A miniature window that follows the Theme and sidebar choices. */
function MiniWindow(): JSX.Element {
  const ctx = useSettings();
  const pref = String(ctx.prefs['appearance.websiteAppearance'] ?? 'automatic');
  const mode = pref === 'automatic' ? (ctx.theme?.mode ?? 'light') : pref;
  const right = ctx.prefs['appearance.sidebarPosition'] === 'right';
  const toolbar = ctx.prefs['appearance.toolbar'] === true;
  const mac = isMacPlatform();
  return (
    <div class={`st-mini is-${mode}${right ? ' is-right' : ''}${mac ? '' : ' is-win'}`} aria-hidden="true">
      <div class="st-mini-sidebar">
        {mac && (
          <span class="st-mini-lights">
            <i />
            <i />
            <i />
          </span>
        )}
        <span class="st-mini-pill" />
        <span class="st-mini-tab is-active" />
        <span class="st-mini-tab" />
        <span class="st-mini-tab" />
      </div>
      <div class="st-mini-page">
        {toolbar && <span class="st-mini-toolbar" />}
        <span class="st-mini-line w70" />
        <span class="st-mini-line w90" />
        <span class="st-mini-line w50" />
      </div>
      {!mac && (
        <span class="st-mini-win-controls">
          <svg viewBox="0 0 38 10" width="38" height="10" aria-hidden="true">
            <line x1="2" y1="5" x2="8" y2="5" stroke="currentColor" stroke-width="1.15" stroke-linecap="round" />
            <rect x="16" y="2.2" width="5.6" height="5.6" rx="0.8" fill="none" stroke="currentColor" stroke-width="1.1" />
            <path d="M29.5 2.2l5.6 5.6M35.1 2.2l-5.6 5.6" stroke="currentColor" stroke-width="1.15" stroke-linecap="round" />
          </svg>
        </span>
      )}
    </div>
  );
}

export function AppearancePane(): JSX.Element {
  const ctx = useSettings();
  const theme = String(ctx.prefs['appearance.websiteAppearance'] ?? 'automatic') as (typeof THEMES)[number]['value'];
  const previewsOn = ctx.prefs['previews.enabled'] === true;
  return (
    <div class="st-pane">
      <PaneHeader section="appearance" />
      <div class="st-mini-wrap">
        <MiniWindow />
      </div>

      <Group title="Theme">
        <Row id="appearance/theme" label="Theme" help="Open and websites follow this color scheme." prefKey="appearance.websiteAppearance">
          <SegmentedControl ariaLabel="Theme" options={THEMES} value={theme} onChange={(v) => void ctx.setPref('appearance.websiteAppearance', v)} />
        </Row>
      </Group>

      <Group title="Window">
        <PrefSelect
          id="appearance/sidebar-position"
          label="Sidebar position"
          prefKey="appearance.sidebarPosition"
          options={[
            { value: 'left', label: 'Left' },
            { value: 'right', label: 'Right' },
          ]}
        />
        <PrefToggle id="appearance/sidebar-autohide" label="Hide the sidebar automatically" help="Show it when the pointer reaches the edge of the window." prefKey="appearance.sidebarAutoHide" />
        {isMacPlatform() && (
          <PrefToggle id="appearance/translucency" label="Translucent window" help="Let the desktop show through the sidebar." prefKey="appearance.translucency" />
        )}
        <PrefToggle id="appearance/contrast" label="Increase contrast" help="Stronger borders and text in the sidebar." prefKey="appearance.increaseContrast" />
      </Group>

      <Group title="Toolbar">
        <PrefToggle id="appearance/toolbar" label="Show the toolbar" help="The address and page controls above each page." prefKey="appearance.toolbar" />
        <PrefToggle
          id="appearance/full-url"
          label="Show the full URL"
          help="Show the full address when the toolbar is on."
          prefKey="appearance.fullUrl"
          disabled={ctx.prefs['appearance.toolbar'] !== true}
        />
      </Group>

      <Group title="Text and zoom">
        <PrefSelect
          id="appearance/font-size"
          label="Font size"
          prefKey="appearance.fontSize"
          options={[
            { value: 'small', label: 'Small' },
            { value: 'medium', label: 'Medium' },
            { value: 'large', label: 'Large' },
            { value: 'very-large', label: 'Very large' },
          ]}
        />
        <PrefSelect
          id="appearance/zoom"
          label="Page zoom"
          prefKey="appearance.defaultZoom"
          options={['75', '80', '90', '100', '110', '125', '150', '175', '200'].map((v) => ({ value: v, label: `${v}%` }))}
        />
      </Group>

      <Group title="Previews">
        <PrefToggle id="appearance/previews" label="Show Open Previews" help="A quick look before you open." prefKey="previews.enabled" />
        <PrefToggle id="appearance/previews-folders" label="Folders" help="Preview folders on hover." prefKey="previews.folders" disabled={!previewsOn} />
        <PrefToggle id="appearance/previews-pages" label="Pinned tabs and Favorites" help="Preview pages on hover." prefKey="previews.pages" disabled={!previewsOn} />
        <PrefToggle id="appearance/previews-recents" label="Recent pages on Linear, Notion, Figma, and Confluence" prefKey="previews.recents" disabled={!previewsOn} />
        <PrefToggle id="appearance/previews-calendar" label="Upcoming meetings" help="Google, Outlook, and Notion Calendar, with Join Meeting." prefKey="previews.calendar" disabled={!previewsOn} />
        <PrefToggle id="appearance/previews-gmail" label="Unread mail in Gmail" prefKey="previews.gmail" disabled={!previewsOn} />
      </Group>
    </div>
  );
}
