import type { JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import {
  type ArchivedTabRecord,
  type Boost,
  type DownloadRecord,
  type EaselSummary,
  type HistoryEntry,
  type MediaCaptureRecord,
  type ProfileSummary,
  type SpaceStyle,
  type SpaceSummary,
  RPC_EVENTS,
  rpc,
  subscribeEvent,
} from '../shared/bridge';
import {
  Badge,
  Card,
  Modal,
  ProfilePill,
  SearchInput,
  SegmentedControl,
  SpaceThemeEditor,
  Toast,
  Toggle,
  computeSpaceGradientCss,
  isLightSpaceStyle,
} from '../shared/components';
import { DownloadIcon, ExternalIcon, OpenDoorwayMark, TrashIcon } from '../shared/icons';
import { currentPageRoute, replacePageRoute } from '../shared/route';

type LibrarySection = 'history' | 'archive' | 'downloads' | 'spaces' | 'boosts' | 'media' | 'easels';

const RAIL_ITEMS: readonly { id: LibrarySection; label: string; glyph: string }[] = [
  { id: 'history', label: 'History', glyph: '🕒' },
  { id: 'archive', label: 'Archived', glyph: '📦' },
  { id: 'downloads', label: 'Downloads', glyph: '⬇️' },
  { id: 'spaces', label: 'Spaces', glyph: '🗂️' },
  { id: 'boosts', label: 'Boosts', glyph: '⚡' },
  { id: 'media', label: 'Media', glyph: '🖼️' },
  { id: 'easels', label: 'Easels', glyph: '🎨' },
];

function formatBytes(n: number): string {
  if (n < 0) return 'Unknown';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function formatTime(sec: number): string {
  if (!sec) return '';
  return new Date(sec * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

// open://library/<section>[/<id>] (C++ opens history, archive, downloads,
// media, and spaces/<space id> for the Space editor).
function parseInitialSection(): LibrarySection {
  const raw = currentPageRoute().segments[0];
  if (RAIL_ITEMS.some((r) => r.id === raw)) return raw as LibrarySection;
  return 'history';
}

function parseInitialSpaceId(): string | null {
  const { segments } = currentPageRoute();
  return segments[0] === 'spaces' && segments[1] ? segments[1] : null;
}

export function LibraryApp(): JSX.Element {
  const [section, setSection] = useState<LibrarySection>(parseInitialSection);
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [profileId, setProfileId] = useState<string>('all');
  const [queries, setQueries] = useState<Record<LibrarySection, string>>({
    history: '',
    archive: '',
    downloads: '',
    spaces: '',
    boosts: '',
    media: '',
    easels: '',
  });
  const [boostLayout, setBoostLayout] = useState<'list' | 'gallery'>('gallery');

  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [archive, setArchive] = useState<ArchivedTabRecord[]>([]);
  const [downloads, setDownloads] = useState<DownloadRecord[]>([]);
  const [spaces, setSpaces] = useState<SpaceSummary[]>([]);
  const [boosts, setBoosts] = useState<Boost[]>([]);
  const [media, setMedia] = useState<MediaCaptureRecord[]>([]);
  const [easels, setEasels] = useState<EaselSummary[]>([]);

  const [editingSpace, setEditingSpace] = useState<{
    id: string;
    title: string;
    emoji: string;
    style: SpaceStyle;
  } | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  // open://library/spaces/<id>: open that Space's editor once Spaces load.
  const [pendingSpaceId, setPendingSpaceId] = useState<string | null>(parseInitialSpaceId);
  const searchRef = useRef<HTMLInputElement | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2500);
  };

  const query = queries[section];
  const setQuery = (val: string) => setQueries((prev) => ({ ...prev, [section]: val }));

  useEffect(() => {
    void rpc('settings.listProfiles', {}).then((res) => setProfiles(res.profiles));
    const unsubDl = subscribeEvent(RPC_EVENTS.downloadUpdated, () => {
      void rpc('library.getDownloads', { profile_id: profileId, query: queries.downloads }).then((r) =>
        setDownloads(r.downloads),
      );
    });
    return () => unsubDl();
  }, []);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === 'Escape' && query) {
        setQuery('');
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [query, section]);

  useEffect(() => {
    let active = true;
    async function loadSection() {
      const q = queries[section];
      if (section === 'history') {
        const res = await rpc('library.getHistory', { profile_id: profileId, query: q });
        if (active) setHistory(res.entries);
      } else if (section === 'archive') {
        const res = await rpc('library.getArchive', { profile_id: profileId, query: q });
        if (active) setArchive(res.items);
      } else if (section === 'downloads') {
        const res = await rpc('library.getDownloads', { profile_id: profileId, query: q });
        if (active) setDownloads(res.downloads);
      } else if (section === 'spaces') {
        const res = await rpc('library.getSpaces', {});
        if (active) setSpaces(res.spaces);
      } else if (section === 'boosts') {
        const res = await rpc('boosts.list', { profile_id: profileId });
        if (active) setBoosts(res.boosts);
      } else if (section === 'media') {
        const res = await rpc('library.getMedia', { profile_id: profileId, query: q });
        if (active) setMedia(res.items);
      } else if (section === 'easels') {
        const res = await rpc('library.getEasels', { profile_id: profileId, query: q });
        if (active) setEasels(res.easels);
      }
    }
    void loadSection();
    return () => {
      active = false;
    };
  }, [section, profileId, queries[section]]);

  useEffect(() => {
    if (!pendingSpaceId || section !== 'spaces' || spaces.length === 0) return;
    const target = spaces.find((sp) => sp.id === pendingSpaceId);
    setPendingSpaceId(null);
    replacePageRoute('spaces');
    if (!target) {
      showToast('That Space no longer exists.');
      return;
    }
    setEditingSpace({
      id: target.id,
      title: target.title,
      emoji: target.icon.value,
      style: { ...target.style, key_color: { ...target.style.key_color } },
    });
  }, [pendingSpaceId, section, spaces]);

  const visibleSpaces = spaces.filter((s) => {
    if (profileId !== 'all' && s.profile_id !== profileId) return false;
    if (queries.spaces.trim() && !s.title.toLowerCase().includes(queries.spaces.trim().toLowerCase())) return false;
    return true;
  });

  const visibleBoosts = boosts.filter((b) => {
    const q = queries.boosts.trim().toLowerCase();
    if (!q) return true;
    return b.name.toLowerCase().includes(q) || b.host_pattern.toLowerCase().includes(q);
  });

  return (
    <div class="library-shell">
      <aside class="library-rail" aria-label="Library sections">
        <div class="library-rail-brand">
          <OpenDoorwayMark size={26} />
          <span>Library</span>
        </div>
        {RAIL_ITEMS.map((item) => (
          <button
            key={item.id}
            type="button"
            class={`library-rail-tile${section === item.id ? ' is-active' : ''}`}
            aria-current={section === item.id ? 'page' : undefined}
            onClick={() => setSection(item.id)}
          >
            <span class="library-rail-glyph" aria-hidden="true">
              {item.glyph}
            </span>
            <span>{item.label}</span>
          </button>
        ))}
      </aside>

      <main class="library-main">
        <header class="library-header">
          <h1>{RAIL_ITEMS.find((r) => r.id === section)?.label ?? 'Library'}</h1>
          <div class="library-toolbar">
            <div style={{ width: '240px' }}>
              <SearchInput
                inputRef={searchRef}
                value={query}
                onInput={setQuery}
                placeholder={`Search ${section}…`}
                ariaLabel={`Search ${section}`}
              />
            </div>
            {profiles.length > 0 && (
              <ProfilePill
                profiles={profiles}
                selectedProfileId={profileId}
                onChange={setProfileId}
                includeAllOption
              />
            )}
            {section === 'boosts' && (
              <SegmentedControl<'list' | 'gallery'>
                ariaLabel="Boost layout"
                value={boostLayout}
                options={[
                  { value: 'gallery', label: 'Gallery' },
                  { value: 'list', label: 'List' },
                ]}
                onChange={setBoostLayout}
              />
            )}
            {section === 'history' && history.length > 0 && (
              <button
                type="button"
                class="open-btn open-btn-danger"
                onClick={async () => {
                  await rpc('library.deleteHistory', {
                    clear_all: true,
                    profile_id: profileId === 'all' ? undefined : profileId,
                  });
                  setHistory([]);
                  showToast('Cleared browsing history.');
                }}
              >
                Clear All
              </button>
            )}
          </div>
        </header>

        {section === 'history' && (
          <Card>
            {history.length === 0 ? (
              <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                No matching history entries.
              </div>
            ) : (
              history.map((entry) => (
                <div key={entry.id} class="library-row">
                  <div class="library-row-main">
                    <div class="library-row-title">{entry.title || entry.url}</div>
                    <div class="library-row-sub">
                      {entry.url} · {entry.visit_count} visit{entry.visit_count === 1 ? '' : 's'} · {formatTime(entry.last_visit)}
                    </div>
                  </div>
                  <div style={{ display: 'flex', gap: '6px' }}>
                    <button
                      type="button"
                      class="open-btn"
                      onClick={async () => {
                        await rpc('library.openUrl', { url: entry.url, new_tab: true });
                        showToast(`Opened ${entry.title || entry.url}`);
                      }}
                    >
                      Open <ExternalIcon size={12} />
                    </button>
                    <button
                      type="button"
                      class="open-btn open-btn-ghost"
                      aria-label={`Delete ${entry.title}`}
                      onClick={async () => {
                        await rpc('library.deleteHistory', { ids: [entry.id] });
                        setHistory((prev) => prev.filter((h) => h.id !== entry.id));
                      }}
                    >
                      <TrashIcon size={13} />
                    </button>
                  </div>
                </div>
              ))
            )}
          </Card>
        )}

        {section === 'archive' && (
          <Card>
            {archive.length === 0 ? (
              <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                No archived tabs found.
              </div>
            ) : (
              archive.map((item) => (
                <div key={item.id} class="library-row">
                  <div class="library-row-main">
                    <div class="library-row-title">{item.title || item.url}</div>
                    <div class="library-row-sub">
                      {item.url} · {item.space_title ?? 'Space'} · {formatTime(item.archived_at)}
                    </div>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <Badge>{item.reason}</Badge>
                    <button
                      type="button"
                      class="open-btn open-btn-primary"
                      onClick={async () => {
                        const res = await rpc('library.restoreArchived', { id: item.id });
                        setArchive((prev) => prev.filter((a) => a.id !== item.id));
                        showToast(`Restored ${res.restored_url || item.title}`);
                      }}
                    >
                      Restore
                    </button>
                  </div>
                </div>
              ))
            )}
          </Card>
        )}

        {section === 'downloads' && (
          <Card>
            {downloads.length === 0 ? (
              <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                No downloads yet.
              </div>
            ) : (
              downloads.map((dl) => {
                const pct =
                  dl.state === 'completed'
                    ? 100
                    : dl.total_bytes > 0
                      ? Math.min(100, Math.round((dl.received_bytes / dl.total_bytes) * 100))
                      : 0;
                return (
                  <div key={dl.id} class="library-row">
                    <div
                      class="download-ring"
                      style={{
                        background: `conic-gradient(var(--open-accent) ${pct}%, var(--bg-input) ${pct}%)`,
                      }}
                    >
                      <span
                        style={{
                          width: '26px',
                          height: '26px',
                          borderRadius: '50%',
                          background: 'var(--bg-card)',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                        }}
                      >
                        {dl.state === 'completed' ? <DownloadIcon size={12} /> : `${pct}%`}
                      </span>
                    </div>
                    <div class="library-row-main">
                      <div class="library-row-title">{dl.filename}</div>
                      <div class="library-row-sub">
                        {formatBytes(dl.received_bytes)} / {formatBytes(dl.total_bytes)} · {dl.target_path}
                      </div>
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                      <Badge tone={dl.state === 'completed' ? 'success' : dl.state === 'in_progress' ? 'accent' : 'sun'}>
                        {dl.state.replace('_', ' ')}
                      </Badge>
                      <button
                        type="button"
                        class="open-btn"
                        onClick={async () => {
                          await rpc('library.openDownload', { id: dl.id, reveal: false });
                          showToast(`Opened ${dl.filename}`);
                        }}
                      >
                        Open
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </Card>
        )}

        {section === 'spaces' && (
          <div class="spaces-grid">
            {visibleSpaces.map((sp) => {
              const lightText = !isLightSpaceStyle(sp.style);
              const prof = profiles.find((p) => p.id === sp.profile_id);
              return (
                <div
                  key={sp.id}
                  class="space-card"
                  style={{
                    background: computeSpaceGradientCss(sp.style),
                    color: lightText ? '#ffffff' : '#14151f',
                  }}
                >
                  <div class="space-card-noise" style={{ opacity: sp.style.noise_factor * 0.6 }} />
                  <div class="space-card-content">
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                      <div>
                        <div style={{ fontSize: '20px', marginBottom: '4px' }}>{sp.icon.value}</div>
                        <div style={{ fontSize: '16px', fontWeight: 700 }}>{sp.title}</div>
                        <div style={{ fontSize: '11.5px', opacity: 0.85 }}>{prof?.name ?? 'Profile'}</div>
                      </div>
                      <span
                        style={{
                          fontSize: '11px',
                          padding: '3px 8px',
                          borderRadius: '999px',
                          background: lightText ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.1)',
                        }}
                      >
                        {sp.pinned_count} pinned · {sp.today_count} today
                      </span>
                    </div>

                    <div style={{ display: 'flex', gap: '6px' }}>
                      <button
                        type="button"
                        class="open-btn"
                        style={{
                          background: lightText ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.1)',
                          borderColor: 'transparent',
                          color: 'inherit',
                        }}
                        onClick={() =>
                          setEditingSpace({
                            id: sp.id,
                            title: sp.title,
                            emoji: sp.icon.value,
                            style: { ...sp.style, key_color: { ...sp.style.key_color } },
                          })
                        }
                      >
                        Edit Theme
                      </button>
                      <button
                        type="button"
                        class="open-btn"
                        style={{
                          background: lightText ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.08)',
                          borderColor: 'transparent',
                          color: 'inherit',
                        }}
                        onClick={async () => {
                          try {
                            await rpc('library.deleteSpace', { id: sp.id });
                            setSpaces((prev) => prev.filter((x) => x.id !== sp.id));
                            showToast(`Deleted Space "${sp.title}".`);
                          } catch (err) {
                            showToast(err instanceof Error ? err.message : 'Cannot delete Space.');
                          }
                        }}
                      >
                        Delete
                      </button>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {section === 'boosts' &&
          (visibleBoosts.length === 0 ? (
            <Card>
              <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                No Boosts yet. Create custom colors, typography, CSS, or Zaps on any website.
              </div>
            </Card>
          ) : boostLayout === 'gallery' ? (
            <div class="boosts-gallery-grid">
              {visibleBoosts.map((b) => (
                <Card key={b.id}>
                  <div style={{ padding: '14px', display: 'flex', flexDirection: 'column', gap: '10px' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <Badge tone="accent">⚡ {b.host_pattern}</Badge>
                      <Toggle
                        label={`Toggle ${b.name}`}
                        checked={b.enabled}
                        onChange={async (enabled) => {
                          const res = await rpc('boosts.toggle', { id: b.id, enabled });
                          setBoosts((prev) => prev.map((x) => (x.id === b.id ? res.boost : x)));
                        }}
                      />
                    </div>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: '14px' }}>{b.name}</div>
                      <div style={{ fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                        {Math.round(b.text_zoom * 100)}% text · {b.zapped_elements.length} Zap
                        {b.zapped_elements.length === 1 ? '' : 's'}
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: '8px' }}>
                      <button
                        type="button"
                        class="open-btn open-btn-primary"
                        onClick={() => void rpc('library.openUrl', { url: `open://boosts#${b.id}`, new_tab: true })}
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="open-btn open-btn-danger"
                        onClick={async () => {
                          await rpc('boosts.delete', { id: b.id });
                          setBoosts((prev) => prev.filter((x) => x.id !== b.id));
                          showToast(`Deleted Boost "${b.name}".`);
                        }}
                      >
                        Delete
                      </button>
                    </div>
                  </div>
                </Card>
              ))}
            </div>
          ) : (
            <Card>
              {visibleBoosts.map((b) => (
                <div key={b.id} class="library-row">
                  <div class="library-row-main">
                    <div class="library-row-title">{b.name}</div>
                    <div class="library-row-sub">
                      {b.host_pattern} · {b.zapped_elements.length} Zaps · {b.font_family ?? 'Default font'}
                    </div>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <Toggle
                      label={`Toggle ${b.name}`}
                      checked={b.enabled}
                      onChange={async (enabled) => {
                        const res = await rpc('boosts.toggle', { id: b.id, enabled });
                        setBoosts((prev) => prev.map((x) => (x.id === b.id ? res.boost : x)));
                      }}
                    />
                    <button
                      type="button"
                      class="open-btn"
                      onClick={() => void rpc('library.openUrl', { url: `open://boosts#${b.id}`, new_tab: true })}
                    >
                      Edit
                    </button>
                  </div>
                </div>
              ))}
            </Card>
          ))}

        {section === 'media' &&
          (media.length === 0 ? (
            <Card>
              <div style={{ padding: '32px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                Captures appear here. Take a page capture to save or add it to an Easel.
              </div>
            </Card>
          ) : (
            <div class="media-grid">
              {media.map((m) => (
                <div key={m.id} class="media-card">
                  <div class="media-thumb" style={{ background: m.preview_gradient }}>
                    {m.width} × {m.height}
                  </div>
                  <div style={{ padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: '4px' }}>
                    <div class="library-row-title">{m.title}</div>
                    <div class="library-row-sub">{formatTime(m.captured_at)}</div>
                  </div>
                </div>
              ))}
            </div>
          ))}

        {section === 'easels' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            <Card>
              <div style={{ padding: '16px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '12px' }}>
                <div>
                  <div style={{ fontWeight: 700, fontSize: '14px' }}>Your Easels are yours to keep</div>
                  <div style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>
                    Easels stay local on your machine with full HTML export support.
                  </div>
                </div>
                <button
                  type="button"
                  class="open-btn open-btn-primary"
                  onClick={() => showToast(`Prepared export for ${easels.length} Easel(s).`)}
                >
                  Export All Easels
                </button>
              </div>
            </Card>
            <Card>
              {easels.length === 0 ? (
                <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-secondary)' }}>
                  No Easels yet. Press Ctrl+Shift+E to create your first Easel.
                </div>
              ) : (
                easels.map((e) => (
                  <div key={e.id} class="library-row">
                    <div class="library-row-main">
                      <div class="library-row-title">{e.title}</div>
                      <div class="library-row-sub">
                        {e.element_count} objects · {e.palette} palette · Updated {formatTime(e.modified_at)}
                      </div>
                    </div>
                    <button
                      type="button"
                      class="open-btn open-btn-primary"
                      onClick={() => void rpc('library.openUrl', { url: `open://easel/${e.id}`, new_tab: true })}
                    >
                      Open Easel
                    </button>
                  </div>
                ))
              )}
            </Card>
          </div>
        )}
      </main>

      <Modal
        open={Boolean(editingSpace)}
        title={`Edit Space "${editingSpace?.title ?? ''}"`}
        onClose={() => setEditingSpace(null)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setEditingSpace(null)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              onClick={async () => {
                if (!editingSpace) return;
                const res = await rpc('library.updateSpace', {
                  id: editingSpace.id,
                  title: editingSpace.title,
                  icon: { kind: 'emoji', value: editingSpace.emoji || '✨' },
                  style: editingSpace.style,
                });
                setSpaces((prev) => prev.map((s) => (s.id === res.space.id ? res.space : s)));
                setEditingSpace(null);
                showToast(`Saved Space "${res.space.title}".`);
              }}
            >
              Save Space
            </button>
          </>
        }
      >
        {editingSpace && (
          <>
            <div style={{ display: 'flex', gap: '8px' }}>
              <input
                class="open-input"
                style={{ width: '56px', textAlign: 'center' }}
                value={editingSpace.emoji}
                onInput={(e) =>
                  setEditingSpace({ ...editingSpace, emoji: (e.currentTarget as HTMLInputElement).value })
                }
              />
              <input
                class="open-input"
                style={{ flex: 1 }}
                value={editingSpace.title}
                onInput={(e) =>
                  setEditingSpace({ ...editingSpace, title: (e.currentTarget as HTMLInputElement).value })
                }
              />
            </div>
            <SpaceThemeEditor
              title={editingSpace.title}
              style={editingSpace.style}
              onChange={(style) => setEditingSpace({ ...editingSpace, style })}
            />
          </>
        )}
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
