import type { JSX } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { type ImportKind, type ImportReceiptInfo, type ImportSource, RPC_EVENTS, rpc, subscribeEvent } from '../shared/bridge';
import { Modal } from '../shared/components';
import { ImportIcon } from '../shared/icons';
import { formatCount, relativeTime, useSettings } from './context';
import { Banner, Btn, Checkbox, EmptyRow, Field, Group, PaneHeader, Pill, Select, Spinner } from './ui';

const KIND_ORDER: Record<string, number> = { open_legacy: 0, arc: 1, safari: 2, chromium: 3, firefox: 4, html: 5 };

const KIND_CHOICES: Record<string, { kind: ImportKind; label: string; help: string }[]> = {
  open_legacy: [
    { kind: 'spaces', label: 'Spaces and tabs', help: 'Profiles, Spaces, pinned and Today tabs, folders, Split Views, and Favorites.' },
    { kind: 'history', label: 'History', help: '' },
    { kind: 'archive', label: 'Archive', help: '' },
    { kind: 'boosts', label: 'Boosts', help: '' },
    { kind: 'documents', label: 'Easels and Notes', help: '' },
    { kind: 'settings', label: 'Settings and shortcuts', help: 'Preferences, keyboard shortcuts, and ad blocking choices.' },
  ],
  arc: [
    { kind: 'spaces', label: 'Spaces and tabs', help: 'Spaces, pinned tabs, folders, Split Views, and Favorites.' },
    { kind: 'history', label: 'History', help: '' },
    { kind: 'archive', label: 'Archive', help: '' },
    { kind: 'boosts', label: 'Boosts', help: '' },
    { kind: 'documents', label: 'Easels and Notes', help: '' },
  ],
  safari: [
    { kind: 'bookmarks', label: 'Bookmarks', help: 'As a pinned folder in your current Space.' },
    { kind: 'history', label: 'History', help: '' },
  ],
  chromium: [
    { kind: 'bookmarks', label: 'Bookmarks', help: 'As a pinned folder in your current Space.' },
    { kind: 'history', label: 'History', help: '' },
  ],
  firefox: [
    { kind: 'bookmarks', label: 'Bookmarks', help: 'As a pinned folder in your current Space.' },
    { kind: 'history', label: 'History', help: '' },
  ],
};

const COUNT_LABELS: Record<string, string> = {
  spaces: 'Spaces',
  tabs: 'tabs',
  bookmarks: 'bookmarks',
  history: 'history entries',
  archive: 'archived tabs',
  boosts: 'Boosts',
  documents: 'Easels and Notes',
  preferences: 'settings',
  shortcuts: 'shortcuts',
};

function sourceTitle(s: ImportSource): string {
  if (s.kind === 'open_legacy') return 'Import from Open (Legacy)';
  if (s.kind === 'arc') return 'Import from Arc';
  return `Import from ${s.browser_name}`;
}

function summary(counts: Record<string, number>): string {
  const parts = Object.entries(counts)
    .filter(([, n]) => n > 0)
    .map(([k, n]) => `${formatCount(n)} ${COUNT_LABELS[k] ?? k}`);
  return parts.length ? parts.join(', ') : 'Nothing new to import';
}

export function ImportPane(): JSX.Element {
  const ctx = useSettings();
  const [sources, setSources] = useState<ImportSource[] | null>(null);
  const [receipts, setReceipts] = useState<ImportReceiptInfo[]>([]);
  const [active, setActive] = useState<ImportSource | null>(null);
  const [kinds, setKinds] = useState<Set<ImportKind>>(new Set());
  const [target, setTarget] = useState('');
  const [phase, setPhase] = useState<'idle' | 'running' | 'done' | 'denied' | 'error'>('idle');
  const [result, setResult] = useState<ImportReceiptInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [htmlName, setHtmlName] = useState<string | null>(null);
  const [progress, setProgress] = useState<string>('');

  const load = async () => {
    const [detected, past] = await Promise.all([ctx.run(() => rpc('settings.import.detect', {})), ctx.run(() => rpc('settings.import.receipts', {}))]);
    setSources(detected?.sources ?? []);
    if (past) setReceipts(past.receipts);
  };

  useEffect(() => {
    void load();
    return subscribeEvent(RPC_EVENTS.importProgress, (p) => {
      const phaseName = (p as { phase?: string } | null)?.phase;
      if (phaseName === 'reading') setProgress('Reading your data…');
      else if (phaseName === 'done') setProgress('Adding it to Open…');
    });
  }, []);

  const grouped = useMemo(() => [...(sources ?? [])].sort((a, b) => (KIND_ORDER[a.kind] ?? 9) - (KIND_ORDER[b.kind] ?? 9)), [sources]);

  const start = (source: ImportSource) => {
    setActive(source);
    setKinds(new Set((KIND_CHOICES[source.kind] ?? []).map((c) => c.kind)));
    setTarget(ctx.profileId || ctx.profiles[0]?.id || '');
    setPhase(source.access_denied ? 'denied' : 'idle');
    setResult(null);
    setError(null);
  };

  const run = async () => {
    if (!active) return;
    setPhase('running');
    setProgress('Reading your data…');
    try {
      const res = await rpc('settings.import.run', { source_id: active.id, kinds: [...kinds], target_profile_id: target });
      if (!res.ok) {
        setPhase(res.access_denied ? 'denied' : 'error');
        setError(res.error ?? 'The import did not finish.');
        return;
      }
      setResult(res.receipt ?? null);
      setPhase('done');
      if (res.receipt) setReceipts((prev) => [res.receipt as ImportReceiptInfo, ...prev.filter((r) => r.receipt_id !== res.receipt?.receipt_id)]);
      await Promise.all([ctx.reloadProfiles(), ctx.reloadSpaces()]);
    } catch (e) {
      setPhase('error');
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const undo = async (receipt: ImportReceiptInfo) => {
    const res = await ctx.run(() => rpc('settings.import.undo', { receipt_id: receipt.receipt_id }), `Undid the import from ${receipt.source_name}.`);
    if (!res) return;
    setReceipts((prev) => prev.map((r) => (r.receipt_id === res.receipt.receipt_id ? res.receipt : r)));
    if (result?.receipt_id === res.receipt.receipt_id) setResult(res.receipt);
    await Promise.all([ctx.reloadProfiles(), ctx.reloadSpaces()]);
  };

  const htmlSource: ImportSource = {
    id: 'html',
    kind: 'html',
    browser_id: 'html',
    browser_name: 'Bookmarks File',
    profile_name: htmlName ?? '',
    is_default: true,
    bookmarks_count: 0,
    history_count: 0,
    access_denied: false,
    read_only: true,
  };

  return (
    <div class="st-pane">
      <PaneHeader section="import" />

      <Group title="From another browser">
        <div id="row-import-sources" />
        {sources === null && (
          <div class="st-empty-row">
            <Spinner /> Looking for browsers on this computer…
          </div>
        )}
        {sources?.length === 0 && <EmptyRow>No other browsers were found on this computer.</EmptyRow>}
        {grouped.map((s) => (
          <div key={s.id} class="st-row st-source-row">
            <span class={`st-source-badge is-${s.kind}`} aria-hidden="true">
              {s.browser_name.slice(0, 1)}
            </span>
            <div class="st-row-meta">
              <div class="st-row-label">
                {sourceTitle(s)}
                {s.read_only && <Pill tone="success">Read-only</Pill>}
                {s.access_denied && <Pill tone="warning">Needs access</Pill>}
              </div>
              <div class="st-row-help">
                {s.profile_name !== s.browser_name ? `${s.profile_name} · ` : ''}
                {s.access_denied
                  ? 'Open needs Full Disk Access to read it.'
                  : `${formatCount(s.bookmarks_count)} ${s.kind === 'arc' || s.kind === 'open_legacy' ? 'tabs' : 'bookmarks'} · ${formatCount(s.history_count)} history entries`}
              </div>
            </div>
            <div class="st-row-control">
              <Btn onClick={() => start(s)}>Import…</Btn>
            </div>
          </div>
        ))}
      </Group>

      <Group title="From a file">
        <div id="row-import-html" class="st-row">
          <div class="st-row-meta">
            <div class="st-row-label">Import Bookmarks HTML</div>
            <div class="st-row-help">{htmlName ? `Chosen: ${htmlName}` : 'A bookmarks file exported from any browser.'}</div>
          </div>
          <div class="st-row-control">
            <Btn
              onClick={async () => {
                const res = await ctx.run(() => rpc('settings.import.pickHtml', {}));
                if (!res || res.canceled) return;
                setHtmlName(res.name ?? res.path ?? 'bookmarks.html');
                start({ ...htmlSource, profile_name: res.name ?? '' });
              }}
            >
              Choose File…
            </Btn>
          </div>
        </div>
      </Group>

      <Group title="Recent imports">
        <div id="row-import-undo" />
        {receipts.length === 0 ? (
          <EmptyRow>Imports you run show up here, so you can undo them.</EmptyRow>
        ) : (
          receipts.map((r) => (
            <div key={r.receipt_id} class="st-row">
              <div class="st-row-meta">
                <div class="st-row-label">
                  {r.source_name} {r.undone && <Pill>Undone</Pill>}
                </div>
                <div class="st-row-help">
                  {relativeTime(r.imported_at)} · {summary(r.counts)}
                </div>
              </div>
              <div class="st-row-control">{!r.undone && <Btn onClick={() => void undo(r)}>Undo Import</Btn>}</div>
            </div>
          ))
        )}
      </Group>

      <Modal
        open={active !== null}
        title={active ? (active.kind === 'html' ? 'Import Bookmarks' : sourceTitle(active)) : ''}
        onClose={() => phase !== 'running' && setActive(null)}
        footer={
          phase === 'done' ? (
            <>
              {result && !result.undone && <Btn onClick={() => result && void undo(result)}>Undo Import</Btn>}
              <Btn kind="primary" onClick={() => setActive(null)}>
                Done
              </Btn>
            </>
          ) : phase === 'denied' ? (
            <>
              <Btn onClick={() => setActive(null)}>Close</Btn>
              <Btn kind="primary" onClick={() => void run()}>
                Try Again
              </Btn>
            </>
          ) : (
            <>
              <Btn disabled={phase === 'running'} onClick={() => setActive(null)}>
                Cancel
              </Btn>
              <Btn kind="primary" busy={phase === 'running'} disabled={active?.kind !== 'html' && kinds.size === 0} onClick={() => void run()}>
                Import
              </Btn>
            </>
          )
        }
      >
        {active?.kind === 'open_legacy' && phase === 'idle' && (
          <Banner tone="success" title="Read-only">
            Open reads your old Open data and never changes or deletes it.
          </Banner>
        )}
        {phase === 'denied' && (
          <Banner tone="warning" title="Open needs Full Disk Access">
            <ol class="st-steps">
              <li>Open System Settings, then Privacy & Security.</li>
              <li>Choose Full Disk Access.</li>
              <li>Turn on Open. Add it with the + button if it is not in the list.</li>
              <li>Quit and reopen Open, then try again.</li>
            </ol>
          </Banner>
        )}
        {phase === 'idle' && active && (
          <>
            {active.kind === 'html' ? (
              <p class="st-dialog-text">The bookmarks of {active.profile_name || 'the file'} go into a pinned folder in your current Space.</p>
            ) : (
              <div class="st-checks">
                {(KIND_CHOICES[active.kind] ?? []).map((c) => (
                  <Checkbox
                    key={c.kind}
                    checked={kinds.has(c.kind)}
                    label={c.label}
                    {...(c.help ? { help: c.help } : {})}
                    onChange={(on) => {
                      const next = new Set(kinds);
                      if (on) next.add(c.kind);
                      else next.delete(c.kind);
                      setKinds(next);
                    }}
                  />
                ))}
              </div>
            )}
            {ctx.profiles.length > 1 && (
              <Field label="Into Profile" hint="Arc and legacy Open imports also bring their own Profiles.">
                <Select ariaLabel="Into Profile" wide value={target} options={ctx.profiles.map((p) => ({ value: p.id, label: p.name }))} onChange={setTarget} />
              </Field>
            )}
          </>
        )}
        {phase === 'running' && (
          <div class="st-progress">
            <Spinner /> {progress || 'Importing…'}
          </div>
        )}
        {phase === 'error' && error && <Banner tone="danger">{error}</Banner>}
        {phase === 'done' && result && (
          <div class="st-import-done">
            <span class="st-import-done-icon" aria-hidden="true">
              <ImportIcon size={20} />
            </span>
            <div>
              <div class="st-row-label">{result.undone ? 'The import was undone.' : `Imported from ${result.source_name}`}</div>
              <div class="st-row-help">{summary(result.counts)}</div>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
}
