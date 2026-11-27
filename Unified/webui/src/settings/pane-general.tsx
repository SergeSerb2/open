import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { rpc } from '../shared/bridge';
import { Toggle } from '../shared/components';
import { CheckIcon, DoorwayLineMark, FolderIcon } from '../shared/icons';
import { isMacPlatform, shortcutPlatform } from '../shared/shortcuts';
import { useSettings } from './context';
import { Btn, Group, PaneHeader, PrefToggle, Row } from './ui';

/** Six original Open icon artworks (OpenPlatform::SetAppIcon ids). */
export const APP_ICONS = [
  { id: 'open-indigo', label: 'Indigo', bg: 'linear-gradient(140deg, #3B3FD8 0%, #6457F0 55%, #F2A35E 100%)' },
  { id: 'open-obsidian', label: 'Obsidian', bg: 'linear-gradient(140deg, #17171F 0%, #34364A 100%)' },
  { id: 'open-sunburst', label: 'Sunburst', bg: 'linear-gradient(140deg, #F7B455 0%, #EF5D3B 100%)' },
  { id: 'open-sage', label: 'Sage', bg: 'linear-gradient(140deg, #3FB68B 0%, #146B52 100%)' },
  { id: 'open-slate', label: 'Slate', bg: 'linear-gradient(140deg, #8390A6 0%, #3A4456 100%)' },
  { id: 'open-dawn', label: 'Dawn', bg: 'linear-gradient(140deg, #F08DB4 0%, #8C63E6 100%)' },
] as const;

export function AppIconPicker(): JSX.Element {
  const ctx = useSettings();
  const current = String(ctx.prefs['appearance.appIcon'] ?? 'open-indigo');
  return (
    <div class="st-icon-picker" role="radiogroup" aria-label="App icon">
      {APP_ICONS.map((icon) => (
        <button
          key={icon.id}
          type="button"
          role="radio"
          aria-checked={current === icon.id}
          class={`st-icon-choice${current === icon.id ? ' is-selected' : ''}`}
          onClick={() => void ctx.setPref('appearance.appIcon', icon.id)}
        >
          <span class="st-icon-art" style={{ background: icon.bg }}>
            <svg viewBox="0 0 40 40" width="30" height="30" aria-hidden="true">
              <path d="M12 33V18.5C12 13.8 15.6 10 20 10s8 3.8 8 8.5V33z" fill="rgba(255,255,255,0.18)" stroke="#fff" stroke-width="2" />
              <circle cx="20" cy="23" r="3.6" fill="#FFE9B8" />
            </svg>
          </span>
          <span class="st-icon-label">{icon.label}</span>
        </button>
      ))}
    </div>
  );
}

export function GeneralPane(): JSX.Element {
  const ctx = useSettings();
  const [isDefault, setIsDefault] = useState(ctx.snapshot?.is_default_browser === true);
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => setIsDefault(ctx.snapshot?.is_default_browser === true), [ctx.snapshot?.is_default_browser]);

  const makeDefault = async () => {
    setBusy('default');
    const res = await ctx.run(() => rpc('settings.setDefaultBrowser', {}));
    setBusy(null);
    if (!res) return;
    setIsDefault(res.is_default);
    if (res.status === 'declined') ctx.toast('Open was not set as the default browser.');
    else if (res.status === 'failed') ctx.toast('Your system did not let Open become the default browser.', 'danger');
    else ctx.toast('Open is now your default browser.', 'success');
  };

  const rawLocation = ctx.prefs['downloads.location'];
  const location =
    typeof rawLocation === 'string' && rawLocation.length > 0
      ? rawLocation
      : ctx.snapshot
        ? shortcutPlatform() === 'windows'
          ? 'Downloads'
          : '~/Downloads'
        : '';

  return (
    <div class="st-pane">
      <PaneHeader section="general" />

      {isDefault ? (
        <div id="row-general-default-browser" class="st-default-ok">
          <span class="st-default-ok-badge" aria-hidden="true">
            <CheckIcon size={12} />
          </span>
          <span>Open is your default browser.</span>
        </div>
      ) : (
        <div id="row-general-default-browser" class="st-hero">
          <DoorwayLineMark size={46} class="st-hero-mark" />
          <div class="st-hero-text">
            <div class="st-hero-title">Make Open your default browser</div>
            <div class="st-hero-subtitle">
              {isMacPlatform()
                ? 'Links from Mail, Messages, and other apps will open here.'
                : 'Links from email, chat, and other apps will open here.'}
            </div>
          </div>
          <button type="button" class="st-hero-cta" disabled={busy === 'default'} onClick={makeDefault}>
            {busy === 'default' ? 'Waiting…' : 'Set as default'}
          </button>
        </div>
      )}

      <Group title="Startup">
        <PrefToggle id="general/restore-windows" label="Restore windows from the previous session" prefKey="general.restoreWindows" />
        <PrefToggle
          id="general/warn-before-quitting"
          label="Warn before quitting"
          help="Ask for confirmation before quitting Open."
          prefKey="general.warnBeforeQuitting"
        />
      </Group>

      <Group title="Updates">
        <Row id="general/automatic-updates" label="Update Open automatically" help="Keep Open up to date." prefKey="general.automaticUpdates">
          <Btn
            small
            busy={busy === 'updates'}
            onClick={async () => {
              setBusy('updates');
              const res = await ctx.run(() => rpc('settings.about.checkForUpdates', {}));
              setBusy(null);
              if (res) ctx.toast(res.message);
            }}
          >
            Check Now
          </Btn>
          <Toggle
            checked={ctx.prefs['general.automaticUpdates'] === true}
            label="Update Open automatically"
            onChange={(v) => void ctx.setPref('general.automaticUpdates', v)}
          />
        </Row>
      </Group>

      <Group title="Downloads">
        <Row
          id="general/download-location"
          label="Download location"
          help={
            <span class="st-path" title={location}>
              <FolderIcon size={13} /> {location}
            </span>
          }
          prefKey="downloads.location"
        >
          <Btn
            busy={busy === 'folder'}
            onClick={async () => {
              setBusy('folder');
              const res = await ctx.run(() => rpc('settings.pickDownloadFolder', { profile_id: ctx.profileId }));
              setBusy(null);
              if (res && !res.canceled && res.preferences) {
                ctx.applyPreferences(res.preferences);
                ctx.toast(`Downloads go to ${res.path ?? 'the new folder'}.`, 'success');
              }
            }}
          >
            Choose…
          </Btn>
        </Row>
        <PrefToggle id="general/ask-each-file" label="Ask where to save each file" prefKey="downloads.askEachTime" />
      </Group>

      <Group title="Language">
        <PrefToggle
          id="general/translate"
          label="Offer to translate pages"
          help="Show a prompt for pages in a language you do not read."
          prefKey="general.offerTranslate"
        />
      </Group>

      <Group title="App icon">
        <Row id="general/app-icon" label="App icon" help="The icon in your Dock or taskbar changes at once." prefKey="appearance.appIcon" stacked>
          <AppIconPicker />
        </Row>
      </Group>

      <Group title="Move in">
        <Row id="general/import" label="Import from Arc" help="Bring your Spaces, tabs, bookmarks, and passwords into Open.">
          <Btn onClick={() => ctx.navigate('import')}>Import…</Btn>
        </Row>
        <Row id="general/export" label="Export your Open data" help="A JSON snapshot of Spaces, Favorites, settings, shortcuts, and rules.">
          <Btn
            busy={busy === 'export'}
            onClick={async () => {
              setBusy('export');
              const res = await ctx.run(() => rpc('settings.exportSnapshot', {}));
              setBusy(null);
              if (res?.ok) ctx.toast(`Saved ${res.path ?? 'your snapshot'}.`, 'success');
            }}
          >
            Export…
          </Btn>
        </Row>
      </Group>
    </div>
  );
}
