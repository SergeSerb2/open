import type { JSX } from 'preact';
import { useState } from 'preact/hooks';
import { rpc, type SettingsSpace, type SpaceStyle } from '../shared/bridge';
import { Modal, SpaceThemeEditor, computeSpaceGradientCss } from '../shared/components';
import { PencilIcon, PlusIcon, TrashIcon } from '../shared/icons';
import { plural, useSettings } from './context';
import { Btn, ConfirmDialog, EmptyRow, Field, Group, PaneHeader, Select, TextInput } from './ui';

const ARCHIVE_LABELS: Record<string, string> = {
  never: 'Never',
  '1h': '1 hour',
  '6h': '6 hours',
  '12h': '12 hours',
  '24h': '24 hours',
  '7d': '7 days',
  '30d': '30 days',
};

export function SpacesPane(): JSX.Element {
  const ctx = useSettings();
  const [theming, setTheming] = useState<{ space: SettingsSpace; style: SpaceStyle } | null>(null);
  const [renaming, setRenaming] = useState<{ space: SettingsSpace; title: string } | null>(null);
  const [deleting, setDeleting] = useState<SettingsSpace | null>(null);
  const [creating, setCreating] = useState<{ title: string; profileId: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const profileOptions = ctx.profiles.map((p) => ({ value: p.id, label: p.name }));

  return (
    <div class="st-pane">
      <PaneHeader section="spaces" />
      <Group
        title="Your Spaces"
        action={
          <Btn onClick={() => setCreating({ title: '', profileId: ctx.profileId || ctx.profiles[0]?.id || '' })}>
            <PlusIcon size={12} /> New Space…
          </Btn>
        }
      >
        <div id="row-spaces-list" />
        {ctx.spaces.length === 0 && <EmptyRow>No Spaces yet.</EmptyRow>}
        {ctx.spaces.map((space) => {
          const owner = ctx.profiles.find((p) => p.id === space.profile_id);
          const archive = owner ? ARCHIVE_LABELS[owner.settings.auto_archive_after] ?? owner.settings.auto_archive_after : '';
          return (
            <div key={space.id} class="st-row st-space-row">
              <button
                type="button"
                class="st-space-swatch"
                style={{ background: computeSpaceGradientCss(space.style) }}
                title={`Edit the theme of ${space.display_title}`}
                onClick={() => setTheming({ space, style: { ...space.style, key_color: { ...space.style.key_color } } })}
              >
                {space.icon.kind === 'emoji' ? <span>{space.icon.value}</span> : <span class="st-space-dot" />}
              </button>
              <div class="st-row-meta">
                <div class="st-row-label">{space.display_title}</div>
                <div class="st-row-help">
                  {plural(space.pinned_count, 'pinned tab')} · {plural(space.today_count, 'Today tab')}
                  {archive && ` · Today tabs archive after ${archive}`}
                </div>
              </div>
              <div class="st-row-control">
                <Select
                  ariaLabel={`Profile of ${space.display_title}`}
                  value={space.profile_id}
                  options={profileOptions}
                  onChange={async (profileId) => {
                    const res = await ctx.run(() => rpc('settings.spaces.setProfile', { space_id: space.id, profile_id: profileId }), `${space.display_title} now uses ${ctx.profiles.find((p) => p.id === profileId)?.name ?? 'that Profile'}.`);
                    if (res) await Promise.all([ctx.reloadSpaces(), ctx.reloadProfiles()]);
                  }}
                />
                <Btn small onClick={() => setTheming({ space, style: { ...space.style, key_color: { ...space.style.key_color } } })}>
                  Edit Theme…
                </Btn>
                <Btn kind="ghost" small title={`Rename ${space.display_title}`} onClick={() => setRenaming({ space, title: space.title })}>
                  <PencilIcon size={13} />
                </Btn>
                <Btn kind="ghost" small title={`Delete ${space.display_title}`} disabled={ctx.spaces.length <= 1} onClick={() => setDeleting(space)}>
                  <TrashIcon size={13} />
                </Btn>
              </div>
            </div>
          );
        })}
      </Group>

      <Modal
        open={theming !== null}
        title={`Theme · ${theming?.space.display_title ?? ''}`}
        onClose={() => setTheming(null)}
        footer={
          <>
            <Btn onClick={() => setTheming(null)}>Cancel</Btn>
            <Btn
              kind="primary"
              busy={busy}
              onClick={async () => {
                if (!theming) return;
                setBusy(true);
                const res = await ctx.run(() => rpc('library.updateSpace', { id: theming.space.id, style: theming.style }), 'Theme saved.');
                setBusy(false);
                if (res) {
                  setTheming(null);
                  await ctx.reloadSpaces();
                }
              }}
            >
              Save Theme
            </Btn>
          </>
        }
      >
        {theming && <SpaceThemeEditor style={theming.style} title={theming.space.display_title} onChange={(style) => setTheming({ ...theming, style })} />}
      </Modal>

      <Modal
        open={renaming !== null}
        title="Rename Space"
        onClose={() => setRenaming(null)}
        footer={
          <>
            <Btn onClick={() => setRenaming(null)}>Cancel</Btn>
            <Btn
              kind="primary"
              disabled={!renaming?.title.trim()}
              onClick={async () => {
                if (!renaming) return;
                const res = await ctx.run(() => rpc('settings.spaces.rename', { space_id: renaming.space.id, title: renaming.title }), 'Space renamed.');
                if (res) {
                  setRenaming(null);
                  await ctx.reloadSpaces();
                }
              }}
            >
              Save
            </Btn>
          </>
        }
      >
        <Field label="Name">
          <TextInput value={renaming?.title ?? ''} onInput={(v) => renaming && setRenaming({ ...renaming, title: v })} ariaLabel="Space name" autoFocus />
        </Field>
      </Modal>

      <Modal
        open={creating !== null}
        title="New Space"
        onClose={() => setCreating(null)}
        footer={
          <>
            <Btn onClick={() => setCreating(null)}>Cancel</Btn>
            <Btn
              kind="primary"
              onClick={async () => {
                if (!creating) return;
                const res = await ctx.run(() => rpc('settings.spaces.create', { profile_id: creating.profileId, title: creating.title }), 'Space created.');
                if (res) {
                  setCreating(null);
                  await Promise.all([ctx.reloadSpaces(), ctx.reloadProfiles()]);
                }
              }}
            >
              Create Space
            </Btn>
          </>
        }
      >
        <Field label="Name">
          <TextInput value={creating?.title ?? ''} onInput={(v) => creating && setCreating({ ...creating, title: v })} ariaLabel="Space name" placeholder="Side Project" autoFocus />
        </Field>
        <Field label="Profile">
          <Select ariaLabel="Profile" wide value={creating?.profileId ?? ''} options={profileOptions} onChange={(v) => creating && setCreating({ ...creating, profileId: v })} />
        </Field>
      </Modal>

      <ConfirmDialog
        open={deleting !== null}
        title={`Delete ${deleting?.display_title ?? 'Space'}?`}
        confirmLabel="Delete Space"
        danger
        onConfirm={async () => {
          if (!deleting) return;
          const res = await ctx.run(() => rpc('library.deleteSpace', { id: deleting.id }), 'Space deleted. Its tabs are in the Archive.');
          if (res) {
            setDeleting(null);
            await Promise.all([ctx.reloadSpaces(), ctx.reloadProfiles()]);
          }
        }}
        onClose={() => setDeleting(null)}
      >
        <p class="st-dialog-text">Its pinned and Today tabs move to the Archive.</p>
      </ConfirmDialog>
    </div>
  );
}
