import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type AboutInfo, type UpdateCheckResult, rpc } from '../shared/bridge';
import { OpenDoorwayMark } from '../shared/icons';
import { CloseIcon, CopyIcon, FolderIcon } from '../shared/icons';
import { isMacPlatform } from '../shared/shortcuts';
import { useSettings } from './context';
import { ChromeLinkButton } from './pane-privacy';
import { Banner, Btn, Group, PaneHeader, Pill, PrefToggle, Row } from './ui';

function useAbout(): AboutInfo | null {
  const [about, setAbout] = useState<AboutInfo | null>(null);
  useEffect(() => {
    void rpc('settings.about.get', {})
      .then(setAbout)
      .catch(() => setAbout(null));
  }, []);
  return about;
}

export function AdvancedPane(): JSX.Element {
  const ctx = useSettings();
  const about = useAbout();
  const [host, setHost] = useState('');
  const hosts = Array.isArray(ctx.prefs['advanced.pipExcludedHosts']) ? (ctx.prefs['advanced.pipExcludedHosts'] as string[]) : [];
  const pipOn = ctx.prefs['advanced.pictureInPicture'] === true;
  const widevineOn = Boolean(ctx.prefs['advanced.widevine']);
  const widevineRestartRequired = about ? widevineOn !== about.widevine.session_enabled : false;

  const addHost = () => {
    if (!pipOn) return;
    const clean = host.trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0] ?? '';
    if (!clean || hosts.includes(clean)) return;
    void ctx.setPref('advanced.pipExcludedHosts', [...hosts, clean]).then((ok) => ok && setHost(''));
  };

  return (
    <div class="st-pane">
      <PaneHeader section="advanced" />

      <Group title="Pages">
        <PrefToggle id="advanced/boosts" label="Enable Boosts on websites you visit" prefKey="advanced.enableBoosts" />
        <PrefToggle id="advanced/shared-quotes" label="Enable Shared Quotes when highlighting text" help="You can always use Copy URL as Quote from the menu." prefKey="advanced.sharedQuotes" />
        <PrefToggle id="advanced/theme-data" label="Allow websites to get your theme data" prefKey="advanced.themeData" />
        <PrefToggle id="advanced/window-dragging" label="Allow window dragging from the top of webpages" prefKey="advanced.windowDragging" />
      </Group>

      <Group title="Picture in Picture">
        <PrefToggle id="advanced/pip" label="Enable Picture in Picture when you leave a video tab" prefKey="advanced.pictureInPicture" />
        <Row
          id="advanced/pip-hosts"
          label="Never on these sites"
          help="Video calls and these sites keep playing in their tab."
          prefKey="advanced.pipExcludedHosts"
          stacked
          disabled={!pipOn}
        >
          <div class="st-add-site">
            <input
              class="st-input"
              type="text"
              value={host}
              disabled={!pipOn}
              placeholder="meet.example.com"
              aria-label="Site without Picture in Picture"
              spellcheck={false}
              autocomplete="off"
              onInput={(e) => setHost((e.currentTarget as HTMLInputElement).value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  addHost();
                }
              }}
            />
            <Btn disabled={!pipOn || !host.trim()} onClick={addHost}>
              Add site
            </Btn>
          </div>
          {hosts.length > 0 && (
            <div class="st-tags">
              {hosts.map((h) => (
                <span key={h} class="st-tag">
                  {h}
                  <button
                    type="button"
                    disabled={!pipOn}
                    aria-label={`Remove ${h}`}
                    onClick={() => void ctx.setPref('advanced.pipExcludedHosts', hosts.filter((x) => x !== h))}
                  >
                    <CloseIcon size={10} />
                  </button>
                </span>
              ))}
            </div>
          )}
        </Row>
      </Group>

      <Group title="Feedback">
        <PrefToggle id="advanced/sound" label="Play Open sound effects" prefKey="advanced.soundEffects" />
        {isMacPlatform() && (
          <PrefToggle id="advanced/haptics" label="Haptic feedback when reordering tabs" prefKey="advanced.haptics" />
        )}
      </Group>

      <Group title="Media">
        <PrefToggle
          id="advanced/widevine"
          label="Play DRM-protected video"
          help="Downloads Google's Widevine module for streaming services. Takes effect after you quit and reopen Open."
          prefKey="advanced.widevine"
        />
        {about && (
          <Row id="advanced/widevine-status" label="Widevine in this session" help={widevineRestartRequired ? 'Quit and reopen Open to apply your choice.' : undefined}>
            <Pill tone={about.widevine.session_enabled ? 'success' : 'default'}>{about.widevine.session_enabled ? 'On' : 'Off'}</Pill>
            {widevineRestartRequired && <Pill tone="warning">{widevineOn ? 'Turns on after restart' : 'Turns off after restart'}</Pill>}
          </Row>
        )}
      </Group>

      <Group title="Developer">
        <PrefToggle id="advanced/developer-mode" label="Developer mode for extensions" help="Load unpacked extensions and see extension IDs." prefKey="advanced.developerMode" />
        <PrefToggle
          id="advanced/hardware-acceleration"
          label="Use hardware acceleration"
          help="Uses the graphics card. Takes effect after you quit and reopen Open."
          prefKey="advanced.hardwareAcceleration"
        />
      </Group>

      <Group title="Tools">
        <Row id="advanced/data-folder" label="Data folder" help={about?.data_folder ?? 'Where Open keeps your Profiles and settings.'}>
          <Btn onClick={() => void ctx.run(() => rpc('settings.about.showDataFolder', {}))}>
            <FolderIcon size={12} /> Show Data Folder
          </Btn>
        </Row>
        <Row id="advanced/onboarding" label="Replay onboarding" help="See the welcome tour again in a new tab.">
          <Btn onClick={() => void ctx.run(() => rpc('settings.about.replayOnboarding', {}))}>Replay</Btn>
        </Row>
        <Row id="advanced/more" label="More browser settings" help="Chromium settings for the current Profile.">
          <ChromeLinkButton url="chrome://settings">Open in tab</ChromeLinkButton>
        </Row>
      </Group>
    </div>
  );
}

export function AboutPane(): JSX.Element {
  const ctx = useSettings();
  const about = useAbout();
  const [update, setUpdate] = useState<UpdateCheckResult | null>(null);
  const [busy, setBusy] = useState(false);
  const version = about?.app_version ?? ctx.snapshot?.app_version ?? '';
  const engine = about?.chromium_version ?? ctx.snapshot?.chromium_version ?? '';
  const updateUrl = update?.status === 'update_available' ? update.download_url || update.release_url : undefined;
  const safeUpdateUrl = updateUrl && /^https?:\/\//i.test(updateUrl) ? updateUrl : undefined;

  return (
    <div class="st-pane">
      <PaneHeader section="about" />
      <div class="st-about" id="row-about-version">
        <OpenDoorwayMark size={88} class="st-about-mark" />
        <div class="st-about-name">Open</div>
        <div class="st-about-version">Version {version}</div>
        <div class="st-about-engine">Chromium engine {engine}</div>
        {about && (
          <div class="st-about-platform">
            {about.platform} · {about.architecture}
          </div>
        )}
      </div>

      {update && (
        <Banner
          tone={update.status === 'error' ? 'danger' : 'info'}
          action={
            safeUpdateUrl ? (
              <Btn kind="primary" small onClick={() => void ctx.run(() => rpc('library.openUrl', { url: safeUpdateUrl, new_tab: true }))}>
                {update.download_url ? 'Download Update' : 'View Release'}
              </Btn>
            ) : undefined
          }
        >
          {update.message}
        </Banner>
      )}

      <Group>
        <Row id="about/updates" label="Updates" help={`Open ${version}`}>
          <Btn
            busy={busy}
            onClick={async () => {
              setBusy(true);
              const res = await ctx.run(() => rpc('settings.about.checkForUpdates', {}));
              setBusy(false);
              if (res) setUpdate(res);
            }}
          >
            Check for Updates
          </Btn>
        </Row>
        <Row id="about/system-info" label="System info" help="Versions and counts for a bug report. It has no page addresses.">
          <Btn
            onClick={async () => {
              const res = await ctx.run(() => rpc('settings.about.copySystemInfo', {}));
              if (!res) return;
              try {
                await navigator.clipboard?.writeText(res.text);
              } catch {
                // Copied natively already.
              }
              ctx.toast('System info copied.', 'success');
            }}
          >
            <CopyIcon size={12} /> Copy System Info
          </Btn>
        </Row>
        <Row id="about/data-folder" label="Data folder" help={about?.data_folder}>
          <Btn onClick={() => void ctx.run(() => rpc('settings.about.showDataFolder', {}))}>Show</Btn>
        </Row>
        <Row id="about/widevine" label="Widevine content decryption">
          <Pill tone={about?.widevine.session_enabled ? 'success' : 'default'}>{about?.widevine.session_enabled ? 'On' : 'Off'}</Pill>
        </Row>
        <Row id="about/licenses" label="Licenses" help="Open is built on Chromium and other open-source software.">
          <ChromeLinkButton url="chrome://credits">Credits</ChromeLinkButton>
        </Row>
      </Group>
      <p class="st-about-foot">Open is not affiliated with Google. Chromium is an open-source project.</p>
    </div>
  );
}
