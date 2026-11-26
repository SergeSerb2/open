import type { JSX } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { type AdBlockConflict, type AdBlockState, RPC_EVENTS, normalizeAdBlockState, rpc, subscribeEvent } from '../shared/bridge';
import type { AdBlockListCategory } from '../shared/catalog';
import { Toggle } from '../shared/components';
import { ChevronRightIcon, CloseIcon, CopyIcon, ExternalIcon, RefreshIcon, SearchIcon } from '../shared/icons';
import { formatCount, relativeTime, useSettings } from './context';
import { Banner, Btn, ConfirmDialog, EmptyRow, Group, PaneHeader, Pill, Row, TextInput } from './ui';

const CATEGORIES: { id: AdBlockListCategory; label: string }[] = [
  { id: 'generic', label: 'Generic' },
  { id: 'cookies', label: 'Cookies' },
  { id: 'privacy', label: 'Privacy' },
  { id: 'regional', label: 'Regional' },
  { id: 'bcny', label: 'More' },
];

export function AdBlockPane(): JSX.Element {
  const ctx = useSettings();
  const [state, setState] = useState<AdBlockState | null>(null);
  const [conflicts, setConflicts] = useState<AdBlockConflict[]>([]);
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [site, setSite] = useState('');
  const [siteError, setSiteError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [rules, setRules] = useState('');
  const [rulesDirty, setRulesDirty] = useState(false);
  const [confirmReset, setConfirmReset] = useState(false);

  useEffect(() => {
    let live = true;
    void rpc('settings.adblock.get', { profile_id: ctx.profileId }).then((s) => {
      if (!live) return;
      setState(s);
      setRules(s.custom_rules ?? '');
      setRulesDirty(false);
    });
    void rpc('settings.adblock.detectConflictingExtensions', { profile_id: ctx.profileId })
      .then((r) => live && setConflicts(r.conflicts.filter((c) => c.enabled)))
      .catch(() => live && setConflicts([]));
    const off = subscribeEvent(RPC_EVENTS.adBlockUpdated, (payload) => {
      const next = normalizeAdBlockState(payload);
      if (live && (!next.profile_id || next.profile_id === ctx.profileId)) setState((prev) => ({ ...next, custom_rules: next.custom_rules ?? prev?.custom_rules ?? '' }));
    });
    return () => {
      live = false;
      off();
    };
  }, [ctx.profileId]);

  const lists = state?.lists ?? [];
  const words = query.trim().toLowerCase();
  const filtered = useMemo(
    () => lists.filter((l) => !words || l.display_name.toLowerCase().includes(words) || l.id.toLowerCase().includes(words)),
    [lists, words],
  );
  const enabledCount = lists.filter((l) => l.enabled).length;

  const addSite = async () => {
    setSiteError(null);
    try {
      const next = await rpc('settings.addAdBlockExclusion', { profile_id: ctx.profileId, host: site });
      setState(next);
      setSite('');
    } catch (error) {
      setSiteError(error instanceof Error ? error.message : String(error));
    }
  };

  const refresh = async (kind: 'update' | 'reset') => {
    setBusy(kind);
    const res = await ctx.run(() =>
      kind === 'update' ? rpc('settings.adblock.updateNow', { profile_id: ctx.profileId }) : rpc('settings.adblock.resetLists', { profile_id: ctx.profileId }),
    );
    setBusy(null);
    if (!res) return;
    setState(res);
    if (res.update_ok === false) ctx.toast('Some lists could not be updated. See the list errors below.', 'danger');
    else ctx.toast(kind === 'update' ? 'Block lists are up to date.' : 'Block lists are back to the defaults.', 'success');
  };

  return (
    <div class="st-pane">
      <PaneHeader section="adblock" />

      {conflicts.length > 0 && (
        <Banner tone="warning" title={`${conflicts.map((c) => c.name).join(', ')} also blocks ads in this Profile.`} action={<Btn small onClick={() => ctx.navigate('extensions')}>Extensions</Btn>}>
          Two blockers can break pages and slow Open down. Keep one of them.
        </Banner>
      )}

      <Group title="Protection">
        <Row id="adblock/enabled" label="Block ads, trackers, and popups" help="The main switch applies to all Profiles." changed={state ? !state.global_enabled : false}>
          <Toggle
            checked={state?.global_enabled === true}
            label="Block ads, trackers, and popups"
            onChange={async (enabled) => {
              const res = await ctx.run(() => rpc('settings.setAdBlockEnabled', { enabled, profile_id: ctx.profileId }));
              if (res) setState(res);
            }}
          />
        </Row>
        <div class="st-stats">
          <div class="st-stat">
            <span class="st-stat-value">{formatCount(state?.blocked_count_session)}</span>
            <span class="st-stat-label">Blocked in open tabs</span>
          </div>
          <div class="st-stat">
            <span class="st-stat-value">{formatCount(state?.active_rules)}</span>
            <span class="st-stat-label">Active rules</span>
          </div>
          <div class="st-stat">
            <span class="st-stat-value">{enabledCount}</span>
            <span class="st-stat-label">Lists on</span>
          </div>
          <div class="st-stat">
            <span class="st-stat-value is-text">{relativeTime(state?.last_updated_at)}</span>
            <span class="st-stat-label">Last updated</span>
          </div>
        </div>
        <Row id="adblock/update" label="Update block lists" help={state?.last_error ? <span class="st-error-text">{state.last_error}</span> : 'Download the newest version of every list that is on.'}>
          <Btn busy={busy === 'reset'} onClick={() => setConfirmReset(true)}>
            Reset Lists…
          </Btn>
          <Btn kind="primary" busy={busy === 'update' || state?.is_updating === true} onClick={() => void refresh('update')}>
            {busy !== 'update' && <RefreshIcon size={12} />} Update Lists Now
          </Btn>
        </Row>
      </Group>

      <Group
        title="Block lists"
        action={
          <label class="st-mini-search">
            <SearchIcon size={13} />
            <input value={query} placeholder="Search block lists" aria-label="Search block lists" onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)} />
          </label>
        }
      >
        <div id="row-adblock-lists" />
        {CATEGORIES.map((cat) => {
          const inCat = filtered.filter((l) => l.category === cat.id);
          const all = lists.filter((l) => l.category === cat.id);
          if (!all.length || (words && !inCat.length)) return null;
          const expanded = open.has(cat.id) || !!words;
          return (
            <div key={cat.id} class="st-disclosure">
              <button
                type="button"
                class="st-disclosure-head"
                aria-expanded={expanded}
                onClick={() => {
                  const next = new Set(open);
                  if (next.has(cat.id)) next.delete(cat.id);
                  else next.add(cat.id);
                  setOpen(next);
                }}
              >
                <span class={`st-disclosure-chevron${expanded ? ' is-open' : ''}`}>
                  <ChevronRightIcon size={12} />
                </span>
                <span class="st-disclosure-title">{cat.label}</span>
                <span class="st-disclosure-count">
                  {all.filter((l) => l.enabled).length} of {all.length} on
                </span>
              </button>
              {expanded &&
                inCat.map((list) => (
                  <div key={list.id} class="st-list-item">
                    <div class="st-row-meta">
                      <div class="st-row-label">
                        {list.display_name}
                        {list.info_url && (
                          <a class="st-info-link" href={list.info_url} target="_blank" rel="noreferrer" title="About this list">
                            <ExternalIcon size={11} />
                          </a>
                        )}
                      </div>
                      <div class="st-receipt">
                        {list.unavailable_reason ? (
                          <Pill tone="warning">{list.unavailable_reason}</Pill>
                        ) : (
                          <>
                            {list.source && <Pill tone={list.source === 'downloaded' ? 'accent' : 'default'}>{list.source === 'downloaded' ? 'Updated' : 'Bundled'}</Pill>}
                            {list.rule_count !== undefined && <span>{formatCount(list.rule_count)} rules</span>}
                            {list.last_updated_at !== undefined && <span>{relativeTime(list.last_updated_at)}</span>}
                            {list.error && <Pill tone="danger">{list.error}</Pill>}
                          </>
                        )}
                      </div>
                    </div>
                    <Toggle
                      checked={list.enabled}
                      disabled={!!list.unavailable_reason}
                      label={list.display_name}
                      onChange={async (enabled) => {
                        const res = await ctx.run(() => rpc('settings.toggleAdBlockList', { profile_id: ctx.profileId, list_id: list.id, enabled }));
                        if (res) setState(res);
                      }}
                    />
                  </div>
                ))}
            </div>
          );
        })}
        {lists.length === 0 && <EmptyRow>{state?.last_error ?? 'Loading block lists…'}</EmptyRow>}
      </Group>

      <Group title="Don't block on these sites">
        <div id="row-adblock-allowed-sites" class="st-add-site">
          <TextInput
            value={site}
            onInput={(v) => {
              setSite(v);
              setSiteError(null);
            }}
            ariaLabel="Site to allow"
            placeholder="example.com"
            invalid={!!siteError}
            onEnter={addSite}
          />
          <Btn disabled={!site.trim()} onClick={addSite}>
            Add site
          </Btn>
        </div>
        {siteError && <div class="st-inline-error">{siteError}</div>}
        {(state?.exclusions ?? []).length === 0 ? (
          <EmptyRow>No sites yet.</EmptyRow>
        ) : (
          <div class="st-tags">
            {state?.exclusions.map((host) => (
              <span key={host} class="st-tag">
                {host}
                <button
                  type="button"
                  aria-label={`Block ads on ${host} again`}
                  onClick={async () => {
                    const res = await ctx.run(() => rpc('settings.removeAdBlockExclusion', { profile_id: ctx.profileId, host }));
                    if (res) setState(res);
                  }}
                >
                  <CloseIcon size={10} />
                </button>
              </span>
            ))}
          </div>
        )}
      </Group>

      <Group title="Custom rules">
        <div id="row-adblock-custom-rules" class="st-rules">
          <textarea
            class="st-textarea"
            spellcheck={false}
            rows={5}
            value={rules}
            placeholder={'! One rule per line, in Adblock Plus syntax\n||ads.example.com^\nexample.com##.promo-banner'}
            aria-label="Custom rules"
            onInput={(e) => {
              setRules((e.currentTarget as HTMLTextAreaElement).value);
              setRulesDirty(true);
            }}
          />
          <div class="st-rules-actions">
            <span class="st-muted">{rules.split('\n').filter((l) => l.trim() && !l.trim().startsWith('!')).length} rules</span>
            <Btn
              kind="primary"
              disabled={!rulesDirty}
              busy={busy === 'rules'}
              onClick={async () => {
                setBusy('rules');
                const res = await ctx.run(() => rpc('settings.adblock.setCustomRules', { profile_id: ctx.profileId, rules }), 'Custom rules saved.');
                setBusy(null);
                if (res) {
                  setState(res);
                  setRulesDirty(false);
                }
              }}
            >
              Save Rules
            </Btn>
          </div>
        </div>
      </Group>

      <Group title="Diagnostics">
        <Row id="adblock/debug" label="Copy debug info" help="Ad blocking details for a bug report. It has no page addresses.">
          <Btn
            onClick={async () => {
              const res = await ctx.run(() => rpc('settings.adblock.copyDebugInfo', { profile_id: ctx.profileId }));
              if (!res) return;
              try {
                await navigator.clipboard?.writeText(res.text);
              } catch {
                // The browser already copied it natively.
              }
              ctx.toast('Debug info copied.', 'success');
            }}
          >
            <CopyIcon size={12} /> Copy
          </Btn>
        </Row>
      </Group>

      <ConfirmDialog
        open={confirmReset}
        title="Reset block lists?"
        confirmLabel="Reset Lists"
        onConfirm={() => {
          setConfirmReset(false);
          void refresh('reset');
        }}
        onClose={() => setConfirmReset(false)}
      >
        <p class="st-dialog-text">Only EasyList and EasyPrivacy stay on. Downloaded lists are deleted and the bundled ones are used again.</p>
      </ConfirmDialog>
    </div>
  );
}
