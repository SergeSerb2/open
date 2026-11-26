import type { JSX } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import { isNativeWebUI } from '../shared/bridge';
import { call, errorText } from './api';
import { CloseGlyph, CopyGlyph, FolderGlyph, MediaGlyph, OpenGlyph, PlayGlyph, PlusGlyph, RevealGlyph, TrashGlyph } from './icons';
import type { LibMediaItem, MediaSource } from './types';
import {
  Chip,
  EmptyState,
  IconButton,
  Menu,
  NavContext,
  Sheet,
  dayLabel,
  formatBytes,
  revealLabel,
  useEscape,
  useMenu,
  useNavRows,
  useSlowFlag,
  type NavRow,
  type SectionProps,
} from './ui';

const SOURCES: { value: MediaSource | 'all'; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'capture', label: 'Captures' },
  { value: 'download', label: 'Downloads' },
  { value: 'folder', label: 'Folders' },
];

const PRESETS: { value: string; label: string }[] = [
  { value: 'desktop', label: 'Desktop' },
  { value: 'documents', label: 'Documents' },
  { value: 'downloads', label: 'Downloads' },
  { value: 'pictures', label: 'Pictures' },
];

/** Copies decoded pixels as PNG (async clipboard); the C++ fallback writes the file. */
async function copyImage(item: LibMediaItem): Promise<void> {
  try {
    const blob = await fetch(item.file_url).then((r) => {
      if (!r.ok) throw new Error('fetch');
      return r.blob();
    });
    const png =
      blob.type === 'image/png'
        ? blob
        : await new Promise<Blob>((resolve, reject) => {
            const img = new Image();
            const url = URL.createObjectURL(blob);
            img.onload = () => {
              const canvas = document.createElement('canvas');
              canvas.width = img.naturalWidth;
              canvas.height = img.naturalHeight;
              canvas.getContext('2d')?.drawImage(img, 0, 0);
              URL.revokeObjectURL(url);
              canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('encode'))), 'image/png');
            };
            img.onerror = () => {
              URL.revokeObjectURL(url);
              reject(new Error('decode'));
            };
            img.src = url;
          });
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })]);
  } catch {
    await call('library.media.copyImage', { id: item.id });
  }
}

function Lightbox({
  item,
  onClose,
  actions,
}: {
  item: LibMediaItem;
  onClose: () => void;
  actions: { copy: () => void; open: () => void; reveal: () => void; trash: () => void; source: () => void };
}): JSX.Element {
  useEscape(true, onClose);
  return (
    <div class="lib-lightbox" role="dialog" aria-modal="true" aria-label={item.title} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class="lib-lightbox-frame">
        {item.kind === 'video' ? (
          <video src={item.file_url} controls autoPlay class="lib-lightbox-media" />
        ) : (
          <img src={item.file_url} alt={item.title} class="lib-lightbox-media" />
        )}
      </div>
      <div class="lib-lightbox-bar">
        <div class="lib-lightbox-meta">
          <div class="lib-lightbox-title">{item.title}</div>
          <div class="lib-lightbox-sub">
            {[item.folder, dayLabel(item.captured_at), formatBytes(item.size)].filter(Boolean).join(' · ')}
          </div>
        </div>
        {item.kind === 'image' && (
          <IconButton label="Copy Image" onClick={actions.copy}>
            <CopyGlyph />
          </IconButton>
        )}
        <IconButton label="Open" onClick={actions.open}>
          <OpenGlyph />
        </IconButton>
        <IconButton label={revealLabel()} onClick={actions.reveal}>
          <RevealGlyph />
        </IconButton>
        {item.source_url && (
          <button type="button" class="lib-btn" onClick={actions.source}>
            Open Page
          </button>
        )}
        <IconButton label="Move to Trash" danger onClick={actions.trash}>
          <TrashGlyph />
        </IconButton>
        <IconButton label="Close" onClick={onClose}>
          <CloseGlyph />
        </IconButton>
      </div>
    </div>
  );
}

export function MediaSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, drawer } = props;
  const [items, setItems] = useState<LibMediaItem[]>([]);
  const [folders, setFolders] = useState<string[]>([]);
  const [source, setSource] = useState<MediaSource | 'all'>('all');
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  const [lightbox, setLightbox] = useState<LibMediaItem | null>(null);
  const [customPath, setCustomPath] = useState<string | null>(null);
  const nav = useContext(NavContext);
  const { menu, openMenu, closeMenu } = useMenu();
  const slow = useSlowFlag(loading);
  // Folder Sources belong to one Profile; "All Profiles" edits the page's own.
  const folderProfile = profileId === 'all' ? undefined : profileId;

  useEffect(() => {
    let live = true;
    setLoading(true);
    call('library.media.list', { profile_id: profileId, query, source })
      .then((res) => {
        if (!live) return;
        setItems(res.items);
        setFolders(res.folders);
      })
      .catch((err) => live && toast(errorText(err, 'Media could not be loaded.')))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [profileId, query, source, refreshKey, tick]);

  const act = async (method: 'library.media.open' | 'library.media.reveal', item: LibMediaItem) => {
    try {
      await call(method, { id: item.id });
    } catch (err) {
      toast(errorText(err, 'The file is not available.'));
    }
  };

  const trash = (item: LibMediaItem) =>
    confirm({
      title: `Move “${item.title}” to the Trash?`,
      body: item.source === 'folder' ? 'This file is in one of your own folders.' : undefined,
      confirm: 'Move to Trash',
      danger: true,
      run: async () => {
        try {
          await call('library.media.delete', { id: item.id });
          setItems((prev) => prev.filter((x) => x.id !== item.id));
          setLightbox(null);
          toast('Moved to the Trash.');
        } catch (err) {
          toast(errorText(err, 'The file could not be moved to the Trash.'));
        }
      },
    });

  const copy = async (item: LibMediaItem) => {
    try {
      await copyImage(item);
      toast('Copied image.');
    } catch (err) {
      toast(errorText(err, 'The image could not be copied.'));
    }
  };

  const openSource = (item: LibMediaItem) =>
    void call('library.openUrl', { url: item.source_url, new_tab: true, close_library: drawer }).catch((err) =>
      toast(errorText(err, 'The page could not be opened.')),
    );

  const addFolder = async (payload: { preset?: string; path?: string }) => {
    try {
      await call('library.media.addFolder', { ...payload, profile_id: folderProfile });
      toast('Added folder.');
      setTick((t) => t + 1);
    } catch (err) {
      toast(errorText(err, 'The folder could not be added.'));
    }
  };

  const removeFolder = async (path: string) => {
    try {
      await call('library.media.removeFolder', { path, profile_id: folderProfile });
      setTick((t) => t + 1);
    } catch (err) {
      toast(errorText(err, 'The folder could not be removed.'));
    }
  };

  const addMenu = (e: MouseEvent) =>
    openMenu(e, 'Add folder', [
      ...PRESETS.map((p) => ({
        label: p.label,
        icon: <FolderGlyph size={14} />,
        checked: folders.some((f) => f.split(/[\\/]/).pop() === p.label),
        onSelect: () => void addFolder({ preset: p.value }),
      })),
      { label: 'Other Folder…', separatorBefore: true, onSelect: () => setCustomPath('') },
    ]);

  const itemMenu = (e: MouseEvent, item: LibMediaItem) =>
    openMenu(e, `${item.title} actions`, [
      ...(item.kind === 'image' ? [{ label: 'Copy Image', icon: <CopyGlyph size={14} />, onSelect: () => void copy(item) }] : []),
      { label: 'Open', icon: <OpenGlyph size={14} />, onSelect: () => void act('library.media.open', item) },
      { label: revealLabel(), icon: <RevealGlyph size={14} />, onSelect: () => void act('library.media.reveal', item) },
      ...(item.source_url ? [{ label: 'Open Page', onSelect: () => openSource(item) }] : []),
      { label: 'Move to Trash', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, onSelect: () => trash(item) },
    ]);

  const navRows: NavRow[] = items.map((item) => ({ key: `m:${item.id}`, activate: () => setLightbox(item), remove: () => trash(item) }));
  useNavRows(navRows);

  return (
    <div class="lib-section">
      <div class="lib-toolbar-row">
        <div class="lib-chip-row is-scroll">
          {SOURCES.map((s) => (
            <Chip key={s.value} selected={source === s.value} onClick={() => setSource(s.value)}>
              {s.label}
            </Chip>
          ))}
        </div>
      </div>
      <div class="lib-folder-chips" aria-label="Folder sources">
          {folders.map((f) => (
            <span key={f} class="lib-folder-chip" title={f}>
              <FolderGlyph size={13} />
              <span>{f.split(/[\\/]/).filter(Boolean).pop() ?? f}</span>
              <button type="button" aria-label={`Remove ${f}`} onClick={() => void removeFolder(f)}>
                <CloseGlyph size={10} />
              </button>
            </span>
          ))}
          <button type="button" class="lib-folder-chip is-add" onClick={addMenu}>
            <PlusGlyph size={12} />
            <span>Add Folder</span>
          </button>
      </div>
      <div class="lib-list">
        {loading && items.length === 0 ? (
          slow ? (
            <div class="lib-media-grid" aria-hidden="true">
              {Array.from({ length: 6 }, (_, i) => (
                <div key={i} class="lib-media-tile is-skeleton" />
              ))}
            </div>
          ) : null
        ) : items.length === 0 ? (
          <EmptyState
            icon={<MediaGlyph size={34} />}
            title={query || source !== 'all' ? 'No matches' : 'No media yet'}
            body={
              query || source !== 'all'
                ? 'Try another word or source.'
                : 'Page captures you take appear here. Quickly grab screenshots, images, and videos from your computer by showing their folders here too.'
            }
            action={query || source !== 'all' ? undefined : { label: 'Show a Folder…', onClick: () => setCustomPath('') }}
          />
        ) : (
          <div class="lib-media-grid" role="listbox" aria-label="Media">
            {items.map((item) => (
              <button
                key={item.id}
                type="button"
                class={`lib-media-tile${nav.focusKey === `m:${item.id}` ? ' is-selected' : ''}${nav.focusKey === `m:${item.id}` && nav.keyboard ? ' is-focus' : ''}`}
                data-nav-key={`m:${item.id}`}
                title={item.title}
                onMouseDown={() => nav.setFocusKey(`m:${item.id}`)}
                onClick={() => setLightbox(item)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  itemMenu(e as unknown as MouseEvent, item);
                }}
                draggable={item.kind === 'image'}
              >
                {item.thumb_url ? (
                  <img src={item.thumb_url} alt="" loading="lazy" decoding="async" />
                ) : (
                  <video src={`${item.file_url}#t=0.1`} preload="metadata" muted playsInline />
                )}
                {item.kind === 'video' && (
                  <span class="lib-media-play">
                    <PlayGlyph />
                  </span>
                )}
                <span class="lib-media-caption">
                  <span class="lib-media-title">{item.title}</span>
                  <span class="lib-media-sub">{item.source === 'folder' ? item.folder : dayLabel(item.captured_at)}</span>
                </span>
              </button>
            ))}
          </div>
        )}
      </div>
      {lightbox && (
        <Lightbox
          item={lightbox}
          onClose={() => setLightbox(null)}
          actions={{
            copy: () => void copy(lightbox),
            open: () => void act('library.media.open', lightbox),
            reveal: () => void act('library.media.reveal', lightbox),
            trash: () => trash(lightbox),
            source: () => openSource(lightbox),
          }}
        />
      )}
      {customPath !== null && (
        <Sheet
          title="Show a Folder in Media"
          onClose={() => setCustomPath(null)}
          footer={
            <>
              <button type="button" class="lib-btn" onClick={() => setCustomPath(null)}>
                Cancel
              </button>
              <button
                type="button"
                class="lib-btn lib-btn-primary"
                disabled={!customPath.trim()}
                onClick={() => {
                  const path = customPath.trim();
                  setCustomPath(null);
                  void addFolder({ path });
                }}
              >
                Add Folder
              </button>
            </>
          }
        >
          <p class="lib-sheet-text">Images and videos in this folder appear alongside your Captures. Choose a common folder or type a full path inside your home folder.</p>
          <div class="lib-chip-row">
            {PRESETS.map((p) => (
              <Chip
                key={p.value}
                onClick={() => {
                  setCustomPath(null);
                  void addFolder({ preset: p.value });
                }}
              >
                {p.label}
              </Chip>
            ))}
          </div>
          <input
            class="lib-input"
            data-autofocus
            placeholder={isNativeWebUI() ? '/Users/you/Pictures/Screenshots' : '/Users/you/Pictures'}
            value={customPath}
            spellcheck={false}
            onInput={(e) => setCustomPath((e.currentTarget as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && customPath.trim()) {
                const path = customPath.trim();
                setCustomPath(null);
                void addFolder({ path });
              }
            }}
          />
        </Sheet>
      )}
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
