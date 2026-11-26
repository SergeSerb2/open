import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type ExtensionItem, rpc } from '../shared/bridge';
import { Toggle } from '../shared/components';
import { ExtensionsIcon, ExternalIcon, TrashIcon } from '../shared/icons';
import { useSettings } from './context';
import { Banner, Btn, ConfirmDialog, EmptyRow, Group, PaneHeader, Pill } from './ui';

export function ExtensionsPane(): JSX.Element {
  const ctx = useSettings();
  const [items, setItems] = useState<ExtensionItem[] | null>(null);
  const [removing, setRemoving] = useState<ExtensionItem | null>(null);

  useEffect(() => {
    let live = true;
    setItems(null);
    void rpc('settings.getExtensions', { profile_id: ctx.profileId })
      .then((res) => live && setItems(res.extensions))
      .catch(() => live && setItems([]));
    return () => {
      live = false;
    };
  }, [ctx.profileId]);

  const toggle = async (ext: ExtensionItem, change: { enabled?: boolean; pinned?: boolean }) => {
    const res = await ctx.run(() =>
      rpc('settings.toggleExtension', { id: ext.id, enabled: change.enabled ?? ext.enabled, ...(change.pinned !== undefined ? { pinned: change.pinned } : {}), profile_id: ctx.profileId }),
    );
    if (res) setItems(res.extensions);
  };

  const blockers = (items ?? []).filter((e) => e.is_adblocker && e.enabled);
  const open = (url: string) => void ctx.run(() => rpc('settings.openChromeUrl', { url }));

  return (
    <div class="st-pane">
      <PaneHeader section="extensions" />

      {blockers.length > 0 && (
        <Banner tone="warning" title={`${blockers.map((b) => b.name).join(', ')} also blocks ads.`} action={<Btn small onClick={() => ctx.navigate('adblock')}>Ad Blocker</Btn>}>
          Two blockers can break pages. Turn one of them off.
        </Banner>
      )}

      <Group
        title="Installed"
        action={
          <>
            <Btn onClick={() => open('chrome://extensions')}>
              Manage in Chromium <ExternalIcon size={12} />
            </Btn>
            <Btn onClick={() => open('https://chromewebstore.google.com/')}>
              Browse Chrome Web Store <ExternalIcon size={12} />
            </Btn>
          </>
        }
      >
        <div id="row-extensions-manage" />
        {items === null && <EmptyRow>Loading extensions…</EmptyRow>}
        {items?.length === 0 && <EmptyRow>No extensions in this Profile. Add some from the Chrome Web Store.</EmptyRow>}
        {items?.map((ext) => (
          <div key={ext.id} class={`st-row st-ext-row${ext.enabled ? '' : ' is-off'}`}>
            <span class="st-avatar is-square" aria-hidden="true">
              <ExtensionsIcon size={15} />
            </span>
            <div class="st-row-meta">
              <div class="st-row-label">
                {ext.name} <span class="st-muted-tag">{ext.version}</span>
                {ext.is_adblocker && <Pill tone="warning">Blocks ads</Pill>}
              </div>
              {ext.description && <div class="st-row-help st-ellipsis">{ext.description}</div>}
            </div>
            <div class="st-row-control">
              <button
                type="button"
                class={`st-pin${ext.pinned ? ' is-on' : ''}`}
                aria-pressed={ext.pinned}
                title={ext.pinned ? 'Unpin from the toolbar' : 'Pin to the toolbar'}
                disabled={!ext.enabled}
                onClick={() => void toggle(ext, { pinned: !ext.pinned })}
              >
                {ext.pinned ? 'Pinned' : 'Pin'}
              </button>
              {ext.has_options && (
                <Btn small onClick={() => void ctx.run(() => rpc('settings.extensions.openOptions', { profile_id: ctx.profileId, id: ext.id }))}>
                  Options
                </Btn>
              )}
              <Btn kind="ghost" small title={`Remove ${ext.name}`} onClick={() => setRemoving(ext)}>
                <TrashIcon size={13} />
              </Btn>
              <Toggle checked={ext.enabled} label={`Turn ${ext.name} on`} onChange={(enabled) => void toggle(ext, { enabled })} />
            </div>
          </div>
        ))}
      </Group>

      <ConfirmDialog
        open={removing !== null}
        title={`Remove ${removing?.name ?? 'extension'}?`}
        confirmLabel="Remove"
        danger
        onConfirm={async () => {
          if (!removing) return;
          const res = await ctx.run(() => rpc('settings.extensions.remove', { profile_id: ctx.profileId, id: removing.id }), `Removed ${removing.name}.`);
          setRemoving(null);
          if (res) setItems(res.extensions);
        }}
        onClose={() => setRemoving(null)}
      >
        <p class="st-dialog-text">The extension and its data are removed from {ctx.profile?.name ?? 'this Profile'}.</p>
      </ConfirmDialog>
    </div>
  );
}
