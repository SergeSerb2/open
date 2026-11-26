import type { JSX } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { type CommandPriority, type ShortcutEntry, type ShortcutsState, isNativeWebUI, rpc } from '../shared/bridge';
import { SegmentedControl } from '../shared/components';
import { ChevronDownIcon, ChevronRightIcon, SearchIcon } from '../shared/icons';
import { formatShortcut } from '../shared/shortcuts';
import { fold } from './sections';
import { useSettings } from './context';
import { Banner, Btn, ConfirmDialog, Group, KeyRecorder, Keycaps, PaneHeader, Pill, Row, Select, rowDomId } from './ui';

type Filter = 'all' | 'changed' | 'unassigned' | 'conflicts';

const PRIORITY_OPTIONS: { value: CommandPriority; label: string }[] = [
  { value: 'browser', label: 'Open first' },
  { value: 'site', label: 'Website first' },
  { value: 'site-then-browser', label: 'Website, then Open on a second press' },
];

export function ShortcutsPane(): JSX.Element {
  const ctx = useSettings();
  const [state, setState] = useState<ShortcutsState | null>(null);
  const [query, setQuery] = useState('');
  const [findKeys, setFindKeys] = useState<string | null>(null);
  const [findingKeys, setFindingKeys] = useState(false);
  const [filter, setFilter] = useState<Filter>('all');
  const [category, setCategory] = useState('all');
  const [recordingId, setRecordingId] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ id: string; other: string } | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [resetAll, setResetAll] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const fileRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    void ctx.run(() => rpc('settings.shortcuts.list', {})).then((res) => res && setState(res));
  }, []);

  const apply = (res: ShortcutsState | null, message = 'Saved.') => {
    if (!res) return;
    setState(res);
    setStatus(message);
  };

  const byId = useMemo(() => new Map((state?.shortcuts ?? []).map((s) => [s.id, s] as const)), [state]);
  const categories = useMemo(() => [...new Set((state?.shortcuts ?? []).map((s) => s.category))].sort(), [state]);

  const visible = useMemo(() => {
    const words = fold(query).split(/\s+/).filter(Boolean);
    return (state?.shortcuts ?? []).filter((s) => {
      if (filter === 'changed' && !s.modified) return false;
      if (filter === 'unassigned' && s.keys) return false;
      if (filter === 'conflicts' && !s.conflict_with) return false;
      if (category !== 'all' && s.category !== category) return false;
      if (findKeys && !s.all_keys.includes(findKeys)) return false;
      if (!words.length) return true;
      const hay = fold(`${s.title} ${s.menu_title} ${s.category} ${s.aliases.join(' ')} ${s.all_keys.map((k) => formatShortcut(k)).join(' ')}`);
      return words.every((w) => hay.includes(w));
    });
  }, [state, query, filter, category, findKeys]);

  const setKeys = async (entry: ShortcutEntry, keys: string) => {
    setRecordingId(null);
    const res = await ctx.run(() => (keys ? rpc('settings.shortcuts.set', { id: entry.id, keys }) : rpc('settings.shortcuts.clear', { id: entry.id })));
    apply(res, keys ? `${entry.title}: ${formatShortcut(keys)}.` : `${entry.title} has no shortcut now.`);
    setNotice(res?.conflict ? { id: entry.id, other: res.conflict } : null);
  };

  const counts = state?.counts ?? { modified: 0, unassigned: 0, conflicts: 0 };
  const chips: { id: Filter; label: string; count: number }[] = [
    { id: 'all', label: 'All', count: state?.shortcuts.length ?? 0 },
    { id: 'changed', label: 'Changed', count: counts.modified },
    { id: 'unassigned', label: 'Unassigned', count: counts.unassigned },
    { id: 'conflicts', label: 'Conflicts', count: counts.conflicts },
  ];

  const conflictEntry = notice ? byId.get(notice.other) : undefined;
  const noticeEntry = notice ? byId.get(notice.id) : undefined;

  return (
    <div class="st-pane">
      <PaneHeader
        section="shortcuts"
        right={
          <div class="st-header-actions">
            <Btn onClick={() => setResetAll(true)}>Reset all…</Btn>
            <div class="st-menu">
              <Btn kind="ghost" onClick={() => setMenuOpen(!menuOpen)}>
                More <ChevronDownIcon size={11} />
              </Btn>
              {menuOpen && (
                <div class="st-menu-pop" role="menu" onMouseLeave={() => setMenuOpen(false)}>
                  <button
                    type="button"
                    role="menuitem"
                    onClick={async () => {
                      setMenuOpen(false);
                      const res = await ctx.run(() => rpc('settings.shortcuts.exportJson', {}));
                      if (res?.ok) ctx.toast(`Exported to ${res.path ?? 'a file'}.`, 'success');
                    }}
                  >
                    Export Shortcuts…
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    onClick={async () => {
                      setMenuOpen(false);
                      // The browser shows a native file picker; the preview
                      // reads the file in the page.
                      const res = await ctx.run(() => rpc('settings.shortcuts.importJson', {}));
                      if (res && res.ok) apply(res, `Imported ${res.applied ?? 0} shortcuts${res.skipped ? `, skipped ${res.skipped}` : ''}.`);
                      else if (res?.canceled && !isNativeWebUI()) fileRef.current?.click();
                    }}
                  >
                    Import Shortcuts…
                  </button>
                </div>
              )}
            </div>
          </div>
        }
      />
      <input
        ref={fileRef}
        type="file"
        accept="application/json,.json"
        hidden
        onChange={async (e) => {
          const file = (e.currentTarget as HTMLInputElement).files?.[0];
          if (!file) return;
          const json = await file.text();
          const res = await ctx.run(() => rpc('settings.shortcuts.importJson', { json }));
          if (res?.ok) apply(res, `Imported ${res.applied ?? 0} shortcuts${res.skipped ? `, skipped ${res.skipped}` : ''}.`);
          (e.currentTarget as HTMLInputElement).value = '';
        }}
      />

      <div class="st-find">
        <span class="st-find-icon" aria-hidden="true">
          <SearchIcon size={14} />
        </span>
        {findingKeys ? (
          <KeyRecorder
            value=""
            onCancel={() => setFindingKeys(false)}
            onRecord={(keys) => {
              setFindingKeys(false);
              setFindKeys(keys || null);
            }}
          />
        ) : findKeys ? (
          <span class="st-find-keys">
            Commands using <Keycaps keys={findKeys} />
          </span>
        ) : (
          <input
            class="st-find-input"
            value={query}
            placeholder="Find a command"
            aria-label="Find a command"
            onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)}
          />
        )}
        <button
          type="button"
          class="st-find-mode"
          onClick={() => {
            if (findKeys) setFindKeys(null);
            else setFindingKeys(!findingKeys);
          }}
        >
          {findKeys ? 'Clear keys' : findingKeys ? 'Cancel' : 'Press keys'}
        </button>
      </div>

      <div class="st-chips" role="toolbar" aria-label="Filter shortcuts">
        {chips.map((chip) => (
          <button key={chip.id} type="button" class={`st-chip${filter === chip.id ? ' is-on' : ''}`} aria-pressed={filter === chip.id} onClick={() => setFilter(chip.id)}>
            {chip.label} <span class="st-chip-count">{chip.count}</span>
          </button>
        ))}
        <span class="st-chip-sep" />
        <Select
          ariaLabel="Category"
          value={category}
          options={[{ value: 'all', label: 'Category' }, ...categories.map((c) => ({ value: c, label: c }))]}
          onChange={setCategory}
        />
      </div>

      {notice && noticeEntry && (
        <Banner
          tone="warning"
          title={`${formatShortcut(noticeEntry.keys)} is also used by “${conflictEntry?.title ?? notice.other}”.`}
          action={
            <>
              <Btn
                small
                onClick={async () => {
                  const res = await ctx.run(() => rpc('settings.shortcuts.clear', { id: notice.other }));
                  apply(res, `Removed it from ${conflictEntry?.title ?? 'the other command'}.`);
                  setNotice(null);
                }}
              >
                Remove from Other
              </Btn>
              <Btn
                small
                onClick={async () => {
                  const res = await ctx.run(() => rpc('settings.shortcuts.reset', { id: notice.id }));
                  apply(res, 'Change undone.');
                  setNotice(null);
                }}
              >
                Undo
              </Btn>
            </>
          }
        >
          The command with the higher priority runs. You can keep both.
        </Banner>
      )}

      <div class="st-card st-shortcut-list" id="row-shortcuts-list">
        {!state && <div class="st-empty-row">Loading shortcuts…</div>}
        {state && visible.length === 0 && <div class="st-empty-row">No commands match.</div>}
        {visible.map((s) => {
          const domId = rowDomId(`shortcuts/${s.id}`);
          const open = expanded === s.id;
          return (
            <div key={s.id} id={domId} class={`st-shortcut${ctx.pulsingRow === domId ? ' is-pulsing' : ''}${s.conflict_with ? ' has-conflict' : ''}`}>
              <div class="st-shortcut-main">
                <button type="button" class="st-disclose" aria-expanded={open} aria-label={`Details for ${s.title}`} onClick={() => setExpanded(open ? null : s.id)}>
                  <ChevronRightIcon size={11} />
                </button>
                <div class="st-shortcut-title">
                  {s.modified && <span class="st-changed-dot" title="Changed from the default" />}
                  <span>{s.title}</span>
                  <span class="st-shortcut-cat">{s.category}</span>
                  {s.global && <Pill tone="accent">Global</Pill>}
                  {s.conflict_with && <Pill tone="warning">Conflict</Pill>}
                </div>
                <div class="st-shortcut-actions">
                  {s.keys && recordingId !== s.id && (
                    <button type="button" class="st-link-btn" onClick={() => void setKeys(s, '')}>
                      Clear
                    </button>
                  )}
                  {s.modified && recordingId !== s.id && (
                    <button
                      type="button"
                      class="st-link-btn"
                      onClick={async () => apply(await ctx.run(() => rpc('settings.shortcuts.reset', { id: s.id })), `${s.title} is back to its default.`)}
                    >
                      Reset
                    </button>
                  )}
                  {recordingId === s.id ? (
                    <KeyRecorder value={s.keys} onCancel={() => setRecordingId(null)} onRecord={(keys) => void setKeys(s, keys)} />
                  ) : (
                    <button type="button" class="st-keys-btn" title="Click, then press new keys" onClick={() => setRecordingId(s.id)}>
                      {s.keys ? <Keycaps keys={s.keys} /> : <span class="st-keys-add">Add shortcut</span>}
                    </button>
                  )}
                </div>
              </div>
              {open && (
                <div class="st-shortcut-details">
                  <div class="st-detail-line">
                    <span class="st-detail-label">Default</span>
                    {s.default_keys ? <Keycaps keys={s.default_keys} /> : <span class="st-muted">None</span>}
                  </div>
                  {s.all_keys.length > 1 && (
                    <div class="st-detail-line">
                      <span class="st-detail-label">Also</span>
                      {s.all_keys.slice(1).map((k) => (
                        <Keycaps key={k} keys={k} />
                      ))}
                    </div>
                  )}
                  {s.menu && (
                    <div class="st-detail-line">
                      <span class="st-detail-label">Menu</span>
                      <span class="st-muted">{s.menu}</span>
                    </div>
                  )}
                  {s.conflict_with && (
                    <div class="st-detail-line">
                      <span class="st-detail-label">Conflict</span>
                      <span class="st-muted">Same keys as “{byId.get(s.conflict_with)?.title ?? s.conflict_with}”</span>
                    </div>
                  )}
                  <div class="st-detail-line">
                    <span class="st-detail-label">On websites</span>
                    <Select
                      ariaLabel={`Priority of ${s.title}`}
                      value={s.priority}
                      options={PRIORITY_OPTIONS}
                      onChange={async (priority) => apply(await ctx.run(() => rpc('settings.shortcuts.setPriority', { id: s.id, priority })))}
                    />
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      {status && (
        <div class="st-status-line" role="status">
          {status}
        </div>
      )}

      <Group title="When shortcuts overlap">
        <Row id="shortcuts/priority" label="If a website uses the same keys" help="A command's own choice above wins over this." prefKey="shortcuts.priority">
          <SegmentedControl
            ariaLabel="Shortcut priority"
            value={(state?.priority ?? 'open') as 'open' | 'website'}
            options={[
              { value: 'open', label: 'Open first' },
              { value: 'website', label: 'Website first' },
            ]}
            onChange={async (priority) => {
              const res = await ctx.run(() => rpc('settings.shortcuts.setPriority', { priority }));
              apply(res);
              if (res) ctx.applyPreferences({ ...ctx.prefs, 'shortcuts.priority': priority });
            }}
          />
        </Row>
        <Row id="shortcuts/import-export" label="Back up your shortcuts" help="Export a JSON file, or import one from another computer.">
          <Btn onClick={async () => {
            const res = await ctx.run(() => rpc('settings.shortcuts.exportJson', {}));
            if (res?.ok) ctx.toast(`Exported to ${res.path ?? 'a file'}.`, 'success');
          }}>Export JSON…</Btn>
          <Btn onClick={async () => {
            const res = await ctx.run(() => rpc('settings.shortcuts.importJson', {}));
            if (res && res.ok) apply(res, `Imported ${res.applied ?? 0} shortcuts.`);
            else if (res?.canceled && !isNativeWebUI()) fileRef.current?.click();
          }}>Import JSON…</Btn>
        </Row>
      </Group>

      <ConfirmDialog
        open={resetAll}
        title="Reset all shortcuts?"
        confirmLabel="Reset All"
        danger
        onConfirm={async () => {
          setResetAll(false);
          apply(await ctx.run(() => rpc('settings.shortcuts.resetAll', {})), 'Every shortcut is back to its default.');
          setNotice(null);
        }}
        onClose={() => setResetAll(false)}
      >
        <p class="st-dialog-text">Every command gets its default keys back. Your changes are lost.</p>
      </ConfirmDialog>
    </div>
  );
}
