import type { JSX } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { call, errorText } from './api';
import { ArchiveGlyph, ChevronGlyph, DotsGlyph, FolderGlyph, OpenGlyph, PeekGlyph, TrashGlyph, UndoGlyph } from './icons';
import type { LibArchiveItem } from './types';
import {
  Chip,
  DayHeading,
  EmptyState,
  Favicon,
  IconButton,
  Menu,
  Row,
  Skeleton,
  groupByDay,
  useMenu,
  useNavRows,
  useSlowFlag,
  type NavRow,
  type SectionProps,
} from './ui';

type Reason = 'all' | 'closed' | 'auto-archive' | 'clear-today' | 'space-deleted';

const REASON_LABEL: Record<string, string> = {
  closed: 'Closed',
  'auto-archive': 'Auto-archived',
  'clear-today': 'Cleared',
  'space-deleted': 'Space deleted',
};

export function ArchiveSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, filterOpen, setFilterActive, drawer, profileNames, multiProfile } = props;
  const [items, setItems] = useState<LibArchiveItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [reason, setReason] = useState<Reason>('all');
  const [space, setSpace] = useState<string>('all');
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [tick, setTick] = useState(0);
  const { menu, openMenu, closeMenu } = useMenu();
  const slow = useSlowFlag(loading);

  useEffect(() => {
    let live = true;
    setLoading(true);
    call('library.archive.list', { profile_id: profileId, query })
      .then((res) => live && setItems(res.items))
      .catch((err) => live && toast(errorText(err, 'Archived tabs could not be loaded.')))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [profileId, query, refreshKey, tick]);

  useEffect(() => setFilterActive(reason !== 'all' || space !== 'all'), [reason, space]);

  const spaces = useMemo(() => {
    const seen = new Map<string, string>();
    for (const it of items) if (it.space_id && it.space_title) seen.set(it.space_id, it.space_title);
    return [...seen.entries()];
  }, [items]);

  const visible = items.filter((it) => (reason === 'all' || it.reason === reason) && (space === 'all' || it.space_id === space));

  const peek = (url: string) =>
    void call('library.archive.peek', { url }).catch((err) => toast(errorText(err, 'Peek is not available.')));

  const restore = async (it: LibArchiveItem) => {
    try {
      await call('library.archive.restore', { id: it.id, profile_id: it.profile_id });
      setItems((prev) => prev.filter((x) => x.id !== it.id));
      toast(it.kind === 'folder' ? `Restored folder “${it.title}”.` : `Restored “${it.title || it.host}”.`);
      if (drawer && it.kind === 'tab') props.closeLibrary();
    } catch (err) {
      toast(errorText(err, 'That item could not be restored.'));
    }
  };

  const remove = async (it: LibArchiveItem) => {
    try {
      await call('library.archive.delete', { profile_id: it.profile_id, ids: [it.id] });
      setItems((prev) => prev.filter((x) => x.id !== it.id));
    } catch (err) {
      toast(errorText(err, 'That item could not be deleted.'));
    }
  };

  const clearAll = () =>
    confirm({
      title: 'Clear the Archive?',
      body:
        profileId === 'all'
          ? 'Archived tabs of every Profile are deleted. You cannot undo this.'
          : `Archived tabs of ${profileNames[profileId] ?? 'this Profile'} are deleted. You cannot undo this.`,
      confirm: 'Clear Archive',
      danger: true,
      run: async () => {
        try {
          await call('library.archive.clearAll', { profile_id: profileId });
          toast('Cleared the Archive.');
          setTick((t) => t + 1);
        } catch (err) {
          toast(errorText(err, 'The Archive could not be cleared.'));
        }
      },
    });

  const toggle = (id: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const navRows: NavRow[] = [];
  for (const it of visible) {
    navRows.push({ key: `ar:${it.id}`, activate: () => void restore(it), remove: () => void remove(it) });
    if (it.kind === 'folder' && expanded.has(it.id)) {
      for (const child of it.children ?? []) navRows.push({ key: `ar:${it.id}:${child.id || child.url}`, activate: () => peek(child.url) });
    }
  }
  useNavRows(navRows);

  const rowMenu = (e: MouseEvent, it: LibArchiveItem) =>
    openMenu(e, `${it.title} actions`, [
      { label: it.kind === 'folder' ? 'Restore Folder' : 'Restore Tab', icon: <UndoGlyph size={14} />, onSelect: () => void restore(it) },
      ...(it.kind === 'tab'
        ? [
            { label: 'Peek', icon: <PeekGlyph size={14} />, onSelect: () => peek(it.url) },
            {
              label: 'Open in New Tab',
              icon: <OpenGlyph size={14} />,
              onSelect: () => void call('library.openUrl', { url: it.url, new_tab: true }).catch((err) => toast(errorText(err, 'The page could not be opened.'))),
            },
          ]
        : []),
      { label: 'Delete', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, onSelect: () => void remove(it) },
    ]);

  const sub = (it: LibArchiveItem) =>
    [
      it.kind === 'folder' ? `${it.child_count ?? 0} tab${it.child_count === 1 ? '' : 's'}` : it.host,
      it.space_title,
      multiProfile && profileId === 'all' && profileNames[it.profile_id] !== it.space_title ? profileNames[it.profile_id] : '',
    ]
      .filter(Boolean)
      .join(' · ');

  return (
    <div class="lib-section">
      {filterOpen && (
        <div class="lib-filter-editor" role="group" aria-label="Filter archived tabs">
          <div class="lib-filter-label">How was the tab closed?</div>
          <div class="lib-chip-row">
            {(['all', 'closed', 'auto-archive', 'clear-today', 'space-deleted'] as const).map((r) => (
              <Chip key={r} selected={reason === r} onClick={() => setReason(r)}>
                {r === 'all' ? 'Any' : REASON_LABEL[r]}
              </Chip>
            ))}
          </div>
          {spaces.length > 1 && (
            <>
              <div class="lib-filter-label">Where was the tab?</div>
              <div class="lib-chip-row">
                <Chip selected={space === 'all'} onClick={() => setSpace('all')}>
                  Any Space
                </Chip>
                {spaces.map(([id, title]) => (
                  <Chip key={id} selected={space === id} onClick={() => setSpace(id)}>
                    {title}
                  </Chip>
                ))}
              </div>
            </>
          )}
          <button type="button" class="lib-link-btn is-danger" disabled={items.length === 0} onClick={clearAll}>
            Clear Archive…
          </button>
        </div>
      )}
      <div class="lib-list" role="listbox" aria-label="Archived tabs">
        {loading && items.length === 0 ? (
          slow ? <Skeleton /> : null
        ) : visible.length === 0 ? (
          <EmptyState
            icon={<ArchiveGlyph size={34} />}
            title={query || reason !== 'all' || space !== 'all' ? 'No matches' : 'Nothing archived yet'}
            body={
              query || reason !== 'all' || space !== 'all'
                ? 'Try another word or filter.'
                : 'Tabs you close, and tabs that Open tidies away, appear here.'
            }
          />
        ) : (
          groupByDay(visible, (it) => it.archived_at).map((group) => (
            <div key={group.day} class="lib-group">
              <DayHeading label={group.day} />
              {group.items.map((it) => {
                const open = expanded.has(it.id);
                return (
                  <div key={it.id}>
                    <Row
                      navKey={`ar:${it.id}`}
                      icon={
                        it.kind === 'folder' ? (
                          <span class="lib-folder-icon">
                            <FolderGlyph />
                          </span>
                        ) : (
                          <Favicon src={it.favicon_url} host={it.host} />
                        )
                      }
                      title={it.title || it.url}
                      subtitle={sub(it)}
                      trailing={
                        it.kind === 'folder' ? (
                          <span class="lib-count-badge" aria-label={`${it.child_count ?? 0} tabs`}>
                            {it.child_count ?? 0}
                          </span>
                        ) : (
                          <span class="lib-reason">{REASON_LABEL[it.reason] ?? ''}</span>
                        )
                      }
                      onClick={() => (it.kind === 'folder' ? toggle(it.id) : peek(it.url))}
                      onDblClick={() => void restore(it)}
                      onContextMenu={(e) => rowMenu(e, it)}
                      actions={
                        <>
                          {it.kind === 'folder' ? (
                            <IconButton label={open ? 'Collapse' : 'Expand'} onClick={() => toggle(it.id)}>
                              <ChevronGlyph size={14} open={open} />
                            </IconButton>
                          ) : (
                            <IconButton label="Peek" onClick={() => peek(it.url)}>
                              <PeekGlyph />
                            </IconButton>
                          )}
                          <IconButton label="Restore" onClick={() => void restore(it)}>
                            <UndoGlyph />
                          </IconButton>
                          <IconButton label="More" onClick={(e) => rowMenu(e, it)}>
                            <DotsGlyph />
                          </IconButton>
                        </>
                      }
                    />
                    {it.kind === 'folder' &&
                      open &&
                      (it.children ?? []).map((child) => (
                        <Row
                          key={child.id || child.url}
                          navKey={`ar:${it.id}:${child.id || child.url}`}
                          indent={22}
                          icon={<Favicon src={child.favicon_url} host={child.host} size={16} />}
                          title={child.title || child.url}
                          subtitle={child.host}
                          onClick={() => peek(child.url)}
                          actions={
                            <IconButton label="Peek" onClick={() => peek(child.url)}>
                              <PeekGlyph />
                            </IconButton>
                          }
                        />
                      ))}
                  </div>
                );
              })}
            </div>
          ))
        )}
      </div>
      {!filterOpen && items.length > 0 && (
        <div class="lib-status">
          <span>
            {items.length} archived item{items.length === 1 ? '' : 's'}
          </span>
          <button type="button" class="lib-link-btn" onClick={clearAll}>
            Clear Archive…
          </button>
        </div>
      )}
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
