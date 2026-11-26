import type { JSX } from 'preact';
import { useState } from 'preact/hooks';
import { formatShortcut } from '../shared/shortcuts';
import { useSettings } from './context';
import { Banner, Btn, Group, PaneHeader, PrefSelect, PrefToggle } from './ui';

const ARCHIVE_OPTIONS = [
  { value: '12h', label: '12 hours' },
  { value: '24h', label: '24 hours' },
  { value: '7d', label: '7 days' },
  { value: '30d', label: '30 days' },
  { value: 'never', label: 'Never' },
] as const;

const LITTLE_OPEN_ARCHIVE = [
  { value: '1h', label: '1 hour' },
  { value: '6h', label: '6 hours' },
  { value: '12h', label: '12 hours' },
  { value: '24h', label: '24 hours' },
  { value: 'never', label: 'Never' },
] as const;

const SLEEP_OPTIONS = [
  { value: 'off', label: 'Never' },
  { value: 'conservative', label: 'Rarely (saves less memory)' },
  { value: 'balanced', label: 'Balanced' },
  { value: 'aggressive', label: 'Often (saves the most memory)' },
] as const;

export function TabsPane(): JSX.Element {
  const ctx = useSettings();
  const [applyPrompt, setApplyPrompt] = useState<string | null>(null);
  const archive = String(ctx.prefs['tabs.archiveAfter'] ?? '12h');

  return (
    <div class="st-pane">
      <PaneHeader section="tabs" />

      <Group title="Archive">
        <div
          onChange={() => {
            if (ctx.profiles.length > 1) setApplyPrompt('tabs.archiveAfter');
          }}
        >
          <PrefSelect
            id="tabs/archive-after"
            label="Archive tabs after"
            help="Today tabs you have not used move to the Archive."
            prefKey="tabs.archiveAfter"
            options={ARCHIVE_OPTIONS}
          />
        </div>
        <PrefSelect id="tabs/little-open-archive" label="Archive Little Open windows after" prefKey="tabs.littleOpenArchiveAfter" options={LITTLE_OPEN_ARCHIVE} />
      </Group>
      {applyPrompt && (
        <Banner
          tone="info"
          title={`This applies to ${ctx.profile?.name ?? 'this Profile'}.`}
          action={
            <>
              <Btn small onClick={() => setApplyPrompt(null)}>
                Keep
              </Btn>
              <Btn
                small
                kind="primary"
                onClick={async () => {
                  await ctx.setPref('tabs.archiveAfter', archive, { applyAll: true });
                  setApplyPrompt(null);
                  ctx.toast('Applied to all Profiles.', 'success');
                }}
              >
                Apply to All Profiles
              </Btn>
            </>
          }
        />
      )}

      <Group title="Memory">
        <PrefSelect
          id="tabs/sleep"
          label="Sleep inactive tabs"
          help="Sleeping tabs stay in the sidebar and wake when you open them. They are not archived."
          prefKey="tabs.sleepMode"
          options={SLEEP_OPTIONS}
          wide
        />
      </Group>

      <Group title="Switching tabs">
        <PrefToggle
          id="tabs/include-favorites"
          label="Include Favorites in tab numbering"
          help={`${formatShortcut('Mod+1')} to ${formatShortcut('Mod+8')} count your Favorites first.`}
          prefKey="tabs.includeFavoritesInSwitcher"
        />
        <PrefToggle id="tabs/ninth-tab" label={`${formatShortcut('Mod+9')} goes to the last tab`} prefKey="tabs.ninthTabGoesToLast" />
      </Group>

      <Group title="Peek">
        <PrefToggle id="tabs/peek-shift" label="Open Peek with Shift-click" prefKey="links.peekShiftClick" />
        <PrefToggle id="tabs/peek-pinned" label="Peek links to other sites from Pinned tabs" help="Applies to Favorites and Pinned tabs." prefKey="links.peekOtherSites" />
      </Group>

      <Group title="Split View">
        <PrefSelect
          id="tabs/split"
          label="New splits open"
          prefKey="tabs.splitOrientation"
          options={[
            { value: 'horizontal', label: 'Side by side' },
            { value: 'vertical', label: 'Top and bottom' },
          ]}
        />
      </Group>
    </div>
  );
}
