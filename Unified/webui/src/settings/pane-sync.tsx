import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type InitialSyncStrategy, RPC_EVENTS, type SyncDetailedStatus, type SyncMutationResult, rpc, subscribeEvent } from '../shared/bridge';
import { Modal, SegmentedControl, Toggle } from '../shared/components';
import { CloudIcon, CopyIcon } from '../shared/icons';
import { errorMessage, plural, relativeTime, useSettings } from './context';
import { Banner, Btn, Checkbox, ConfirmDialog, Field, Group, PaneHeader, Pill, Row, TextInput } from './ui';

// SyncCategoryToString names (core/sync/sync_engine.cc).
const CATEGORIES: { id: string; title: string; help: string }[] = [
  { id: 'workspace', title: 'Spaces and pinned tabs', help: 'Profiles, Spaces, folders, Favorites, and Air Traffic Control rules.' },
  { id: 'todayTabs', title: 'Today tabs', help: 'Unpinned tabs of each Space.' },
  { id: 'archive', title: 'Archive', help: 'The 2,000 most recent archived tabs of each Profile.' },
  { id: 'settingsAndShortcuts', title: 'Settings and shortcuts', help: 'Portable preferences and your keyboard shortcuts.' },
  { id: 'adBlocking', title: 'Ad blocking', help: 'Block lists and allowed sites.' },
  { id: 'boostsEaselsNotes', title: 'Boosts, Easels, and Notes', help: 'With their images, encrypted.' },
  { id: 'history', title: 'History', help: 'The 5,000 most recent pages of each Profile.' },
  { id: 'extensions', title: 'Extensions', help: 'Which extensions are installed and pinned.' },
  { id: 'credentialsAndPermissions', title: 'Passwords, Autofill & Site Permissions', help: 'Encrypted before they leave this computer.' },
];

const SELF_HOST_PROMPT = `Set up a private Open Sync Server for my Open browser from the Open repository (the \`SyncServer/\` folder).
1. Build and run \`SyncServer/\` with its Dockerfile (Node.js 22+, built-in SQLite and WebSockets).
2. Run one instance with persistent storage at /data and OPEN_SYNC_DATA_DIR=/data.
3. Expose HTTPS, forward WebSocket upgrades on /v1/sync/ws, and set OPEN_SYNC_TRUST_PROXY=1.
4. Check that GET <url>/health returns {"ok":true,"service":"open-sync","version":1}, then tell me the final https:// URL.`;

const DOCKER_COMMAND = 'docker run -d --name open-sync -p 8787:8787 -v open-sync-data:/data -e OPEN_SYNC_DATA_DIR=/data open-sync-server';

type Mode = 'signin' | 'signup' | 'recover';

/** "Just now" -> "just now" inside a sentence; dates keep their case. */
function lowerPhrase(text: string): string {
  return /^(Just now|Yesterday|Never)$/.test(text) ? text.toLowerCase() : text;
}

export function SyncPane(): JSX.Element {
  const ctx = useSettings();
  const [status, setStatus] = useState<SyncDetailedStatus | null>(null);
  const [mode, setMode] = useState<Mode>('signin');
  const [server, setServer] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [recoveryKey, setRecoveryKey] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [newKey, setNewKey] = useState<string | null>(null);
  const [nameDraft, setNameDraft] = useState<string | null>(null);
  const [pwOpen, setPwOpen] = useState(false);
  const [pw, setPw] = useState({ current: '', next: '', confirm: '', revoke: true });
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [deletePw, setDeletePw] = useState('');
  const [signOutOpen, setSignOutOpen] = useState(false);

  const load = async () => {
    try {
      const s = await rpc('settings.sync.getStatus', {});
      setStatus(s);
      setServer((prev) => prev || s.server_url);
    } catch (error) {
      ctx.toast(errorMessage(error), 'danger');
    }
  };

  useEffect(() => {
    void load();
    // The event carries four fields; fetch the full status instead of
    // replacing it.
    let timer = 0;
    const off = subscribeEvent(RPC_EVENTS.syncStatusChanged, () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => void rpc('settings.sync.getStatus', { refresh_devices: false }).then(setStatus).catch(() => undefined), 150);
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, []);

  const mutate = async (key: string, task: () => Promise<SyncMutationResult>, success?: string) => {
    setBusy(key);
    setFormError(null);
    try {
      const res = await task();
      setStatus(res.status);
      if (res.recovery_key) setNewKey(res.recovery_key);
      if (success) ctx.toast(success, 'success');
      return res;
    } catch (error) {
      setFormError(errorMessage(error));
      return null;
    } finally {
      setBusy(null);
    }
  };

  const submitAuth = async () => {
    if (mode === 'signin') {
      const res = await mutate('auth', () => rpc('settings.sync.signIn', { server_url: server, email, password }));
      if (res) setPassword('');
    } else if (mode === 'signup') {
      const res = await mutate('auth', () => rpc('settings.sync.signUp', { server_url: server, email, password, display_name: displayName }), 'Your Open Account is ready.');
      if (res) setPassword('');
    } else {
      const res = await mutate('auth', () => rpc('settings.sync.recover', { server_url: server, email, recovery_key: recoveryKey, new_password: password }), 'Your account is recovered.');
      if (res) {
        setPassword('');
        setRecoveryKey('');
      }
    }
  };

  const copy = async (text: string, message: string) => {
    try {
      await navigator.clipboard.writeText(text);
      ctx.toast(message, 'success');
    } catch {
      ctx.toast('Copy is not available here.', 'danger');
    }
  };

  if (!status) {
    return (
      <div class="st-pane">
        <PaneHeader section="sync" />
        <div class="st-empty-row">Loading your account…</div>
      </div>
    );
  }

  // --- Signed out -----------------------------------------------------------
  if (!status.signed_in) {
    return (
      <div class="st-pane">
        <PaneHeader section="sync" />
        <div class="st-sync-intro" id="row-sync-account">
          <span class="st-sync-intro-icon" aria-hidden="true">
            <CloudIcon size={22} />
          </span>
          <div>
            <div class="st-sync-intro-title">Your Spaces on every computer</div>
            <div class="st-row-help">Open encrypts everything on this computer before it syncs. Your server never sees your tabs, history, or passwords.</div>
          </div>
        </div>
        <Group>
          <div class="st-auth">
            <SegmentedControl
              ariaLabel="Account action"
              value={mode}
              options={[
                { value: 'signin', label: 'Sign In' },
                { value: 'signup', label: 'Create Account' },
                { value: 'recover', label: 'Recover' },
              ]}
              onChange={(m) => {
                setMode(m);
                setFormError(null);
              }}
            />
            <form
              class="st-auth-form"
              onSubmit={(e) => {
                e.preventDefault();
                void submitAuth();
              }}
            >
              <Field label="Sync server" hint="Your self-hosted Open Sync server.">
                <TextInput value={server} onInput={setServer} ariaLabel="Sync server" type="url" placeholder="https://sync.example.com" mono />
              </Field>
              {mode === 'signup' && (
                <Field label="Name">
                  <TextInput value={displayName} onInput={setDisplayName} ariaLabel="Your name" placeholder="Alex" />
                </Field>
              )}
              <Field label="Email">
                <TextInput value={email} onInput={setEmail} ariaLabel="Email" type="email" placeholder="you@example.com" />
              </Field>
              {mode === 'recover' && (
                <Field label="Recovery key">
                  <TextInput value={recoveryKey} onInput={setRecoveryKey} ariaLabel="Recovery key" placeholder="OPEN-XXXX-XXXX-…" mono />
                </Field>
              )}
              <Field label={mode === 'signin' ? 'Password' : 'New password'} hint={mode === 'signin' ? undefined : 'At least 8 characters.'}>
                <TextInput value={password} onInput={setPassword} ariaLabel="Password" type="password" />
              </Field>
              {formError && <Banner tone="warning">{formError}</Banner>}
              <div class="st-auth-actions">
                <Btn
                  onClick={async () => {
                    setBusy('server');
                    try {
                      setStatus(await rpc('settings.sync.setServerUrl', { server_url: server }));
                      ctx.toast('Server saved.', 'success');
                      setFormError(null);
                    } catch (error) {
                      setFormError(errorMessage(error));
                    } finally {
                      setBusy(null);
                    }
                  }}
                  busy={busy === 'server'}
                >
                  Save Server
                </Btn>
                <Btn kind="primary" type="submit" busy={busy === 'auth'}>
                  {mode === 'signin' ? 'Sign In' : mode === 'signup' ? 'Create Account' : 'Recover Account'}
                </Btn>
              </div>
            </form>
          </div>
        </Group>

        <Group title="Need a sync server?">
          <Row id="sync/self-host" label="Run your own Open Sync server" help="Copy a setup prompt for an AI coding agent, or a Docker command.">
            <Btn onClick={() => void copy(SELF_HOST_PROMPT, 'Setup prompt copied.')}>
              <CopyIcon size={12} /> Agent Prompt
            </Btn>
            <Btn onClick={() => void copy(DOCKER_COMMAND, 'Docker command copied.')}>
              <CopyIcon size={12} /> Docker
            </Btn>
          </Row>
        </Group>
        <RecoveryKeyDialog keyText={newKey} onClose={() => setNewKey(null)} onCopy={(k) => void copy(k, 'Recovery key copied.')} />
      </div>
    );
  }

  // --- Signed in --------------------------------------------------------------
  const initials = (status.display_name || status.email || '?')
    .split(/[\s@.]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase())
    .join('');
  const live = status.ws_connected;
  const saveDisplayName = async () => {
    if (nameDraft === null || busy === 'name') return;
    const res = await mutate('name', () => rpc('settings.sync.updateDisplayName', { display_name: nameDraft }), 'Name saved.');
    if (res) setNameDraft(null);
  };

  return (
    <div class="st-pane">
      <PaneHeader section="sync" />

      {status.initial_sync_required && (
        <div class="st-initial" id="row-sync-initial">
          <div class="st-initial-title">This account already has data</div>
          <p class="st-row-help">
            Choose what Open does with the {status.cloud_summary ? plural(Object.values(status.cloud_summary.collection_counts).reduce((a, b) => a + b, 0), 'item') : 'items'} on the server and the setup on this
            computer.
          </p>
          <div class="st-initial-options">
            {(
              [
                ['merge', 'Merge', 'Keep both. Spaces and tabs from both sides are combined.'],
                ['use_server', 'Use Server', 'Replace this computer’s setup with the server’s.'],
                ['use_local', 'Use This Computer', 'Replace the server’s data with this setup.'],
              ] as [InitialSyncStrategy, string, string][]
            ).map(([strategy, title, help]) => (
              <button
                key={strategy}
                type="button"
                class="st-initial-option"
                disabled={busy !== null}
                onClick={() => void mutate(strategy, () => rpc('settings.sync.completeInitialSync', { strategy }), 'Sync is on.')}
              >
                <span class="st-initial-option-title">{busy === strategy ? 'Working…' : title}</span>
                <span class="st-row-help">{help}</span>
              </button>
            ))}
          </div>
          {formError && <Banner tone="warning">{formError}</Banner>}
        </div>
      )}

      <div class="st-account" id="row-sync-account">
        <span class="st-account-avatar" aria-hidden="true">
          {initials}
        </span>
        <div class="st-account-meta">
          {nameDraft === null ? (
            <div class="st-account-name">
              {status.display_name || 'Open Account'}
              <button type="button" class="st-link-btn" onClick={() => setNameDraft(status.display_name)}>
                Edit
              </button>
            </div>
          ) : (
            <div class="st-inline-edit">
              <TextInput value={nameDraft} onInput={setNameDraft} ariaLabel="Display name" autoFocus onEnter={() => void saveDisplayName()} />
              <Btn small kind="primary" busy={busy === 'name'} onClick={() => void saveDisplayName()}>
                Save
              </Btn>
              <Btn small onClick={() => setNameDraft(null)}>
                Cancel
              </Btn>
            </div>
          )}
          <div class="st-row-help">{status.email}</div>
          <div class="st-row-help st-mono">{status.server_url}</div>
        </div>
        <Pill tone={live ? 'success' : 'warning'}>
          <span class={`st-live-dot${live ? ' is-live' : ''}`} /> {live ? 'Connected' : 'Reconnecting'}
        </Pill>
      </div>

      {status.error_message && <Banner tone="danger" title="Sync stopped">{status.error_message}</Banner>}
      {formError && !status.initial_sync_required && <Banner tone="warning">{formError}</Banner>}
      {status.warnings.map((w) => (
        <Banner key={w} tone="info">
          {w}
        </Banner>
      ))}

      <Group title="Sync">
        <Row
          id="sync/sync-now"
          label="Sync Now"
          help={`Last synced ${lowerPhrase(relativeTime(status.last_sync_at_ms ? status.last_sync_at_ms / 1000 : undefined))} · ${
            status.pending_push_count ? `${plural(status.pending_push_count, 'change')} waiting` : 'nothing waiting'
          }`}
        >
          <Btn kind="primary" busy={busy === 'now' || status.is_busy} disabled={status.initial_sync_required} onClick={() => void mutate('now', () => rpc('settings.sync.syncNow', {}), 'Synced.')}>
            Sync Now
          </Btn>
        </Row>
      </Group>

      <Group title="What to sync">
        <div id="row-sync-categories" />
        {CATEGORIES.map((c) => (
          <Row key={c.id} id={`sync/category-${c.id}`} label={c.title} help={c.help}>
            <Toggle
              checked={status.categories[c.id] !== false}
              label={c.title}
              onChange={async (enabled) => {
                const res = await ctx.run(() => rpc('settings.sync.setCategory', { category: c.id, enabled }));
                if (res) setStatus(res);
              }}
            />
          </Row>
        ))}
      </Group>

      <Group title="Devices">
        <div id="row-sync-devices" />
        {status.devices_error && <Banner tone="warning">{status.devices_error}</Banner>}
        {status.devices.map((d) => (
          <Row
            key={d.id}
            id={`sync/device-${d.id}`}
            label={
              <>
                {d.name} {d.is_current && <Pill tone="accent">This computer</Pill>}
              </>
            }
            help={`${d.platform} · last seen ${lowerPhrase(relativeTime(d.last_seen_at))}`}
          >
            {!d.is_current && (
              <Btn small busy={busy === `revoke-${d.id}`} onClick={() => void mutate(`revoke-${d.id}`, () => rpc('settings.sync.revokeDevice', { device_id: d.id }), `${d.name} is signed out.`)}>
                Revoke
              </Btn>
            )}
          </Row>
        ))}
      </Group>

      <Group title="Account security">
        <Row id="sync/security" label="Password" help="Changing it keeps your data. Other devices sign in again if you choose.">
          <Btn onClick={() => setPwOpen(true)}>Change Password…</Btn>
        </Row>
        <Row id="sync/sign-out" label="Sign out of this computer" help="Your data stays here and on the server.">
          <Btn onClick={() => setSignOutOpen(true)}>Sign Out…</Btn>
        </Row>
      </Group>

      <Group title="Danger zone">
        <Row id="sync/delete" label="Delete account" help="Deletes your encrypted data from the server. This computer keeps its copy.">
          <Btn kind="danger" onClick={() => setDeleteOpen(true)}>
            Delete Account…
          </Btn>
        </Row>
      </Group>

      <Modal
        open={pwOpen}
        title="Change Password"
        onClose={() => setPwOpen(false)}
        footer={
          <>
            <Btn onClick={() => setPwOpen(false)}>Cancel</Btn>
            <Btn
              kind="primary"
              busy={busy === 'pw'}
              disabled={!pw.current || pw.next.length < 8 || pw.next !== pw.confirm}
              onClick={async () => {
                const res = await mutate(
                  'pw',
                  () => rpc('settings.sync.changePassword', { current_password: pw.current, new_password: pw.next, revoke_other_sessions: pw.revoke }),
                  'Password changed.',
                );
                if (res) {
                  setPwOpen(false);
                  setPw({ current: '', next: '', confirm: '', revoke: true });
                }
              }}
            >
              Change Password
            </Btn>
          </>
        }
      >
        <Field label="Current password">
          <TextInput value={pw.current} onInput={(v) => setPw({ ...pw, current: v })} ariaLabel="Current password" type="password" autoFocus />
        </Field>
        <Field label="New password" hint="At least 8 characters.">
          <TextInput value={pw.next} onInput={(v) => setPw({ ...pw, next: v })} ariaLabel="New password" type="password" />
        </Field>
        <Field label="Confirm new password">
          <TextInput value={pw.confirm} onInput={(v) => setPw({ ...pw, confirm: v })} ariaLabel="Confirm new password" type="password" invalid={!!pw.confirm && pw.confirm !== pw.next} />
        </Field>
        <Checkbox checked={pw.revoke} label="Sign out my other devices" onChange={(v) => setPw({ ...pw, revoke: v })} />
        {formError && <Banner tone="warning">{formError}</Banner>}
      </Modal>

      <ConfirmDialog
        open={signOutOpen}
        title="Sign out of Open Sync?"
        confirmLabel="Sign Out"
        busy={busy === 'signout'}
        onConfirm={async () => {
          const res = await mutate('signout', () => rpc('settings.sync.signOut', {}), 'Signed out.');
          if (res) setSignOutOpen(false);
        }}
        onClose={() => setSignOutOpen(false)}
      >
        <p class="st-dialog-text">This computer stops syncing. Nothing is deleted.</p>
      </ConfirmDialog>

      <ConfirmDialog
        open={deleteOpen}
        title="Delete your Open Account?"
        confirmLabel="Delete Account"
        danger
        busy={busy === 'delete'}
        confirmDisabled={!deletePw}
        onConfirm={async () => {
          const res = await mutate('delete', () => rpc('settings.sync.deleteAccount', { password: deletePw }), 'Your account was deleted.');
          if (res) {
            setDeleteOpen(false);
            setDeletePw('');
          }
        }}
        onClose={() => setDeleteOpen(false)}
      >
        <Banner tone="danger" title="This cannot be undone.">
          Every device loses sync. The encrypted data on the server is deleted.
        </Banner>
        <Field label="Password">
          <TextInput value={deletePw} onInput={setDeletePw} ariaLabel="Password" type="password" />
        </Field>
        {formError && <Banner tone="warning">{formError}</Banner>}
      </ConfirmDialog>

      <RecoveryKeyDialog keyText={newKey} onClose={() => setNewKey(null)} onCopy={(k) => void copy(k, 'Recovery key copied.')} />
    </div>
  );
}

function RecoveryKeyDialog({ keyText, onClose, onCopy }: { keyText: string | null; onClose: () => void; onCopy: (key: string) => void }): JSX.Element | null {
  const [saved, setSaved] = useState(false);
  return (
    <Modal
      open={keyText !== null}
      title="Save your recovery key"
      onClose={() => saved && onClose()}
      footer={
        <Btn kind="primary" disabled={!saved} onClick={onClose}>
          Done
        </Btn>
      }
    >
      <p class="st-dialog-text">It is the only way back into your encrypted data if you forget your password. Open cannot show it again.</p>
      <div class="st-recovery-key">
        <code>{keyText}</code>
        <Btn small onClick={() => keyText && onCopy(keyText)}>
          <CopyIcon size={12} /> Copy
        </Btn>
      </div>
      <Checkbox checked={saved} label="I saved my recovery key" onChange={setSaved} />
    </Modal>
  );
}
