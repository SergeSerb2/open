import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { call, errorText } from './api';
import { DotsGlyph, EaselsGlyph, NoteGlyph, OpenGlyph, PlusGlyph, TrashGlyph } from './icons';
import type { LibDocument } from './types';
import { EmptyState, IconButton, Menu, Row, dayLabel, formatClock, useMenu, useNavRows, type NavRow, type SectionProps } from './ui';

function modified(sec: number): string {
  if (!sec) return '';
  const day = dayLabel(sec);
  return day === 'Today' || day === 'Yesterday' ? `${day}, ${formatClock(sec)}` : day;
}

export function DocumentsSection(props: SectionProps): JSX.Element {
  const { profileId, query, refreshKey, toast, confirm, drawer, profileNames, multiProfile } = props;
  const [easels, setEasels] = useState<LibDocument[]>([]);
  const [notes, setNotes] = useState<LibDocument[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [tick, setTick] = useState(0);
  const { menu, openMenu, closeMenu } = useMenu();

  useEffect(() => {
    let live = true;
    call('library.documents.list', { profile_id: profileId, query })
      .then((res) => {
        if (!live) return;
        setEasels(res.easels);
        setNotes(res.notes);
      })
      .catch((err) => live && toast(errorText(err, 'Easels and Notes could not be loaded.')))
      .finally(() => live && setLoaded(true));
    return () => {
      live = false;
    };
  }, [profileId, query, refreshKey, tick]);

  const open = (doc: LibDocument) =>
    void call('library.openUrl', { url: doc.url, new_tab: true, close_library: drawer }).catch((err) =>
      toast(errorText(err, 'The document could not be opened.')),
    );

  const create = async (kind: 'easel' | 'note') => {
    try {
      await call('library.documents.create', { kind, profile_id: profileId === 'all' ? undefined : profileId, open: true });
      setTick((t) => t + 1);
      if (drawer) props.closeLibrary();
    } catch (err) {
      toast(errorText(err, `The ${kind === 'easel' ? 'Easel' : 'Note'} could not be created.`));
    }
  };

  const remove = (doc: LibDocument) =>
    confirm({
      title: `Delete “${doc.title || (doc.kind === 'easel' ? 'Untitled Easel' : 'Untitled Note')}”?`,
      body: 'You cannot undo this.',
      confirm: 'Delete',
      danger: true,
      run: async () => {
        try {
          await call('library.documents.delete', { kind: doc.kind, id: doc.id, profile_id: doc.profile_id });
          (doc.kind === 'easel' ? setEasels : setNotes)((prev) => prev.filter((d) => d.id !== doc.id));
          toast('Deleted.');
        } catch (err) {
          toast(errorText(err, 'That document could not be deleted.'));
        }
      },
    });

  const all = [...easels, ...notes];
  const navRows: NavRow[] = all.map((d) => ({ key: `doc:${d.kind}:${d.id}`, activate: () => open(d), remove: () => remove(d) }));
  useNavRows(navRows);

  const docMenu = (e: MouseEvent, d: LibDocument) =>
    openMenu(e, `${d.title} actions`, [
      { label: 'Open', icon: <OpenGlyph size={14} />, onSelect: () => open(d) },
      { label: 'Delete…', icon: <TrashGlyph size={14} />, danger: true, separatorBefore: true, onSelect: () => remove(d) },
    ]);

  const group = (title: string, kind: 'easel' | 'note', docs: LibDocument[]) => (
    <div class="lib-doc-group">
      <div class="lib-doc-head">
        <span class="lib-heading is-inline">{title}</span>
        <button type="button" class="lib-chip" onClick={() => void create(kind)}>
          <PlusGlyph size={12} /> {kind === 'easel' ? 'New Easel' : 'New Note'}
        </button>
      </div>
      {docs.length === 0 ? (
        <div class="lib-doc-empty">
          {query ? 'No matches.' : kind === 'easel' ? 'Click the + sign in the Sidebar to create a new Easel.' : 'Notes you write appear here.'}
        </div>
      ) : (
        docs.map((d) => (
          <Row
            key={d.id}
            navKey={`doc:${d.kind}:${d.id}`}
            icon={<span class={`lib-doc-icon is-${d.kind}`}>{d.kind === 'easel' ? <EaselsGlyph size={20} /> : <NoteGlyph size={18} />}</span>}
            title={d.title || (d.kind === 'easel' ? 'Untitled Easel' : 'Untitled Note')}
            subtitle={[
              d.kind === 'easel' && d.element_count !== undefined ? `${d.element_count} item${d.element_count === 1 ? '' : 's'}` : '',
              modified(d.modified_at),
              multiProfile && profileId === 'all' ? profileNames[d.profile_id] : '',
            ]
              .filter(Boolean)
              .join(' · ')}
            onClick={() => open(d)}
            onContextMenu={(e) => docMenu(e, d)}
            actions={
              <>
                <IconButton label="Delete" onClick={() => remove(d)}>
                  <TrashGlyph />
                </IconButton>
                <IconButton label="More" onClick={(e) => docMenu(e, d)}>
                  <DotsGlyph />
                </IconButton>
              </>
            }
          />
        ))
      )}
    </div>
  );

  return (
    <div class="lib-section">
      <div class="lib-list" role="listbox" aria-label="Easels and Notes">
        {loaded && all.length === 0 && !query ? (
          <EmptyState
            icon={<EaselsGlyph size={34} />}
            title="No Easels or Notes yet"
            body="Easels hold live page cards, images and drawings. Notes hold your writing."
            action={{ label: 'New Easel', onClick: () => void create('easel') }}
          />
        ) : (
          <>
            {group('Easels', 'easel', easels)}
            {group('Notes', 'note', notes)}
          </>
        )}
      </div>
      {menu && <Menu anchor={menu.anchor} items={menu.items} label={menu.label} onClose={closeMenu} />}
    </div>
  );
}
