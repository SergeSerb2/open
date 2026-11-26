import type { JSX } from 'preact';
import { useState } from 'preact/hooks';
import { rpc } from '../shared/bridge';
import { Modal, Toggle } from '../shared/components';
import { ExternalIcon } from '../shared/icons';
import { useSettings } from './context';
import { Btn, Checkbox, Field, Group, PaneHeader, Pill, PrefToggle, Row, Select } from './ui';

type Range = 'hour' | 'day' | 'week' | 'month' | 'all';

const RANGES: { value: Range; label: string }[] = [
  { value: 'hour', label: 'Last hour' },
  { value: 'day', label: 'Last 24 hours' },
  { value: 'week', label: 'Last 7 days' },
  { value: 'month', label: 'Last 4 weeks' },
  { value: 'all', label: 'All time' },
];

const KINDS = [
  { id: 'history', label: 'Browsing history', help: 'Pages you visited in this Profile.' },
  { id: 'downloads', label: 'Download history', help: 'The list of downloads. Files stay on disk.' },
  { id: 'cookies', label: 'Cookies', help: 'Signs you out of most sites.' },
  { id: 'site_data', label: 'Site data', help: 'Local storage of websites.' },
  { id: 'cache', label: 'Cached images and files', help: 'Pages may load more slowly next time.' },
] as const;

export function ChromeLinkButton({ url, children }: { url: string; children: string }): JSX.Element {
  const ctx = useSettings();
  return (
    <Btn onClick={() => void ctx.run(() => rpc('settings.openChromeUrl', { url }))}>
      {children} <ExternalIcon size={12} />
    </Btn>
  );
}

export function PrivacyPane(): JSX.Element {
  const ctx = useSettings();
  const [clearOpen, setClearOpen] = useState(false);
  const [range, setRange] = useState<Range>('day');
  const [kinds, setKinds] = useState<Record<string, boolean>>({ history: true, downloads: false, cookies: false, site_data: false, cache: true });
  const [busy, setBusy] = useState(false);

  const selected = Object.entries(kinds)
    .filter(([, on]) => on)
    .map(([k]) => k);

  return (
    <div class="st-pane">
      <PaneHeader section="privacy" />

      <Group title="Site permissions">
        <Row id="privacy/site-permissions" label="Site Permissions" help="Camera, microphone, location, pop-ups, and more for each site.">
          <ChromeLinkButton url="chrome://settings/content">Open</ChromeLinkButton>
        </Row>
        <Row id="privacy/notifications" label="Notifications" help="Which sites may show notifications.">
          <ChromeLinkButton url="chrome://settings/content/notifications">Open</ChromeLinkButton>
        </Row>
        <Row id="privacy/cookies" label="Third-party cookies" help="Block cookies that track you across sites.">
          <ChromeLinkButton url="chrome://settings/cookies">Open</ChromeLinkButton>
        </Row>
      </Group>

      <Group title="Security">
        <PrefToggle id="privacy/https-only" label="Always use secure connections" help="Warn before you go to a site without HTTPS." prefKey="privacy.httpsOnly" />
        <PrefToggle id="privacy/do-not-track" label='Send a "Do Not Track" request' help="Most sites ignore it." prefKey="privacy.doNotTrack" />
        <Row id="privacy/search-suggestions" label="Search suggestions" help={`Ask ${ctx.profile?.settings.search_engine_id ?? 'your search engine'} for suggestions as you type.`} prefKey="search.suggestions">
          <Toggle checked={ctx.prefs['search.suggestions'] === true} label="Search suggestions" onChange={(v) => void ctx.setPref('search.suggestions', v)} />
        </Row>
        <Row id="privacy/safe-browsing" label="Safe Browsing" help="Open does not send the pages you visit to a blocklist service. Safe Browsing is off by design.">
          <Pill>Off</Pill>
        </Row>
      </Group>

      <Group title="Browsing data">
        <Row id="privacy/clear-data" label="Clear Browsing Data" help={`History, cookies, cache, and download history of ${ctx.profile?.name ?? 'this Profile'}.`}>
          <Btn onClick={() => setClearOpen(true)}>Clear…</Btn>
        </Row>
      </Group>

      <Group title="More">
        <Row id="privacy/security-settings" label="Security settings" help="Certificates and secure DNS.">
          <ChromeLinkButton url="chrome://settings/security">Open</ChromeLinkButton>
        </Row>
        <Row id="privacy/chromium-settings" label="More browser settings" help="All Chromium settings for this Profile.">
          <ChromeLinkButton url="chrome://settings">Open</ChromeLinkButton>
        </Row>
      </Group>

      <Modal
        open={clearOpen}
        title={`Clear Browsing Data · ${ctx.profile?.name ?? ''}`}
        onClose={() => setClearOpen(false)}
        footer={
          <>
            <Btn onClick={() => setClearOpen(false)}>Cancel</Btn>
            <Btn
              kind="danger"
              busy={busy}
              disabled={!selected.length}
              onClick={async () => {
                setBusy(true);
                const res = await ctx.run(() => rpc('settings.clearBrowsingData', { profile_id: ctx.profileId, range, kinds: selected }));
                setBusy(false);
                if (res?.ok) {
                  setClearOpen(false);
                  ctx.toast(`Cleared ${selected.length === 1 ? 'one kind' : `${selected.length} kinds`} of data.`, 'success');
                }
              }}
            >
              Clear Data
            </Btn>
          </>
        }
      >
        <Field label="Time range">
          <Select ariaLabel="Time range" wide value={range} options={RANGES} onChange={setRange} />
        </Field>
        <div class="st-checks">
          {KINDS.map((k) => (
            <Checkbox key={k.id} checked={kinds[k.id] === true} label={k.label} help={k.help} onChange={(v) => setKinds({ ...kinds, [k.id]: v })} />
          ))}
        </div>
      </Modal>
    </div>
  );
}

export function PasswordsPane(): JSX.Element {
  const ctx = useSettings();
  return (
    <div class="st-pane">
      <PaneHeader section="passwords" />
      <Group title="Passwords">
        <Row id="passwords/passwords" label="Passwords and passkeys" help="See, edit, export, and check your saved logins.">
          <ChromeLinkButton url="chrome://password-manager/passwords">Open Password Manager</ChromeLinkButton>
        </Row>
        <Row id="passwords/checkup" label="Password Checkup" help="Find reused and weak passwords.">
          <ChromeLinkButton url="chrome://password-manager/checkup">Check</ChromeLinkButton>
        </Row>
      </Group>
      <Group title="Autofill">
        <Row id="passwords/payments" label="Payment methods" help="Cards that Open fills in for you.">
          <ChromeLinkButton url="chrome://settings/payments">Open</ChromeLinkButton>
        </Row>
        <Row id="passwords/addresses" label="Addresses" help="Addresses and contact details.">
          <ChromeLinkButton url="chrome://settings/addresses">Open</ChromeLinkButton>
        </Row>
      </Group>
      <Group title="Sync">
        <Row
          id="passwords/sync"
          label="Sync passwords with your Open Account"
          help='Passwords sync end-to-end encrypted when "Passwords, Autofill & Site Permissions" is on.'
        >
          <Btn onClick={() => ctx.navigate('sync', 'sync/categories')}>Account & Sync</Btn>
        </Row>
      </Group>
    </div>
  );
}
