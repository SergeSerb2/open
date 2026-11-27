import type { JSX } from 'preact';
import { useState } from 'preact/hooks';
import { type CustomSearchEngineDraft, type ProfileSummary, rpc } from '../shared/bridge';
import { BUILTIN_SEARCH_ENGINES } from '../shared/catalog';
import { Modal, ProfileGlyph, Toggle } from '../shared/components';
import { PencilIcon, PlusIcon, TrashIcon } from '../shared/icons';
import { plural, useSettings } from './context';
import { Banner, Btn, ConfirmDialog, EmptyRow, Field, Group, PaneHeader, PrefSelect, Row, Select, TextInput } from './ui';

const DOCUMENT_APPS = [
  { value: 'note', label: 'Open Note' },
  { value: 'google-doc', label: 'Google Doc' },
  { value: 'notion', label: 'Notion page' },
  { value: 'word', label: 'Word document' },
  { value: 'confluence', label: 'Confluence page' },
] as const;

type ProfileDialog =
  | { kind: 'create' }
  | { kind: 'rename'; profile: ProfileSummary }
  | { kind: 'delete'; profile: ProfileSummary }
  | { kind: 'engine'; index: number | null };

export function ProfilesPane(): JSX.Element {
  const ctx = useSettings();
  const [dialog, setDialog] = useState<ProfileDialog | null>(null);
  const [name, setName] = useState('');
  const [emoji, setEmoji] = useState('');
  const [confirm, setConfirm] = useState('');
  const [moveTo, setMoveTo] = useState('');
  const [busy, setBusy] = useState(false);
  const [engineDraft, setEngineDraft] = useState<CustomSearchEngineDraft>({ name: '', keyword: '', url_template: '' });
  const [cleanup, setCleanup] = useState<{ profiles: { id: string; name: string }[]; orphan_directories: string[] } | null>(null);

  const profile = ctx.profile;
  const engines = profile?.settings.custom_search_engines ?? [];
  const engineOptions = [
    ...BUILTIN_SEARCH_ENGINES.map((e) => ({ value: e.id, label: e.name })),
    ...engines.map((e) => ({ value: e.id, label: `${e.name} (${e.keyword})` })),
  ];

  const close = () => {
    setDialog(null);
    setBusy(false);
  };

  const iconFor = (value: string) => (value.trim() ? { kind: 'emoji' as const, value: Array.from(value.trim())[0] ?? '' } : undefined);

  const submitProfile = async () => {
    if (!dialog) return;
    setBusy(true);
    if (dialog.kind === 'create') {
      const icon = iconFor(emoji);
      const res = await ctx.run(() => rpc('settings.profiles.create', icon ? { name, icon } : { name }), `Created ${name.trim()}.`);
      if (res) {
        await ctx.reloadProfiles();
        ctx.setProfileId(res.profile.id);
        close();
      }
    } else if (dialog.kind === 'rename') {
      const icon = iconFor(emoji);
      const res = await ctx.run(
        () => rpc('settings.profiles.rename', icon ? { profile_id: dialog.profile.id, name, icon } : { profile_id: dialog.profile.id, name }),
        'Profile updated.',
      );
      if (res) {
        await ctx.reloadProfiles();
        close();
      }
    } else if (dialog.kind === 'delete') {
      const payload = moveTo
        ? { profile_id: dialog.profile.id, confirm_name: confirm, move_spaces_to: moveTo }
        : { profile_id: dialog.profile.id, confirm_name: confirm };
      const res = await ctx.run(() => rpc('settings.profiles.delete', payload), `Deleted ${dialog.profile.name} and its data.`);
      if (res?.ok) {
        if (ctx.profileId === dialog.profile.id) ctx.setProfileId(ctx.profiles[0]?.id ?? '');
        await Promise.all([ctx.reloadProfiles(), ctx.reloadSpaces()]);
        close();
      }
    }
    setBusy(false);
  };

  const saveEngines = async (next: CustomSearchEngineDraft[], message: string) => {
    if (!profile) return false;
    const res = await ctx.run(() => rpc('settings.profiles.setCustomSearchEngines', { profile_id: profile.id, engines: next }), message);
    if (res) {
      ctx.applyPreferences({ ...ctx.prefs, 'search.engine': res.profile.settings.search_engine_id });
      await ctx.reloadProfiles();
    }
    return res !== null;
  };

  const openCleanup = async () => {
    const res = await ctx.run(() => rpc('settings.profiles.cleanupUnused', { dry_run: true }));
    if (!res) return;
    if (!res.profiles.length && !res.orphan_directories.length) {
      ctx.toast('Every Profile is in use.');
      return;
    }
    setCleanup(res);
  };

  const deleteTarget = dialog?.kind === 'delete' ? dialog.profile : null;
  const spacesOfTarget = deleteTarget ? ctx.spaces.filter((s) => s.profile_id === deleteTarget.id).length : 0;

  return (
    <div class="st-pane">
      <PaneHeader section="profiles" />

      <Group
        title="Your Profiles"
        action={
          <Btn
            onClick={() => {
              setName('');
              setEmoji('');
              setDialog({ kind: 'create' });
            }}
          >
            New Profile…
          </Btn>
        }
      >
        {ctx.profiles.map((p) => (
          <div key={p.id} id={`row-profiles-${p.id}`} class="st-row st-profile-row">
            <span class="st-avatar" aria-hidden="true">
              <ProfileGlyph profile={p} size={16} />
            </span>
            <div class="st-row-meta">
              <div class="st-row-label">
                {p.name}
                {p.is_default && <span class="st-muted-tag">Default</span>}
              </div>
              <div class="st-row-help">
                {plural(p.space_count, 'Space')} · {plural(p.favorites_count, 'Favorite')}
              </div>
            </div>
            <div class="st-row-control">
              <Btn
                kind="ghost"
                small
                title={`Rename ${p.name}`}
                onClick={() => {
                  setName(p.name);
                  setEmoji(p.icon.kind === 'emoji' ? p.icon.value : '');
                  setDialog({ kind: 'rename', profile: p });
                }}
              >
                <PencilIcon size={13} />
              </Btn>
              {!p.is_default && (
                <Btn
                  kind="ghost"
                  small
                  title={`Delete ${p.name}`}
                  onClick={() => {
                    setConfirm('');
                    setMoveTo('');
                    setDialog({ kind: 'delete', profile: p });
                  }}
                >
                  <TrashIcon size={13} />
                </Btn>
              )}
            </div>
          </div>
        ))}
      </Group>
      <div class="st-below-card">
        <span />
        <Btn onClick={openCleanup}>Delete unused Profiles…</Btn>
      </div>

      {profile && (
        <>
          <Group title={`Search · ${profile.name}`}>
            <Row
              id="profiles/search-engine"
              label="Search engine"
              help="Used by the Command Bar and the address field."
              changed={profile.settings.search_engine_id !== 'google'}
              onReset={async () => {
                const res = await ctx.run(() => rpc('settings.profiles.setSearchEngine', { profile_id: profile.id, engine_id: 'google' }));
                if (res) {
                  ctx.applyPreferences({ ...ctx.prefs, 'search.engine': 'google' });
                  await ctx.reloadProfiles();
                }
              }}
            >
              <Select
                ariaLabel="Search engine"
                value={profile.settings.search_engine_id}
                options={engineOptions}
                onChange={async (id) => {
                  const res = await ctx.run(() => rpc('settings.profiles.setSearchEngine', { profile_id: profile.id, engine_id: id }));
                  if (res) {
                    ctx.applyPreferences({ ...ctx.prefs, 'search.engine': id });
                    await ctx.reloadProfiles();
                  }
                }}
              />
            </Row>
            <Row id="profiles/search-suggestions" label="Include search engine suggestions" help="We talk to your search engine to help suggest results." prefKey="search.suggestions">
              <Toggle
                checked={ctx.prefs['search.suggestions'] === true}
                label="Include search engine suggestions"
                onChange={(v) => void ctx.setPref('search.suggestions', v)}
              />
            </Row>
            <PrefSelect id="profiles/new-documents" label="New documents" help="What New Note creates." prefKey="profiles.newDocuments" options={DOCUMENT_APPS} />
          </Group>

          <Group
            title="Custom search engines"
            action={
              <Btn
                onClick={() => {
                  setEngineDraft({ name: '', keyword: '', url_template: 'https://' });
                  setDialog({ kind: 'engine', index: null });
                }}
              >
                <PlusIcon size={12} /> Add Engine…
              </Btn>
            }
          >
            <div id="row-profiles-custom-engines" />
            {engines.length === 0 ? (
              <EmptyRow>Type a keyword and a space in the Command Bar to search a site. Add one with Add Engine.</EmptyRow>
            ) : (
              engines.map((engine, index) => (
                <div key={engine.id} class="st-row">
                  <div class="st-row-meta">
                    <div class="st-row-label">
                      {engine.name} <code class="st-code">{engine.keyword}</code>
                    </div>
                    <div class="st-row-help st-ellipsis">{engine.url_template}</div>
                  </div>
                  <div class="st-row-control">
                    <Btn
                      kind="ghost"
                      small
                      title={`Edit ${engine.name}`}
                      onClick={() => {
                        setEngineDraft({ ...engine });
                        setDialog({ kind: 'engine', index });
                      }}
                    >
                      <PencilIcon size={13} />
                    </Btn>
                    <Btn
                      kind="ghost"
                      small
                      title={`Remove ${engine.name}`}
                      onClick={() => void saveEngines(engines.filter((_, i) => i !== index), `Removed ${engine.name}.`)}
                    >
                      <TrashIcon size={13} />
                    </Btn>
                  </div>
                </div>
              ))
            )}
          </Group>
        </>
      )}

      <Modal
        open={dialog?.kind === 'create' || dialog?.kind === 'rename'}
        title={dialog?.kind === 'rename' ? 'Edit Profile' : 'New Profile'}
        onClose={close}
        footer={
          <>
            <Btn onClick={close}>Cancel</Btn>
            <Btn kind="primary" busy={busy} disabled={!name.trim()} onClick={submitProfile}>
              {dialog?.kind === 'rename' ? 'Save' : 'Create Profile'}
            </Btn>
          </>
        }
      >
        <p class="st-dialog-text">A Profile keeps its own cookies, history, passwords, and extensions.</p>
        <Field label="Name">
          <TextInput value={name} onInput={setName} ariaLabel="Profile name" placeholder="Work" autoFocus onEnter={submitProfile} />
        </Field>
        <Field label="Icon (one emoji, optional)">
          <TextInput value={emoji} onInput={setEmoji} ariaLabel="Profile emoji" placeholder="💼" />
        </Field>
      </Modal>

      <ConfirmDialog
        open={dialog?.kind === 'delete'}
        title={`Delete ${deleteTarget?.name ?? 'Profile'}?`}
        confirmLabel="Delete Profile and Data"
        danger
        busy={busy}
        confirmDisabled={!deleteTarget || confirm !== deleteTarget.name || (spacesOfTarget > 0 && !moveTo)}
        onConfirm={submitProfile}
        onClose={close}
      >
        <Banner tone="danger" title="This removes the Profile's data from this computer.">
          Cookies, history, saved passwords, extensions, Boosts, Easels, and Notes of this Profile are deleted from disk. This cannot be undone.
        </Banner>
        {spacesOfTarget > 0 && (
          <Field label={`Move its ${plural(spacesOfTarget, 'Space')} to`}>
            <Select
              ariaLabel="Move Spaces to"
              wide
              value={moveTo}
              options={[{ value: '', label: 'Choose a Profile…' }, ...ctx.profiles.filter((p) => p.id !== deleteTarget?.id).map((p) => ({ value: p.id, label: p.name }))]}
              onChange={setMoveTo}
            />
          </Field>
        )}
        <Field label={`Type "${deleteTarget?.name ?? ''}" to confirm`}>
          <TextInput value={confirm} onInput={setConfirm} ariaLabel="Confirm Profile name" />
        </Field>
      </ConfirmDialog>

      <Modal
        open={dialog?.kind === 'engine'}
        title={dialog?.kind === 'engine' && dialog.index !== null ? 'Edit Search Engine' : 'Add Search Engine'}
        onClose={close}
        footer={
          <>
            <Btn onClick={close}>Cancel</Btn>
            <Btn
              kind="primary"
              busy={busy}
              onClick={async () => {
                if (dialog?.kind !== 'engine') return;
                setBusy(true);
                const next = dialog.index === null ? [...engines, engineDraft] : engines.map((e, i) => (i === dialog.index ? engineDraft : e));
                const ok = await saveEngines(next, `Saved ${engineDraft.name.trim() || 'the engine'}.`);
                setBusy(false);
                if (ok) close();
              }}
            >
              Save
            </Btn>
          </>
        }
      >
        <Field label="Name">
          <TextInput value={engineDraft.name} onInput={(v) => setEngineDraft({ ...engineDraft, name: v })} ariaLabel="Engine name" placeholder="GitHub" autoFocus />
        </Field>
        <Field label="Keyword" hint="One word. Type it and a space in the Command Bar.">
          <TextInput value={engineDraft.keyword} onInput={(v) => setEngineDraft({ ...engineDraft, keyword: v })} ariaLabel="Engine keyword" placeholder="gh" mono />
        </Field>
        <Field label="URL" hint="Put %s where the search words go.">
          <TextInput value={engineDraft.url_template} onInput={(v) => setEngineDraft({ ...engineDraft, url_template: v })} ariaLabel="Engine URL" placeholder="https://github.com/search?q=%s" mono />
        </Field>
      </Modal>

      <ConfirmDialog
        open={cleanup !== null}
        title="Delete unused Profiles?"
        confirmLabel="Delete"
        danger
        busy={busy}
        onConfirm={async () => {
          setBusy(true);
          const res = await ctx.run(() => rpc('settings.profiles.cleanupUnused', { dry_run: false }), 'Unused Profiles were deleted.');
          setBusy(false);
          if (res) {
            setCleanup(null);
            await ctx.reloadProfiles();
          }
        }}
        onClose={() => setCleanup(null)}
      >
        <p class="st-dialog-text">These Profiles have no Spaces. Their data is deleted from this computer.</p>
        <ul class="st-list">
          {cleanup?.profiles.map((p) => <li key={p.id}>{p.name}</li>)}
          {cleanup?.orphan_directories.map((d) => (
            <li key={d}>
              Leftover folder <code class="st-code">{d}</code>
            </li>
          ))}
        </ul>
      </ConfirmDialog>
    </div>
  );
}
