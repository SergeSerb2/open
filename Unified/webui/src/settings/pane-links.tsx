import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import {
  type AtcState,
  type RoutingDecisionInfo,
  type RoutingDestination,
  type RoutingRule,
  type SourceApp,
  rpc,
} from '../shared/bridge';
import { Modal, Toggle } from '../shared/components';
import { ArrowDownIcon, ArrowUpIcon, DragHandleIcon, PencilIcon, PlusIcon, TrashIcon } from '../shared/icons';
import { formatShortcut, isMacPlatform, shortcutPlatform } from '../shared/shortcuts';
import { relativeTime, useSettings } from './context';
import { Banner, Btn, EmptyRow, Field, Group, KeyRecorder, PaneHeader, Pill, PrefToggle, Row, Select, TextInput } from './ui';

type MatchKind = 'host' | 'subdomains' | 'contains' | 'prefix';

const MATCH_OPTIONS: { value: MatchKind; label: string }[] = [
  { value: 'host', label: 'Host is' },
  { value: 'subdomains', label: 'Domain and subdomains' },
  { value: 'contains', label: 'Host contains' },
  { value: 'prefix', label: 'URL starts with' },
];

const OUTCOME_LABELS: Record<string, string> = {
  matched: 'Matched',
  disabled: 'Rule is off',
  source_unknown: 'Source app unknown',
  source_mismatch: 'Other source app',
  host_mismatch: 'Other site',
  path_mismatch: 'Other path',
  space_missing: 'Space deleted',
  profile_missing: 'Profile deleted',
};

interface RuleDraft {
  id: string;
  name: string;
  match: MatchKind;
  value: string;
  source: string;
  destination: string; // "little_open" | "most_recent_space" | "space:<id>"
  enabled: boolean;
}

function matchOf(rule: RoutingRule): { match: MatchKind; value: string } {
  if (rule.path_prefix) return { match: 'prefix', value: `${rule.host_pattern}${rule.path_prefix}` };
  const p = rule.host_pattern;
  if (p.startsWith('*.')) return { match: 'subdomains', value: p.slice(2) };
  if (p.length > 2 && p.startsWith('*') && p.endsWith('*')) return { match: 'contains', value: p.slice(1, -1) };
  return { match: 'host', value: p };
}

function destinationKey(d: RoutingDestination): string {
  return d.kind === 'space' && d.space_id ? `space:${d.space_id}` : d.kind;
}

function ruleFromDraft(draft: RuleDraft, profileOfSpace: (id: string) => string | undefined): RoutingRule {
  let host = draft.value.trim().toLowerCase().replace(/^https?:\/\//, '');
  let path: string | undefined;
  if (draft.match === 'prefix') {
    const slash = host.indexOf('/');
    if (slash >= 0) {
      path = host.slice(slash);
      host = host.slice(0, slash);
    }
  } else {
    host = host.split('/')[0] ?? host;
  }
  const pattern = draft.match === 'subdomains' ? `*.${host}` : draft.match === 'contains' ? `*${host}*` : host;
  let destination: RoutingDestination;
  if (draft.destination.startsWith('space:')) {
    const spaceId = draft.destination.slice(6);
    const profileId = profileOfSpace(spaceId);
    destination = profileId ? { kind: 'space', space_id: spaceId, profile_id: profileId } : { kind: 'space', space_id: spaceId };
  } else {
    destination = { kind: draft.destination as RoutingDestination['kind'] };
  }
  const rule: RoutingRule = { id: draft.id, name: draft.name.trim(), host_pattern: pattern, destination, enabled: draft.enabled };
  if (path) rule.path_prefix = path;
  if (draft.source) rule.source_app_id = draft.source;
  return rule;
}

export function LinksPane(): JSX.Element {
  const ctx = useSettings();
  const [atc, setAtc] = useState<AtcState | null>(null);
  const [apps, setApps] = useState<SourceApp[]>([]);
  const [draft, setDraft] = useState<RuleDraft | null>(null);
  const [draftError, setDraftError] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [testUrl, setTestUrl] = useState('https://github.com/');
  const [testSource, setTestSource] = useState('');
  const [testResult, setTestResult] = useState<RoutingDecisionInfo | null>(null);
  const [testError, setTestError] = useState<string | null>(null);
  const [recent, setRecent] = useState<RoutingDecisionInfo[]>([]);
  const [dragId, setDragId] = useState<string | null>(null);

  const reload = async () => {
    const [state, log] = await Promise.all([ctx.run(() => rpc('settings.atc.get', {})), ctx.run(() => rpc('settings.atc.recentDecisions', {}))]);
    if (state) setAtc(state);
    if (log) setRecent(log.decisions);
  };

  useEffect(() => {
    void reload();
    void rpc('settings.atc.listRunningApps', {})
      .then((res) => setApps(res.apps))
      .catch(() => setApps([]));
  }, []);

  const hotkey = String(ctx.prefs['links.littleOpenHotkey'] ?? '');
  const hotkeyOn = !!hotkey && !['off', 'none', 'disabled'].includes(hotkey.toLowerCase());
  const defaultHotkey = String(ctx.defaults['links.littleOpenHotkey'] ?? 'Mod+Alt+N');
  const appName = (id?: string) => (id ? apps.find((a) => a.id === id)?.name ?? id : '');
  const profileOfSpace = (id: string) => ctx.spaces.find((s) => s.id === id)?.profile_id;

  const destinationOptions = [
    { value: 'little_open', label: 'Little Open' },
    { value: 'most_recent_space', label: 'Most recent Space' },
    ...ctx.spaces.map((s) => ({
      value: `space:${s.id}`,
      label: `${s.display_title}${ctx.profiles.length > 1 ? ` (${ctx.profiles.find((p) => p.id === s.profile_id)?.name ?? ''})` : ''}`,
    })),
  ];

  const sourceOptions = [{ value: '', label: 'Any app' }, ...apps.map((a) => ({ value: a.id, label: a.name }))];

  const setDefault = async (key: string) => {
    const destination: RoutingDestination = key.startsWith('space:')
      ? { kind: 'space', space_id: key.slice(6) }
      : { kind: key as RoutingDestination['kind'] };
    const res = await ctx.run(() => rpc('settings.atc.setDefaultDestination', { destination }), 'Default destination saved.');
    if (res) setAtc(res);
  };

  const saveDraft = async () => {
    if (!draft) return;
    if (!draft.value.trim()) {
      setDraftError('Enter a site such as github.com.');
      return;
    }
    const rule = ruleFromDraft(draft, profileOfSpace);
    try {
      const res = draft.id ? await rpc('settings.atc.updateRule', { rule }) : await rpc('settings.atc.addRule', { rule });
      setAtc(res);
      setDraft(null);
      ctx.toast('Rule saved.', 'success');
    } catch (error) {
      setDraftError(error instanceof Error ? error.message : String(error));
    }
  };

  const reorder = async (ids: string[]) => {
    const res = await ctx.run(() => rpc('settings.atc.reorderRules', { ids }));
    if (res) setAtc(res);
  };

  const move = (index: number, delta: number) => {
    if (!atc) return;
    const ids = atc.rules.map((r) => r.id);
    const target = index + delta;
    if (target < 0 || target >= ids.length) return;
    const [id] = ids.splice(index, 1);
    if (id) ids.splice(target, 0, id);
    void reorder(ids);
  };

  const runTest = async () => {
    setTestError(null);
    try {
      const payload = testSource ? { url: testUrl, source_app_id: testSource } : { url: testUrl };
      setTestResult(await rpc('settings.atc.testUrl', payload));
    } catch (error) {
      setTestResult(null);
      setTestError(error instanceof Error ? error.message : String(error));
    }
  };

  const clickLabel = isMacPlatform() ? 'Option-Command-click' : 'Ctrl+Alt-click';
  const formattedHotkey = formatShortcut(hotkey.replace(/Option/g, 'Alt'));
  const sourceAppsSupported = atc?.source_apps_supported ?? (isMacPlatform() || shortcutPlatform() === 'windows');
  const hotkeyHelp = !hotkeyOn
    ? 'The global shortcut is off.'
    : shortcutPlatform() === 'linux'
      ? 'On Linux, Little Open uses the in-app shortcut (rebindable in Settings → Shortcuts → New Little Open Window) or your desktop shortcut manager.'
      : `Press ${formattedHotkey} from any app.`;

  return (
    <div class="st-pane">
      <PaneHeader section="links" />

      <Group title="Little Open">
        <Row
          id="links/little-open-hotkey"
          label="Open Little Open in any app"
          help={hotkeyHelp}
          prefKey="links.littleOpenHotkey"
        >
          {recording ? (
            <KeyRecorder
              value={hotkey}
              onCancel={() => setRecording(false)}
              onRecord={(keys) => {
                setRecording(false);
                if (keys) void ctx.setPref('links.littleOpenHotkey', keys);
              }}
            />
          ) : (
            hotkeyOn && (
              <Btn small onClick={() => setRecording(true)}>
                Change…
              </Btn>
            )
          )}
          <Toggle
            checked={hotkeyOn}
            label="Open Little Open in any app"
            onChange={(on) => void ctx.setPref('links.littleOpenHotkey', on ? defaultHotkey : 'off')}
          />
        </Row>
        <PrefToggle id="links/option-command-click" label={`Open Little Open with ${clickLabel}`} prefKey="links.optionCommandClick" />
        <PrefToggle
          id="links/external-links"
          label="Links from other apps open in Little Open"
          help="When off, they open in your most recent Space."
          prefKey="links.externalLinksLittleOpen"
          onChanged={() => void reload()}
        />
      </Group>

      <Group title="Peek">
        <PrefToggle id="links/peek-shift-click" label="Open Peek with Shift-click" prefKey="links.peekShiftClick" />
        <PrefToggle id="links/peek-other-sites" label="Open Peek for links to other sites" help="Applies to Favorites and Pinned tabs." prefKey="links.peekOtherSites" />
      </Group>

      <Group
        title="Air Traffic Control"
        action={
          <Btn
            onClick={() => {
              setDraftError(null);
              setDraft({ id: '', name: '', match: 'subdomains', value: '', source: '', destination: ctx.spaces[0] ? `space:${ctx.spaces[0].id}` : 'little_open', enabled: true });
            }}
          >
            <PlusIcon size={12} /> Add Rule…
          </Btn>
        }
      >
        <Row
          id="links/destination"
          label="Default destination"
          help="Where links open when no rule matches."
          changed={atc ? atc.default_destination.kind !== 'little_open' : false}
          onReset={() => void setDefault('little_open')}
        >
          <Select ariaLabel="Default destination" wide value={atc ? destinationKey(atc.default_destination) : 'little_open'} options={destinationOptions} onChange={(v) => void setDefault(v)} />
        </Row>
        <div id="row-links-rules" />
        {atc && atc.rules.length === 0 && (
          <Row id="links/no-rules" label="No routing rules yet" help="Send a site to a Space, a Profile, or Little Open." />
        )}
        {atc?.rules.map((rule, index) => {
          const { match, value } = matchOf(rule);
          return (
            <div
              key={rule.id}
              class={`st-row st-rule-row${dragId === rule.id ? ' is-dragging' : ''}${rule.enabled ? '' : ' is-off'}`}
              draggable
              onDragStart={(e) => {
                setDragId(rule.id);
                e.dataTransfer?.setData('text/plain', rule.id);
              }}
              onDragEnd={() => setDragId(null)}
              onDragOver={(e) => e.preventDefault()}
              onDrop={(e) => {
                e.preventDefault();
                if (!dragId || dragId === rule.id || !atc) return;
                const ids = atc.rules.map((r) => r.id).filter((id) => id !== dragId);
                ids.splice(index, 0, dragId);
                setDragId(null);
                void reorder(ids);
              }}
            >
              <span class="st-drag" aria-hidden="true">
                <DragHandleIcon size={14} />
              </span>
              <div class="st-row-meta">
                <div class="st-row-label">{rule.name || rule.host_pattern}</div>
                <div class="st-row-help">
                  {MATCH_OPTIONS.find((m) => m.value === match)?.label} <code class="st-code">{value}</code>
                  {rule.source_app_id && <> · from {appName(rule.source_app_id)}</>} → {destinationOptions.find((d) => d.value === destinationKey(rule.destination))?.label ?? 'A deleted Space'}
                </div>
              </div>
              <div class="st-row-control">
                <Btn kind="ghost" small title="Move up" disabled={index === 0} onClick={() => move(index, -1)}>
                  <ArrowUpIcon size={13} />
                </Btn>
                <Btn kind="ghost" small title="Move down" disabled={index === atc.rules.length - 1} onClick={() => move(index, 1)}>
                  <ArrowDownIcon size={13} />
                </Btn>
                <Btn
                  kind="ghost"
                  small
                  title="Edit rule"
                  onClick={() => {
                    setDraftError(null);
                    setDraft({ id: rule.id, name: rule.name, match, value, source: rule.source_app_id ?? '', destination: destinationKey(rule.destination), enabled: rule.enabled });
                  }}
                >
                  <PencilIcon size={13} />
                </Btn>
                <Btn
                  kind="ghost"
                  small
                  title="Delete rule"
                  onClick={async () => {
                    const res = await ctx.run(() => rpc('settings.atc.deleteRule', { id: rule.id }), 'Rule deleted.');
                    if (res) setAtc(res);
                  }}
                >
                  <TrashIcon size={13} />
                </Btn>
                <Toggle
                  checked={rule.enabled}
                  label={`Use rule ${rule.name}`}
                  onChange={async (enabled) => {
                    const res = await ctx.run(() => rpc('settings.atc.updateRule', { rule: { ...rule, enabled } }));
                    if (res) setAtc(res);
                  }}
                />
              </div>
            </div>
          );
        })}
      </Group>

      <Group title="Test a Link">
        <div id="row-links-test" class="st-test-box">
          <div class="st-test-inputs">
            <TextInput value={testUrl} onInput={setTestUrl} ariaLabel="Link to test" placeholder="https://example.com/page" onEnter={runTest} mono />
            <Select ariaLabel="Source app" value={testSource} options={sourceOptions} onChange={setTestSource} />
            <Btn kind="primary" onClick={runTest}>
              Test
            </Btn>
          </div>
          {atc && !atc.source_apps_supported && <div class="st-row-help">This system does not report which app opened a link, so rules with a source app never match.</div>}
          {testError && <Banner tone="warning">{testError}</Banner>}
          {testResult && (
            <div class="st-test-result">
              <div class="st-test-headline">
                Opens in <strong>{testResult.destination_label}</strong>
                {testResult.matched_rule_name && <Pill tone="accent">{testResult.matched_rule_name}</Pill>}
              </div>
              <div class="st-row-help">{testResult.explanation}</div>
              {testResult.traces.length > 0 && (
                <ol class="st-trace">
                  {testResult.traces.map((t) => (
                    <li key={`${t.rule_id}-${t.index}`} class={t.outcome === 'matched' ? 'is-match' : ''}>
                      <span>{t.rule_name || 'Rule'}</span>
                      <Pill tone={t.outcome === 'matched' ? 'success' : 'default'}>{OUTCOME_LABELS[t.outcome] ?? t.outcome}</Pill>
                    </li>
                  ))}
                </ol>
              )}
            </div>
          )}
        </div>
      </Group>

      <Group title="Recent routing decisions" action={<Btn small onClick={() => void reload()}>Refresh</Btn>}>
        <div id="row-links-recent" />
        {recent.length === 0 ? (
          <EmptyRow>Links from other apps show up here.</EmptyRow>
        ) : (
          recent.slice(0, 12).map((d, i) => (
            <div key={`${d.at}-${i}`} class="st-row st-decision-row">
              <div class="st-row-meta">
                <div class="st-row-label st-ellipsis">{d.host ?? d.url}</div>
                <div class="st-row-help">
                  {relativeTime(d.at)}
                  {d.source_app_id && <> · from {appName(d.source_app_id)}</>}
                  {d.matched_rule_name ? <> · rule “{d.matched_rule_name}”</> : <> · default</>}
                </div>
              </div>
              <div class="st-row-control">
                <Pill tone={d.via === 'rule' ? 'accent' : 'default'}>{d.destination_label}</Pill>
              </div>
            </div>
          ))
        )}
      </Group>

      <Modal
        open={draft !== null}
        title={draft?.id ? 'Edit Rule' : 'New Rule'}
        onClose={() => setDraft(null)}
        footer={
          <>
            <Btn onClick={() => setDraft(null)}>Cancel</Btn>
            <Btn kind="primary" onClick={saveDraft}>
              Save Rule
            </Btn>
          </>
        }
      >
        {draft && (
          <>
            <Field label="Name (optional)">
              <TextInput value={draft.name} onInput={(v) => setDraft({ ...draft, name: v })} ariaLabel="Rule name" placeholder="GitHub to Work" autoFocus />
            </Field>
            <div class="st-field-row">
              <Field label="When the link">
                <Select ariaLabel="Match kind" wide value={draft.match} options={MATCH_OPTIONS} onChange={(v) => setDraft({ ...draft, match: v })} />
              </Field>
              <Field label={draft.match === 'prefix' ? 'URL' : 'Site'}>
                <TextInput
                  value={draft.value}
                  onInput={(v) => {
                    setDraft({ ...draft, value: v });
                    setDraftError(null);
                  }}
                  ariaLabel="Site"
                  placeholder={draft.match === 'prefix' ? 'github.com/my-org' : 'github.com'}
                  invalid={!!draftError}
                  mono
                />
              </Field>
            </div>
            {sourceAppsSupported && (
              <Field label="And comes from" hint={apps.length === 0 ? 'No running apps were detected right now.' : undefined}>
                <Select ariaLabel="Source app" wide value={draft.source} options={sourceOptions} onChange={(v) => setDraft({ ...draft, source: v })} />
              </Field>
            )}
            <Field label="Open it in">
              <Select ariaLabel="Destination" wide value={draft.destination} options={destinationOptions.filter((o) => o.value !== 'most_recent_space')} onChange={(v) => setDraft({ ...draft, destination: v })} />
            </Field>
            {draftError && <Banner tone="warning">{draftError}</Banner>}
          </>
        )}
      </Modal>
    </div>
  );
}
