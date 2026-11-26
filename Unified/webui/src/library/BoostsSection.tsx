import type { JSX } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import { call, errorText } from './api';
import { BoostsGlyph, BrushGlyph, DotsGlyph, PencilGlyph, PlusGlyph, TrashGlyph } from './icons';
import type { LibBoost } from './types';
import { Chip, EmptyState, IconButton, Menu, NavContext, Row, useMenu, useNavRows, type NavRow, type SectionProps } from './ui';

type Layout = 'list' | 'gallery';

const LAYOUT_KEY = 'open.library.boostLayout';

function readLayout(): Layout {
  try {
    return window.localStorage.getItem(LAYOUT_KEY) === 'list' ? 'list' : 'gallery';
  } catch {
    return 'gallery';
  }
}

export function BoostsSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, drawer, profileNames, multiProfile } = props;
  const nav = useContext(NavContext);
  const [boosts, setBoosts] = useState<LibBoost[]>([]);
  const [globalEnabled, setGlobalEnabled] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [layout, setLayout] = useState<Layout>(readLayout);
  const [tick, setTick] = useState(0);
  const { menu, openMenu, closeMenu } = useMenu();

  useEffect(() => {
    let live = true;
    Promise.all([call('library.boosts.list', { profile_id: profileId, query }), call('boosts.list', {}).catch(() => null)])
      .then(([res, global]) => {
        if (!live) return;
        setBoosts(res.boosts);
        if (global) setGlobalEnabled(global.global_enabled);
      })
      .catch((err) => live && toast(errorText(err, 'Boosts could not be loaded.')))
      .finally(() => live && setLoaded(true));
    return () => {
      live = false;
    };
  }, [profileId, query, refreshKey, tick]);

  const chooseLayout = (next: Layout) => {
    setLayout(next);
    try {
      window.localStorage.setItem(LAYOUT_KEY, next);
    } catch {
      // Per-viewer convenience only.
    }
  };

  const toggle = async (b: LibBoost) => {
    try {
      const res = await call('boosts.toggle', { id: b.id, enabled: !b.enabled, profile_id: b.profile_id });
      setBoosts((prev) => prev.map((x) => (x.id === b.id ? { ...x, ...res.boost } : x)));
    } catch (err) {
      toast(errorText(err, 'That Boost could not be changed.'));
    }
  };

  const edit = (b: LibBoost) =>
    void call('library.openUrl', { url: `open://boosts/edit/${encodeURIComponent(b.id)}`, new_tab: true, close_library: drawer }).catch((err) =>
      toast(errorText(err, 'The Boost editor could not be opened.')),
    );

  const create = () =>
    void call('library.openUrl', { url: 'open://boosts/new', new_tab: true, close_library: drawer }).catch((err) =>
      toast(errorText(err, 'The Boost editor could not be opened.')),
    );

  const remove = (b: LibBoost) =>
    confirm({
      title: `Delete the Boost for ${b.host_pattern || b.name}?`,
      body: 'Its colors, fonts, code and Zaps are removed.',
      confirm: 'Delete Boost',
      danger: true,
      run: async () => {
        try {
          await call('boosts.delete', { id: b.id, profile_id: b.profile_id });
          setBoosts((prev) => prev.filter((x) => x.id !== b.id));
          toast('Deleted Boost.');
        } catch (err) {
          toast(errorText(err, 'That Boost could not be deleted.'));
        }
      },
    });

  const turnOn = async () => {
    try {
      await call('settings.setPreference', { key: 'advanced.enableBoosts', value: true });
      setGlobalEnabled(true);
      setTick((t) => t + 1);
    } catch (err) {
      toast(errorText(err, 'Boosts could not be turned on.'));
    }
  };

  const navRows: NavRow[] = boosts.map((b) => ({ key: `b:${b.id}`, activate: () => edit(b), remove: () => remove(b) }));
  useNavRows(navRows);

  const boostMenu = (e: MouseEvent, b: LibBoost) =>
    openMenu(e, `${b.name} actions`, [
      { label: b.enabled ? 'Turn Off' : 'Turn On', onSelect: () => void toggle(b) },
      { label: 'Edit…', icon: <PencilGlyph size={14} />, onSelect: () => edit(b) },
      { label: 'Delete…', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, onSelect: () => remove(b) },
    ]);

  const sub = (b: LibBoost) =>
    [b.name, b.enabled ? 'on' : 'off', b.zapped_elements.length ? `${b.zapped_elements.length} Zap${b.zapped_elements.length === 1 ? '' : 's'}` : '', multiProfile && profileId === 'all' ? profileNames[b.profile_id] : '']
      .filter(Boolean)
      .join(' · ');

  return (
    <div class="lib-section">
      <div class="lib-toolbar-row">
        <div class="lib-chip-row">
          <Chip selected={layout === 'list'} onClick={() => chooseLayout('list')}>
            List
          </Chip>
          <Chip selected={layout === 'gallery'} onClick={() => chooseLayout('gallery')}>
            Gallery
          </Chip>
        </div>
        <span class="lib-flex" />
        <button type="button" class="lib-chip" onClick={create}>
          <PlusGlyph size={12} /> New Boost
        </button>
      </div>
      {!globalEnabled && (
        <div class="lib-banner" role="status">
          <span>Boosts are turned off.</span>
          <button type="button" class="lib-btn lib-btn-primary" onClick={() => void turnOn()}>
            Turn On
          </button>
        </div>
      )}
      <div class="lib-list" role="listbox" aria-label="Boosts">
        {loaded && boosts.length === 0 ? (
          <EmptyState
            icon={<BoostsGlyph size={34} />}
            title={query ? 'No matches' : 'No Boosts yet'}
            body={query ? 'Try another word.' : 'Open a site and choose Boost to change how it looks.'}
            action={query ? undefined : { label: 'New Boost', onClick: create }}
          />
        ) : layout === 'list' ? (
          boosts.map((b) => (
            <Row
              key={b.id}
              navKey={`b:${b.id}`}
              dim={!b.enabled}
              icon={<BrushGlyph />}
              title={b.host_pattern || b.name}
              subtitle={sub(b)}
              onClick={() => edit(b)}
              onContextMenu={(e) => boostMenu(e, b)}
              actions={
                <>
                  <button type="button" class={`lib-onoff${b.enabled ? ' is-on' : ''}`} aria-pressed={b.enabled} onClick={() => void toggle(b)}>
                    {b.enabled ? 'On' : 'Off'}
                  </button>
                  <IconButton label="More" onClick={(e) => boostMenu(e, b)}>
                    <DotsGlyph />
                  </IconButton>
                </>
              }
            />
          ))
        ) : (
          boosts.map((b) => {
            const focused = nav.focusKey === `b:${b.id}`;
            return (
              <div
                key={b.id}
                class={`lib-boost-card${b.enabled ? '' : ' is-off'}${focused ? ' is-selected' : ''}${focused && nav.keyboard ? ' is-focus' : ''}`}
                data-nav-key={`b:${b.id}`}
                role="option"
                aria-selected={focused}
                aria-label={b.host_pattern || b.name}
                onMouseDown={() => nav.setFocusKey(`b:${b.id}`)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  boostMenu(e as unknown as MouseEvent, b);
                }}
              >
                <button type="button" class={`lib-onoff is-card${b.enabled ? ' is-on' : ''}`} aria-pressed={b.enabled} onClick={() => void toggle(b)}>
                  {b.enabled ? 'On' : 'Off'}
                </button>
                <div class="lib-boost-main">
                  <span class="lib-row-icon">
                    <BrushGlyph />
                  </span>
                  <div class="lib-row-text">
                    <div class="lib-row-title">{b.host_pattern || b.name}</div>
                    <div class="lib-row-sub">{sub(b)}</div>
                  </div>
                </div>
                <div class="lib-boost-foot">
                  <button type="button" class="lib-btn lib-btn-quiet" onClick={() => edit(b)}>
                    Edit…
                  </button>
                  <IconButton label="More" onClick={(e) => boostMenu(e, b)}>
                    <DotsGlyph />
                  </IconButton>
                </div>
              </div>
            );
          })
        )}
      </div>
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
