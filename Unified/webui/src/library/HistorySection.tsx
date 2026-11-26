import type { JSX } from 'preact';
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { RPC_EVENTS } from '../shared/bridge';
import { call, errorText, onEvent } from './api';
import { CopyGlyph, DotsGlyph, HistoryGlyph, OpenGlyph, PeekGlyph, TrashGlyph } from './icons';
import type { LibHistoryEntry } from './types';
import {
  Chip,
  DayHeading,
  EmptyState,
  Favicon,
  IconButton,
  Menu,
  Row,
  Sheet,
  Skeleton,
  formatClock,
  groupByDay,
  useMenu,
  useNavRows,
  useSlowFlag,
  type NavRow,
  type SectionProps,
} from './ui';

const PAGE = 120;

type When = 'all' | 'today' | 'yesterday' | 'week';
type ClearRange = 'lastHour' | 'today' | 'last7Days' | 'all';

const CLEAR_OPTIONS: { value: ClearRange; label: string }[] = [
  { value: 'lastHour', label: 'Last hour' },
  { value: 'today', label: 'Today' },
  { value: 'last7Days', label: 'Last 7 days' },
  { value: 'all', label: 'Everything' },
];

function startOfToday(): number {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime() / 1000;
}

export function HistorySection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, filterOpen, setFilterActive, drawer, profileNames, multiProfile } = props;
  const [entries, setEntries] = useState<LibHistoryEntry[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [when, setWhen] = useState<When>('all');
  const [clearing, setClearing] = useState(false);
  const [clearRange, setClearRange] = useState<ClearRange>('lastHour');
  const { menu, openMenu, closeMenu } = useMenu();
  const slow = useSlowFlag(loading);
  const gen = useRef(0);
  const sentinel = useRef<HTMLDivElement>(null);

  const fetchPage = async (offset: number) => {
    const my = offset === 0 ? ++gen.current : gen.current;
    const res = await call('library.history.list', { profile_id: profileId, query, offset, limit: PAGE });
    if (my !== gen.current) return;
    setEntries((prev) => (offset === 0 ? res.entries : [...prev, ...res.entries]));
    setHasMore(res.has_more);
  };

  useEffect(() => {
    setLoading(true);
    fetchPage(0)
      .catch((err) => toast(errorText(err, 'History could not be loaded.')))
      .finally(() => setLoading(false));
  }, [profileId, query, refreshKey]);

  // New visits arrive as open.stateChanged; refresh the first page only when
  // the user has not scrolled into older pages.
  useEffect(() => {
    let timer = 0;
    const off = onEvent(RPC_EVENTS.stateChanged, () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        if (entries.length <= PAGE) void fetchPage(0).catch(() => {});
      }, 600);
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, [entries.length, profileId, query]);

  const loadMore = async () => {
    if (loadingMore || !hasMore) return;
    setLoadingMore(true);
    try {
      await fetchPage(entries.length);
    } catch (err) {
      toast(errorText(err, 'More history could not be loaded.'));
    } finally {
      setLoadingMore(false);
    }
  };

  // Infinite scroll: the sentinel row near the end loads the next page.
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !hasMore) return;
    const io = new IntersectionObserver((list) => {
      if (list.some((e) => e.isIntersecting)) void loadMore();
    }, { rootMargin: '400px' });
    io.observe(el);
    return () => io.disconnect();
  }, [hasMore, entries.length, loadingMore]);

  useEffect(() => setFilterActive(when !== 'all'), [when]);

  const visible = useMemo(() => {
    if (when === 'all') return entries;
    const today = startOfToday();
    return entries.filter((e) =>
      when === 'today' ? e.last_visit >= today : when === 'yesterday' ? e.last_visit >= today - 86400 && e.last_visit < today : e.last_visit >= today - 6 * 86400,
    );
  }, [entries, when]);

  const open = (e: LibHistoryEntry, background = false) =>
    void call('library.openUrl', { url: e.url, new_tab: true, background, close_library: drawer && !background }).catch((err) =>
      toast(errorText(err, 'The page could not be opened.')),
    );

  const remove = async (e: LibHistoryEntry) => {
    try {
      await call('library.history.delete', { profile_id: e.profile_id, ids: [e.id] });
      setEntries((prev) => prev.filter((x) => !(x.id === e.id && x.profile_id === e.profile_id)));
    } catch (err) {
      toast(errorText(err, 'The page could not be removed.'));
    }
  };

  const removeSite = async (e: LibHistoryEntry) => {
    const same = entries.filter((x) => x.host === e.host && x.profile_id === e.profile_id);
    try {
      await call('library.history.delete', { profile_id: e.profile_id, ids: same.map((x) => x.id) });
      setEntries((prev) => prev.filter((x) => !(x.host === e.host && x.profile_id === e.profile_id)));
      toast(`Removed ${same.length} page${same.length === 1 ? '' : 's'} from ${e.host}.`);
    } catch (err) {
      toast(errorText(err, 'The pages could not be removed.'));
    }
  };

  const navRows: NavRow[] = visible.map((e) => ({ key: `h:${e.profile_id}:${e.id}`, activate: () => open(e), remove: () => void remove(e) }));
  useNavRows(navRows);

  const rowMenu = (ev: MouseEvent, e: LibHistoryEntry) =>
    openMenu(ev, `${e.title || e.url} actions`, [
      { label: 'Open in New Tab', icon: <OpenGlyph size={14} />, onSelect: () => open(e) },
      { label: 'Open in Background', onSelect: () => open(e, true) },
      { label: 'Peek', icon: <PeekGlyph size={14} />, onSelect: () => void call('library.archive.peek', { url: e.url }).catch((err) => toast(errorText(err, 'Peek is not available.'))) },
      {
        label: 'Copy Link',
        icon: <CopyGlyph size={14} />,
        onSelect: () => void navigator.clipboard.writeText(e.url).then(() => toast('Copied link.'), () => toast('The link could not be copied.')),
      },
      { label: 'Delete from History', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, onSelect: () => void remove(e) },
      { label: `Delete All from ${e.host || 'This Site'}`, danger: true, disabled: !e.host, onSelect: () => void removeSite(e) },
    ]);

  const runClear = async () => {
    try {
      await call('library.history.clear', { profile_id: profileId, range: clearRange });
      toast(clearRange === 'all' ? 'Cleared all history.' : `Cleared history from ${CLEAR_OPTIONS.find((o) => o.value === clearRange)?.label.toLowerCase()}.`);
      setClearing(false);
      setLoading(true);
      await fetchPage(0);
    } catch (err) {
      toast(errorText(err, 'History could not be cleared.'));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div class="lib-section">
      {filterOpen && (
        <div class="lib-filter-editor" role="group" aria-label="Filter history">
          <div class="lib-filter-label">When</div>
          <div class="lib-chip-row">
            {(['all', 'today', 'yesterday', 'week'] as const).map((w) => (
              <Chip key={w} selected={when === w} onClick={() => setWhen(w)}>
                {w === 'all' ? 'Any Time' : w === 'today' ? 'Today' : w === 'yesterday' ? 'Yesterday' : 'Last 7 Days'}
              </Chip>
            ))}
          </div>
          <button type="button" class="lib-link-btn is-danger" onClick={() => setClearing(true)}>
            Clear History…
          </button>
        </div>
      )}
      <div class="lib-list" role="listbox" aria-label="History">
        {loading && entries.length === 0 ? (
          slow ? <Skeleton /> : null
        ) : visible.length === 0 ? (
          <EmptyState
            icon={<HistoryGlyph size={34} />}
            title={query || when !== 'all' ? 'No matches' : 'No history yet'}
            body={query || when !== 'all' ? 'Try another word or time.' : 'Pages you visit appear here.'}
          />
        ) : (
          <>
            {groupByDay(visible, (e) => e.last_visit).map((group) => (
              <div key={group.day} class="lib-group">
                <DayHeading label={group.day} />
                {group.items.map((e) => (
                  <Row
                    key={`${e.profile_id}:${e.id}`}
                    navKey={`h:${e.profile_id}:${e.id}`}
                    icon={<Favicon src={e.favicon_url} host={e.host} />}
                    title={e.title || e.url}
                    subtitle={
                      <>
                        {e.host || e.url}
                        {multiProfile && profileId === 'all' && profileNames[e.profile_id] ? ` · ${profileNames[e.profile_id]}` : ''}
                      </>
                    }
                    trailing={<span class="lib-time-chip">{formatClock(e.last_visit)}</span>}
                    onClick={() => open(e)}
                    onContextMenu={(ev) => rowMenu(ev, e)}
                    actions={
                      <>
                        <IconButton label="Delete from History" onClick={() => void remove(e)}>
                          <TrashGlyph />
                        </IconButton>
                        <IconButton label="More" onClick={(ev) => rowMenu(ev, e)}>
                          <DotsGlyph />
                        </IconButton>
                      </>
                    }
                  />
                ))}
              </div>
            ))}
            {hasMore && (
              <div ref={sentinel} class="lib-load-more">
                <button type="button" class="lib-btn" disabled={loadingMore} onClick={() => void loadMore()}>
                  {loadingMore ? 'Loading…' : 'Load More'}
                </button>
              </div>
            )}
          </>
        )}
      </div>
      {!filterOpen && entries.length > 0 && (
        <div class="lib-status">
          <span>
            {visible.length}
            {hasMore ? '+' : ''} page{visible.length === 1 ? '' : 's'}
          </span>
          <button type="button" class="lib-link-btn" onClick={() => setClearing(true)}>
            Clear History…
          </button>
        </div>
      )}
      {clearing && (
        <Sheet
          title="Clear History"
          onClose={() => setClearing(false)}
          footer={
            <>
              <button type="button" class="lib-btn" onClick={() => setClearing(false)}>
                Cancel
              </button>
              <button type="button" class="lib-btn lib-btn-danger" onClick={() => void runClear()}>
                Clear History
              </button>
            </>
          }
        >
          <p class="lib-sheet-text">
            {profileId === 'all' ? 'Pages from every Profile are removed.' : `Pages from ${profileNames[profileId] ?? 'this Profile'} are removed.`} Open tabs stay
            open.
          </p>
          <div class="lib-radio-list" role="radiogroup" aria-label="Time range">
            {CLEAR_OPTIONS.map((o) => (
              <label key={o.value} class={`lib-radio${clearRange === o.value ? ' is-selected' : ''}`}>
                <input
                  type="radio"
                  name="clear-range"
                  checked={clearRange === o.value}
                  data-autofocus={clearRange === o.value ? true : undefined}
                  onChange={() => setClearRange(o.value)}
                />
                <span>{o.label}</span>
              </label>
            ))}
          </div>
        </Sheet>
      )}
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
