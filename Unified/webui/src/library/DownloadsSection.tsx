import type { JSX } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { RPC_EVENTS } from '../shared/bridge';
import { call, errorText, onEvent } from './api';
import {
  CancelGlyph,
  CopyGlyph,
  DotsGlyph,
  DownloadsGlyph,
  FileGlyph,
  OpenGlyph,
  PauseGlyph,
  ResumeGlyph,
  RetryGlyph,
  RevealGlyph,
  TrashGlyph,
} from './icons';
import type { LibDownload } from './types';
import {
  Chip,
  DayHeading,
  EmptyState,
  IconButton,
  Menu,
  Row,
  Skeleton,
  formatBytes,
  groupByDay,
  revealLabel,
  useMenu,
  useNavRows,
  useSlowFlag,
  type NavRow,
  type SectionProps,
} from './ui';

type StateFilter = 'all' | 'active' | 'completed' | 'failed';

const isActive = (d: LibDownload) => d.state === 'in_progress' || d.state === 'paused';
const isFailed = (d: LibDownload) => d.state === 'interrupted' || d.state === 'cancelled';

function Ring({ progress, paused }: { progress: number; paused: boolean }): JSX.Element {
  const r = 9;
  const c = 2 * Math.PI * r;
  const known = progress >= 0;
  return (
    <svg class={`lib-ring${known ? '' : ' is-indeterminate'}`} width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r={r} class="lib-ring-track" />
      <circle
        cx="12"
        cy="12"
        r={r}
        class="lib-ring-fill"
        stroke-dasharray={`${c}`}
        stroke-dashoffset={`${known ? c * (1 - Math.max(0.02, progress)) : c * 0.72}`}
        transform="rotate(-90 12 12)"
      />
      {paused ? (
        <g class="lib-ring-arrow">
          <line x1="10" y1="9" x2="10" y2="15" />
          <line x1="14" y1="9" x2="14" y2="15" />
        </g>
      ) : (
        <g class="lib-ring-arrow">
          <line x1="12" y1="8" x2="12" y2="15.5" />
          <polyline points="9.2,12.9 12,15.7 14.8,12.9" />
        </g>
      )}
    </svg>
  );
}

function subtitle(d: LibDownload): JSX.Element | string {
  if (d.state === 'in_progress' || d.state === 'paused') {
    const of = d.total_bytes > 0 ? `${formatBytes(d.received_bytes)} of ${formatBytes(d.total_bytes)}` : formatBytes(d.received_bytes);
    if (d.state === 'paused') return `Paused — ${of}`;
    return d.bytesPerSecond > 0 ? `${of} (${formatBytes(d.bytesPerSecond)}/s)` : of;
  }
  if (d.state === 'cancelled') return 'Cancelled';
  if (d.state === 'interrupted') return d.canResume ? 'Failed — can resume' : 'Failed';
  if (!d.fileExists) {
    return (
      <>
        <span class="lib-badge is-warn">Missing file</span> {d.host || 'Download'}
      </>
    );
  }
  return [formatBytes(d.total_bytes > 0 ? d.total_bytes : d.received_bytes), d.host].filter(Boolean).join(' · ') || 'Download';
}

export function DownloadsSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, filterOpen, setFilterActive, profileNames, multiProfile } = props;
  const [items, setItems] = useState<LibDownload[]>([]);
  const [loading, setLoading] = useState(true);
  const [stateFilter, setStateFilter] = useState<StateFilter>('all');
  const [tick, setTick] = useState(0);
  const { menu, openMenu, closeMenu } = useMenu();
  const slow = useSlowFlag(loading);
  const pending = useRef(0);

  const load = async () => {
    const gen = ++pending.current;
    try {
      const res = await call('library.downloads.list', { profile_id: profileId, query, limit: 500 });
      if (gen === pending.current) setItems(res.downloads);
    } catch (err) {
      if (gen === pending.current) toast(errorText(err, 'Downloads could not be loaded.'));
    } finally {
      if (gen === pending.current) setLoading(false);
    }
  };

  useEffect(() => {
    setLoading(true);
    void load();
  }, [profileId, query, refreshKey, tick]);

  // Push updates (coalesced), and a 1 s poll while a transfer runs (the
  // store-only fallback has no per-progress events).
  useEffect(() => {
    let timer = 0;
    const off = onEvent(RPC_EVENTS.downloadUpdated, () => {
      if (timer) return;
      timer = window.setTimeout(() => {
        timer = 0;
        setTick((t) => t + 1);
      }, 250);
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, []);
  const anyActive = items.some(isActive);
  useEffect(() => {
    if (!anyActive) return;
    const id = window.setInterval(() => setTick((t) => t + 1), 1000);
    return () => window.clearInterval(id);
  }, [anyActive]);

  useEffect(() => setFilterActive(stateFilter !== 'all'), [stateFilter]);

  const visible = useMemo(
    () =>
      items.filter((d) =>
        stateFilter === 'all'
          ? true
          : stateFilter === 'active'
            ? isActive(d)
            : stateFilter === 'completed'
              ? d.state === 'completed'
              : isFailed(d),
      ),
    [items, stateFilter],
  );

  const act = async (
    method:
      | 'library.downloads.pause'
      | 'library.downloads.resume'
      | 'library.downloads.cancel'
      | 'library.downloads.retry'
      | 'library.downloads.open'
      | 'library.downloads.reveal'
      | 'library.downloads.trash'
      | 'library.downloads.remove',
    d: LibDownload,
    done?: string,
  ) => {
    try {
      await call(method, { id: d.id, profile_id: d.profile_id });
      if (method === 'library.downloads.trash' || method === 'library.downloads.remove') {
        setItems((prev) => prev.filter((x) => x.id !== d.id));
      }
      if (done) toast(done);
      setTick((t) => t + 1);
    } catch (err) {
      toast(errorText(err, 'That did not work.'));
    }
  };

  const copyLink = async (d: LibDownload) => {
    try {
      await navigator.clipboard.writeText(d.url);
      toast('Copied download link.');
    } catch {
      toast('The link could not be copied.');
    }
  };

  const trash = (d: LibDownload) =>
    confirm({
      title: `Move “${d.filename}” to the Trash?`,
      body: 'The file is removed from your Downloads list too.',
      confirm: 'Move to Trash',
      danger: true,
      run: () => act('library.downloads.trash', d, 'Moved to the Trash.'),
    });

  const primary = (d: LibDownload) => {
    if (d.state === 'completed' && d.fileExists) void act('library.downloads.open', d);
    else if (d.state === 'paused') void act('library.downloads.resume', d);
    else if (isFailed(d)) void act('library.downloads.retry', d, 'Retrying download.');
  };

  const destructive = (d: LibDownload) => {
    if (isActive(d)) void act('library.downloads.cancel', d);
    else void act('library.downloads.remove', d);
  };

  const moreMenu = (e: MouseEvent, d: LibDownload) =>
    openMenu(e, `${d.filename} actions`, [
      { label: 'Open', icon: <OpenGlyph size={14} />, disabled: d.state !== 'completed' || !d.fileExists, onSelect: () => void act('library.downloads.open', d) },
      { label: revealLabel(), icon: <RevealGlyph size={14} />, disabled: !d.fileExists && d.state === 'completed', onSelect: () => void act('library.downloads.reveal', d) },
      { label: 'Copy Download Link', icon: <CopyGlyph size={14} />, disabled: !d.url, onSelect: () => void copyLink(d) },
      ...(isFailed(d)
        ? [{ label: 'Retry', icon: <RetryGlyph size={14} />, onSelect: () => void act('library.downloads.retry', d, 'Retrying download.') }]
        : []),
      { label: 'Move to Trash', icon: <TrashGlyph size={14} />, separatorBefore: true, danger: true, disabled: d.state !== 'completed' || !d.fileExists, onSelect: () => trash(d) },
      { label: 'Remove from List', disabled: isActive(d), onSelect: () => void act('library.downloads.remove', d) },
    ]);

  const navRows: NavRow[] = visible.map((d) => ({ key: `dl:${d.id}`, activate: () => primary(d), remove: () => destructive(d) }));
  useNavRows(navRows);

  const finished = items.filter((d) => !isActive(d)).length;
  const clearCompleted = () =>
    confirm({
      title: 'Clear finished downloads?',
      body: 'Completed, failed and cancelled downloads leave this list. Files stay on disk.',
      confirm: 'Clear',
      run: async () => {
        try {
          await call('library.downloads.clear', { profile_id: profileId });
          toast('Cleared finished downloads.');
          setTick((t) => t + 1);
        } catch (err) {
          toast(errorText(err, 'Downloads could not be cleared.'));
        }
      },
    });

  return (
    <div class="lib-section">
      {filterOpen && (
        <div class="lib-filter-editor" role="group" aria-label="Filter downloads">
          <div class="lib-filter-label">Show</div>
          <div class="lib-chip-row">
            {(['all', 'active', 'completed', 'failed'] as const).map((f) => (
              <Chip key={f} selected={stateFilter === f} onClick={() => setStateFilter(f)}>
                {f === 'all' ? 'All' : f === 'active' ? 'In Progress' : f === 'completed' ? 'Completed' : 'Failed'}
              </Chip>
            ))}
          </div>
        </div>
      )}
      <div class="lib-list" role="listbox" aria-label="Downloads">
        {loading && items.length === 0 ? (
          slow ? <Skeleton /> : null
        ) : visible.length === 0 ? (
          <EmptyState
            icon={<DownloadsGlyph size={34} />}
            title={query || stateFilter !== 'all' ? 'No matches' : 'No downloads yet'}
            body={query || stateFilter !== 'all' ? 'Try another word or filter.' : 'Files you download appear here.'}
          />
        ) : (
          groupByDay(visible, (d) => d.started_at).map((group) => (
            <div key={group.day} class="lib-group">
              <DayHeading label={group.day} />
              {group.items.map((d) => {
                const running = isActive(d);
                return (
                  <Row
                    key={d.id}
                    navKey={`dl:${d.id}`}
                    progress={running}
                    dim={d.state === 'completed' && !d.fileExists}
                    icon={
                      running ? (
                        <Ring progress={d.progress} paused={d.state === 'paused'} />
                      ) : d.thumb_url ? (
                        <img class="lib-file-thumb" src={d.thumb_url} alt="" loading="lazy" decoding="async" />
                      ) : (
                        <FileGlyph />
                      )
                    }
                    title={d.filename}
                    subtitle={
                      <>
                        {subtitle(d)}
                        {multiProfile && profileId === 'all' && profileNames[d.profile_id] ? ` · ${profileNames[d.profile_id]}` : ''}
                      </>
                    }
                    onDblClick={() => primary(d)}
                    onContextMenu={(e) => moreMenu(e, d)}
                    actions={
                      <>
                        {d.state === 'in_progress' && (
                          <IconButton label="Pause" onClick={() => void act('library.downloads.pause', d)}>
                            <PauseGlyph />
                          </IconButton>
                        )}
                        {d.state === 'paused' && (
                          <IconButton label="Resume" onClick={() => void act('library.downloads.resume', d)}>
                            <ResumeGlyph />
                          </IconButton>
                        )}
                        {running && (
                          <IconButton label="Cancel" onClick={() => void act('library.downloads.cancel', d)}>
                            <CancelGlyph />
                          </IconButton>
                        )}
                        {isFailed(d) && (
                          <IconButton label="Retry" onClick={() => void act('library.downloads.retry', d, 'Retrying download.')}>
                            <RetryGlyph />
                          </IconButton>
                        )}
                        {d.state === 'completed' && d.fileExists && (
                          <IconButton label={revealLabel()} onClick={() => void act('library.downloads.reveal', d)}>
                            <RevealGlyph />
                          </IconButton>
                        )}
                        <IconButton label="More" onClick={(e) => moreMenu(e, d)}>
                          <DotsGlyph />
                        </IconButton>
                      </>
                    }
                  />
                );
              })}
            </div>
          ))
        )}
      </div>
      {finished > 0 && (
        <div class="lib-status">
          <span>
            {items.length} download{items.length === 1 ? '' : 's'}
            {anyActive ? ` · ${items.filter(isActive).length} in progress` : ''}
          </span>
          <button type="button" class="lib-link-btn" onClick={clearCompleted}>
            Clear Completed…
          </button>
        </div>
      )}
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
