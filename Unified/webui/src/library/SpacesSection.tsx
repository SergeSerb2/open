import type { JSX } from 'preact';
import { useContext, useEffect, useRef, useState } from 'preact/hooks';
import { RPC_EVENTS, type SpaceStyle } from '../shared/bridge';
import { SpaceThemeEditor, computeSpaceGradientCss, isLightSpaceStyle } from '../shared/components';
import { call, errorText, onEvent } from './api';
import { DotsGlyph, PencilGlyph, PlusGlyph, SpacesGlyph, TrashGlyph } from './icons';
import type { LibSpace } from './types';
import { EmptyState, IconButton, Menu, NavContext, Sheet, useMenu, useNavRows, type NavRow, type SectionProps } from './ui';

interface EditState {
  id: string;
  title: string;
  emoji: string;
  iconKind: LibSpace['icon']['kind'];
  style: SpaceStyle;
}

function SpaceIconView({ space }: { space: LibSpace }): JSX.Element {
  if (space.icon.kind === 'emoji' && space.icon.value) return <span class="lib-space-emoji">{space.icon.value}</span>;
  // Named / symbol icons: the Space's initial on a tinted disc.
  return (
    <span class="lib-space-initial" style={{ background: computeSpaceGradientCss(space.style) }} aria-hidden="true">
      {(space.title || '?').charAt(0).toUpperCase()}
    </span>
  );
}

export function SpacesSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, multiProfile } = props;
  const nav = useContext(NavContext);
  const [spaces, setSpaces] = useState<LibSpace[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [editing, setEditing] = useState<EditState | null>(null);
  const [dragId, setDragId] = useState<string | null>(null);
  const [dropId, setDropId] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const { menu, openMenu, closeMenu } = useMenu();
  const strip = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let live = true;
    call('library.spaces.list', { profile_id: profileId })
      .then((res) => live && setSpaces(res.spaces))
      .catch((err) => live && toast(errorText(err, 'Spaces could not be loaded.')))
      .finally(() => live && setLoaded(true));
    return () => {
      live = false;
    };
  }, [profileId, refreshKey, tick]);

  useEffect(() => {
    let timer = 0;
    const off = onEvent(RPC_EVENTS.stateChanged, () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => setTick((t) => t + 1), 300);
    });
    return () => {
      off();
      window.clearTimeout(timer);
    };
  }, []);

  // open://library/spaces/<id>: the Space editor (sidebar "Edit Theme").
  useEffect(() => {
    const match = /\/spaces\/([^/?#]+)/.exec(window.location.pathname + window.location.hash);
    if (!match || !loaded) return;
    const target = spaces.find((s) => s.id === decodeURIComponent(match[1] ?? ''));
    if (target) startEdit(target);
  }, [loaded]);

  const q = query.trim().toLowerCase();
  const visible = spaces.filter((s) => !q || s.title.toLowerCase().includes(q) || (s.profile_name ?? '').toLowerCase().includes(q));

  const startEdit = (s: LibSpace) =>
    setEditing({ id: s.id, title: s.title, emoji: s.icon.kind === 'emoji' ? s.icon.value : '', iconKind: s.icon.kind, style: { ...s.style, key_color: { ...s.style.key_color } } });

  const switchTo = async (s: LibSpace) => {
    try {
      // The browser switches the Space and closes the Library (open_library_ui.cc).
      await call('library.spaces.switch', { id: s.id, close: true });
    } catch (err) {
      toast(errorText(err, 'That Space could not be opened.'));
    }
  };

  const remove = (s: LibSpace) =>
    confirm({
      title: `Delete “${s.title || 'Space'}”?`,
      body: 'Its pinned and Today tabs move to the Archive.',
      confirm: 'Delete Space',
      danger: true,
      run: async () => {
        try {
          await call('library.spaces.delete', { id: s.id });
          setSpaces((prev) => prev.filter((x) => x.id !== s.id));
          toast(`Deleted “${s.title}”.`);
        } catch (err) {
          toast(errorText(err, 'That Space could not be deleted.'));
        }
      },
    });

  const create = async () => {
    try {
      const res = await call('library.spaces.create', { profile_id: profileId === 'all' ? undefined : profileId, title: 'New Space' });
      setSpaces((prev) => [...prev, res.space]);
      startEdit(res.space);
      window.setTimeout(() => strip.current?.scrollTo({ left: strip.current.scrollWidth, behavior: 'smooth' }), 50);
    } catch (err) {
      toast(errorText(err, 'The Space could not be created.'));
    }
  };

  const save = async () => {
    if (!editing) return;
    try {
      const icon = editing.emoji.trim()
        ? { kind: 'emoji' as const, value: Array.from(editing.emoji.trim()).slice(0, 2).join('') }
        : undefined;
      const res = await call('library.spaces.update', { id: editing.id, title: editing.title.trim(), style: editing.style, ...(icon ? { icon } : {}) });
      setSpaces((prev) => prev.map((s) => (s.id === res.space.id ? { ...s, ...res.space } : s)));
      setEditing(null);
      setTick((t) => t + 1);
      toast(`Saved “${res.space.title}”.`);
    } catch (err) {
      toast(errorText(err, 'The Space could not be saved.'));
    }
  };

  const drop = async (targetId: string) => {
    const from = dragId;
    setDragId(null);
    setDropId(null);
    if (!from || from === targetId) return;
    const before = spaces;
    const order = spaces.filter((s) => s.id !== from);
    const at = order.findIndex((s) => s.id === targetId);
    const moved = spaces.find((s) => s.id === from);
    if (!moved || at < 0) return;
    order.splice(at, 0, moved);
    setSpaces(order);
    try {
      await call('library.spaces.reorder', { ids: order.map((s) => s.id) });
    } catch (err) {
      setSpaces(before);
      toast(errorText(err, 'Spaces could not be reordered.'));
    }
  };

  const navRows: NavRow[] = visible.map((s) => ({ key: `sp:${s.id}`, activate: () => void switchTo(s), remove: () => remove(s) }));
  useNavRows(navRows);

  const cardMenu = (e: MouseEvent, s: LibSpace) =>
    openMenu(e, `${s.title} actions`, [
      { label: 'Switch to Space', disabled: s.is_active, onSelect: () => void switchTo(s) },
      { label: 'Edit Theme…', icon: <PencilGlyph size={14} />, onSelect: () => startEdit(s) },
      { label: 'Delete Space…', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, disabled: spaces.length <= 1, onSelect: () => remove(s) },
    ]);

  return (
    <div class="lib-section lib-spaces">
      {loaded && visible.length === 0 && q ? (
        <EmptyState icon={<SpacesGlyph size={34} />} title="No matches" body="Try another word." />
      ) : (
        <div ref={strip} class="lib-space-strip" role="listbox" aria-label="Spaces" aria-orientation="horizontal">
          {visible.map((s) => {
            const theme = s.theme;
            const light = theme ? theme.mode === 'light' : isLightSpaceStyle(s.style);
            const focused = nav.focusKey === `sp:${s.id}`;
            return (
              <div
                key={s.id}
                class={`lib-space-card${s.is_active ? ' is-active' : ''}${focused ? ' is-selected' : ''}${focused && nav.keyboard ? ' is-focus' : ''}${dropId === s.id ? ' is-drop' : ''}${dragId === s.id ? ' is-dragging' : ''}`}
                data-nav-key={`sp:${s.id}`}
                role="option"
                aria-selected={focused}
                aria-label={s.title}
                style={{
                  background: theme?.bg,
                  color: theme?.fg ?? (light ? '#1c1c21' : '#f5f5f7'),
                }}
                draggable
                onMouseDown={() => nav.setFocusKey(`sp:${s.id}`)}
                onDblClick={() => void switchTo(s)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  cardMenu(e as unknown as MouseEvent, s);
                }}
                onDragStart={(e) => {
                  setDragId(s.id);
                  e.dataTransfer?.setData('text/plain', s.title);
                  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
                }}
                onDragOver={(e) => {
                  if (!dragId) return;
                  e.preventDefault();
                  setDropId(s.id);
                }}
                onDragLeave={() => setDropId((d) => (d === s.id ? null : d))}
                onDrop={(e) => {
                  e.preventDefault();
                  void drop(s.id);
                }}
                onDragEnd={() => {
                  setDragId(null);
                  setDropId(null);
                }}
              >
                <div class="lib-space-band" style={{ background: computeSpaceGradientCss(s.style) }} />
                <div class="lib-space-head">
                  <SpaceIconView space={s} />
                  <span class="lib-space-title">{s.title || 'Space'}</span>
                  <IconButton label="Edit Theme" onClick={() => startEdit(s)}>
                    <PencilGlyph />
                  </IconButton>
                </div>
                <div class="lib-space-rule" />
                <div class="lib-space-body">
                  {s.is_active && <span class="lib-badge is-accent">Current Space</span>}
                  <div class="lib-space-stat">
                    <strong>{s.pinned_count}</strong> pinned <span aria-hidden="true">·</span> <strong>{s.today_count}</strong> today
                  </div>
                  {(multiProfile || profileId === 'all') && s.profile_name && <div class="lib-space-profile">{s.profile_name}</div>}
                </div>
                <div class="lib-space-actions">
                  {!s.is_active && (
                    <button type="button" class="lib-btn lib-btn-on-card" onClick={() => void switchTo(s)}>
                      Switch
                    </button>
                  )}
                  <button type="button" class="lib-btn lib-btn-on-card" onClick={() => startEdit(s)}>
                    Edit Theme…
                  </button>
                  <span class="lib-flex" />
                  <IconButton label="More" onClick={(e) => cardMenu(e, s)}>
                    <DotsGlyph />
                  </IconButton>
                </div>
              </div>
            );
          })}
          {!q && (
            <button type="button" class="lib-space-card lib-space-new" onClick={() => void create()}>
              <PlusGlyph size={20} />
              <span>New Space</span>
            </button>
          )}
        </div>
      )}
      {editing && (
        <Sheet
          title="Edit Space"
          wide
          onClose={() => setEditing(null)}
          footer={
            <>
              <button type="button" class="lib-btn" onClick={() => setEditing(null)}>
                Cancel
              </button>
              <button type="button" class="lib-btn lib-btn-primary" disabled={!editing.title.trim()} onClick={() => void save()}>
                Save
              </button>
            </>
          }
        >
          <div class="lib-edit-row">
            <input
              class="lib-input lib-input-emoji"
              aria-label="Space icon"
              placeholder="＋"
              value={editing.emoji}
              onInput={(e) => setEditing({ ...editing, emoji: (e.currentTarget as HTMLInputElement).value })}
            />
            <input
              class="lib-input"
              aria-label="Space name"
              data-autofocus
              maxLength={128}
              value={editing.title}
              onInput={(e) => setEditing({ ...editing, title: (e.currentTarget as HTMLInputElement).value })}
              onKeyDown={(e) => e.key === 'Enter' && void save()}
            />
          </div>
          <SpaceThemeEditor title={editing.title || 'Space'} style={editing.style} onChange={(style) => setEditing({ ...editing, style })} />
        </Sheet>
      )}
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
