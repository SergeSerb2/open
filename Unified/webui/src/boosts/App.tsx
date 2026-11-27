// open://boosts — the Boost Gallery and manager: the Profile's Boosts as
// cards (On/Off, Edit in Floating Panel, Export, Delete), starter templates,
// share-card import, and the full editor (open://boosts/<id>, /new?host=).

import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { type Boost, type ProfileSummary, rpc } from '../shared/bridge';
import { Modal, ProfilePill, Toast, Toggle } from '../shared/components';
import { PlusIcon } from '../shared/icons';
import { currentPageRoute, replacePageRoute } from '../shared/route';
import { subscribeSettingsTheme } from '../shared/theme';
import { DoorwayEmblem } from '../onboarding/art';
import { BoostEditor } from './Editor';
import { type BoostShareCard, downloadShareCard, editOnSite, parseShareCard } from './rpc';
import { BOOST_TEMPLATES, type BoostTemplate } from './templates';

// A host from open://boosts/new?host=<host> (Site Control "New Boost"):
// lowercase, no scheme, port or path, no "www.".
function cleanHost(raw: string | null): string | null {
  if (!raw) return null;
  let host = raw.trim().toLowerCase();
  host = host.replace(/^[a-z][a-z0-9+.-]*:\/\//, '').split(/[/?#]/)[0] ?? '';
  host = host.replace(/:\d+$/, '').replace(/^www\./, '');
  return /^[a-z0-9.-]+$/.test(host) && (host.includes('.') || host === 'localhost') ? host : null;
}

function newId(): string {
  const rand =
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  return `boost-${rand}`;
}

function blankBoost(profileId: string, host?: string): Boost {
  const now = Math.floor(Date.now() / 1000);
  return {
    id: newId(),
    profile_id: profileId,
    name: host ? `${host} Boost` : 'New Boost',
    host_pattern: host ?? '',
    enabled: true,
    color: { enabled: false, hue_degrees: 0, saturation: 1, lightness: 0, contrast: 1, invert: false },
    font_family: '',
    text_zoom: 1,
    text_transform: '',
    custom_css: '',
    custom_js: '',
    zapped_elements: [],
    created_at: now,
    modified_at: now,
  };
}

function copyBoost(b: Boost): Boost {
  return { ...b, color: { ...b.color }, zapped_elements: b.zapped_elements.map((z) => ({ ...z })) };
}

function previewFilter(b: Pick<Boost, 'color'>): string {
  const c = b.color;
  return c.enabled
    ? `hue-rotate(${c.hue_degrees}deg) saturate(${c.saturation}) brightness(${1 + c.lightness}) contrast(${c.contrast})${c.invert ? ' invert(1)' : ''}`
    : 'none';
}

/** A small page drawing with the Boost's look applied. */
function BoostPreview({
  boost,
  page = '#fbfaf7',
  ink = '#2b2b33',
  accent = '#4f46e5',
}: {
  boost: Pick<Boost, 'color' | 'font_family' | 'text_transform' | 'zapped_elements' | 'custom_css'>;
  page?: string;
  ink?: string;
  accent?: string;
}): JSX.Element {
  return (
    <div class="bst-preview" style={{ filter: previewFilter(boost), background: page, color: ink }} aria-hidden="true">
      <div class="bst-preview-bar" style={{ background: accent }} />
      <div
        class="bst-preview-title"
        style={{ fontFamily: boost.font_family || 'var(--font-sans)', textTransform: boost.text_transform || 'none' }}
      >
        Aa
      </div>
      <div class="bst-preview-lines">
        <i style={{ width: '86%' }} />
        <i style={{ width: '72%' }} />
        <i style={{ width: '80%' }} />
      </div>
      {boost.zapped_elements.length === 0 && !boost.custom_css && <div class="bst-preview-ad" style={{ borderColor: accent }} />}
    </div>
  );
}

type View = { kind: 'gallery' } | { kind: 'edit'; id: string; isNew: boolean };

export function BoostsApp(): JSX.Element {
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [profileId, setProfileId] = useState('');
  const [globalEnabled, setGlobalEnabled] = useState(true);
  const [boosts, setBoosts] = useState<Boost[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [view, setView] = useState<View>({ kind: 'gallery' });
  const [draft, setDraft] = useState<Boost | null>(null);
  const [saved, setSaved] = useState<Boost | null>(null);
  const [query, setQuery] = useState('');
  const [toast, setToast] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<Boost | null>(null);
  const [templateHost, setTemplateHost] = useState<{ template: BoostTemplate; host: string } | null>(null);
  const [importCard, setImportCard] = useState<BoostShareCard['boost'] | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2800);
  }, []);

  const openEditor = useCallback((b: Boost, isNew = false) => {
    setDraft(copyBoost(b));
    setSaved(isNew ? null : copyBoost(b));
    setView({ kind: 'edit', id: b.id, isNew });
    if (!isNew) replacePageRoute(b.id);
  }, []);

  const backToGallery = () => {
    setView({ kind: 'gallery' });
    setDraft(null);
    replacePageRoute('');
  };

  const load = useCallback(async (pid: string) => {
    const res = await rpc('boosts.list', { profile_id: pid });
    setBoosts(res.boosts);
    setGlobalEnabled(res.global_enabled);
    return res.boosts;
  }, []);

  useEffect(() => subscribeSettingsTheme(), []);

  useEffect(() => {
    let active = true;
    void (async () => {
      const profRes = await rpc('settings.listProfiles', {});
      const first = profRes.profiles.find((p) => p.is_default)?.id ?? profRes.profiles[0]?.id ?? '';
      if (!active) return;
      setProfiles(profRes.profiles);
      setProfileId(first);
      const list = await load(first);
      if (!active) return;
      setLoaded(true);
      // open://boosts/new?host=<host> starts an unsaved Boost for that site;
      // open://boosts/<id> (or /edit/<id>) opens one.
      const route = currentPageRoute();
      if (route.segments[0] === 'new') {
        openEditor(blankBoost(first, cleanHost(route.params.get('host')) ?? undefined), true);
        replacePageRoute('');
        return;
      }
      const routeId = route.segments[0] === 'edit' ? route.segments[1] : route.segments[0];
      const routed = list.find((b) => b.id === routeId);
      if (routed) openEditor(routed);
    })();
    return () => {
      active = false;
    };
  }, [load, openEditor]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const list = [...boosts].sort((a, b) => b.modified_at - a.modified_at);
    return q ? list.filter((b) => b.name.toLowerCase().includes(q) || b.host_pattern.toLowerCase().includes(q)) : list;
  }, [boosts, query]);

  const upsert = (b: Boost) =>
    setBoosts((prev) => (prev.some((x) => x.id === b.id) ? prev.map((x) => (x.id === b.id ? b : x)) : [b, ...prev]));

  const save = async (b: Boost): Promise<Boost | null> => {
    const host = cleanHost(b.host_pattern) ?? b.host_pattern.trim().toLowerCase();
    if (!host) {
      showToast('Add the site this Boost is for, like example.com.');
      return null;
    }
    try {
      const res = await rpc('boosts.save', { boost: { ...b, host_pattern: host, name: b.name.trim() || `${host} Boost` } });
      upsert(res.boost);
      return res.boost;
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'The Boost could not be saved.');
      return null;
    }
  };

  const toggle = async (b: Boost, enabled: boolean) => {
    upsert({ ...b, enabled });
    try {
      const res = await rpc('boosts.toggle', { id: b.id, enabled, profile_id: b.profile_id } as { id: string; enabled: boolean });
      upsert(res.boost);
      if (draft?.id === b.id) {
        setDraft({ ...draft, enabled: res.boost.enabled });
        setSaved(copyBoost(res.boost));
      }
    } catch {
      upsert(b);
      showToast('Could not change that Boost.');
    }
  };

  const remove = async (b: Boost) => {
    setConfirmDelete(null);
    try {
      await rpc('boosts.delete', { id: b.id, profile_id: b.profile_id } as { id: string });
      setBoosts((prev) => prev.filter((x) => x.id !== b.id));
      if (view.kind === 'edit' && view.id === b.id) backToGallery();
      showToast(`Deleted “${b.name}”.`);
    } catch {
      showToast('Could not delete that Boost.');
    }
  };

  const floatingEdit = async (b: Boost, zap = false) => {
    try {
      const res = await editOnSite(b, zap);
      if (res.message) showToast(res.message);
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'Could not open the site.');
    }
  };

  const applyTemplate = async (template: BoostTemplate, host: string) => {
    const b = blankBoost(profileId, host);
    const created = await save({
      ...b,
      name: template.host_pattern ? template.name : `${template.name} · ${host}`,
      color: { ...template.boost.color },
      font_family: template.boost.font_family,
      text_zoom: template.boost.text_zoom,
      text_transform: template.boost.text_transform,
      custom_css: template.boost.custom_css,
    });
    setTemplateHost(null);
    if (created) showToast(`Added “${created.name}”. It applies the next time ${created.host_pattern} loads.`);
  };

  const importFile = async (file: File) => {
    if (file.size > 1024 * 1024) {
      showToast('That file is too large to be a Boost.');
      return;
    }
    try {
      setImportCard(parseShareCard(await file.text()));
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'That file is not a Boost.');
    }
  };

  const finishImport = async (withScript: boolean) => {
    if (!importCard) return;
    const card = importCard;
    setImportCard(null);
    const created = await save({
      ...blankBoost(profileId, card.host_pattern),
      ...card,
      custom_js: withScript ? card.custom_js : '',
      font_family: card.font_family ?? '',
      zapped_elements: card.zapped_elements.map((z) => ({ ...z })),
    });
    if (created) showToast(`Imported “${created.name}”.`);
  };

  const dirty = useMemo(() => {
    if (!draft) return false;
    if (!saved) return true;
    return JSON.stringify({ ...draft, modified_at: 0 }) !== JSON.stringify({ ...saved, modified_at: 0 });
  }, [draft, saved]);

  const header = (
    <header class="bst-header">
      <div class="bst-title">
        <DoorwayEmblem size={26} />
        <h1>Boosts</h1>
      </div>
      {profiles.length > 1 && (
        <ProfilePill
          profiles={profiles}
          selectedProfileId={profileId}
          onChange={async (pid) => {
            setProfileId(pid);
            backToGallery();
            await load(pid);
          }}
        />
      )}
      <span class="bst-spacer" />
      {view.kind === 'gallery' && (
        <input
          class="open-input bst-search"
          type="search"
          placeholder="Search Boosts"
          aria-label="Search Boosts"
          value={query}
          onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)}
        />
      )}
      <button type="button" class="open-btn" onClick={() => fileRef.current?.click()}>
        Import…
      </button>
      <button type="button" class="open-btn open-btn-primary" onClick={() => openEditor(blankBoost(profileId), true)}>
        <PlusIcon size={12} /> New Boost
      </button>
      <input
        ref={fileRef}
        type="file"
        accept=".json,application/json"
        hidden
        onChange={(e) => {
          const input = e.currentTarget as HTMLInputElement;
          const file = input.files?.[0];
          input.value = '';
          if (file) void importFile(file);
        }}
      />
    </header>
  );

  const banner = !globalEnabled && (
    <div class="bst-banner" role="status">
      <span>Boosts are turned off, so none of them change pages right now.</span>
      <button
        type="button"
        class="open-btn open-btn-primary"
        onClick={async () => {
          try {
            await rpc('settings.setPreference', { key: 'advanced.enableBoosts', value: true });
            setGlobalEnabled(true);
          } catch {
            showToast('Turn Boosts on in Settings › Advanced.');
          }
        }}
      >
        Turn On
      </button>
    </div>
  );

  return (
    <div class="bst-shell">
      {header}
      {banner}

      {view.kind === 'edit' && draft ? (
        <BoostEditor
          draft={draft}
          isNew={view.isNew}
          dirty={dirty}
          setDraft={setDraft}
          onBack={backToGallery}
          onSave={async () => {
            const res = await save(draft);
            if (res) {
              setDraft(copyBoost(res));
              setSaved(copyBoost(res));
              setView({ kind: 'edit', id: res.id, isNew: false });
              replacePageRoute(res.id);
              showToast(`Saved “${res.name}”.`);
            }
          }}
          onDelete={() => setConfirmDelete(draft)}
          onEditOnSite={() => void floatingEdit(draft)}
          onExport={() => downloadShareCard(draft)}
          onZap={() => void floatingEdit(draft, true)}
          onPickSelector={() => void floatingEdit(draft, true)}
          onRemoveZap={async (zapId, label) => {
            try {
              const res = await rpc('boosts.removeZap', {
                boost_id: draft.id,
                zap_id: zapId,
                profile_id: draft.profile_id,
              } as { boost_id: string; zap_id: string });
              upsert(res.boost);
              setDraft(copyBoost(res.boost));
              setSaved(copyBoost(res.boost));
              showToast(`Showing “${label}” again.`);
            } catch {
              showToast('Could not remove that Zap.');
            }
          }}
        />
      ) : (
        <main class="bst-gallery">
          <section aria-label="Your Boosts">
            <div class="bst-section-head">
              <h2>Your Boosts</h2>
              <span>{boosts.length ? `${boosts.length} in this Profile` : ''}</span>
            </div>
            {loaded && filtered.length === 0 ? (
              <div class="bst-empty">
                {query ? (
                  <p>No Boost matches “{query}”.</p>
                ) : (
                  <>
                    <p>
                      <strong>Make any site yours.</strong> A Boost changes how a site looks: colors, fonts, and the
                      parts you’d rather not see. Start from a template below, or make one from scratch.
                    </p>
                    <button type="button" class="open-btn open-btn-primary" onClick={() => openEditor(blankBoost(profileId), true)}>
                      <PlusIcon size={12} /> New Boost
                    </button>
                  </>
                )}
              </div>
            ) : (
              <div class="bst-grid">
                {filtered.map((b) => (
                  <article key={b.id} class={`bst-card${b.enabled ? '' : ' is-off'}`}>
                    <button type="button" class="bst-card-art" aria-label={`Edit ${b.name}`} onClick={() => openEditor(b)}>
                      <BoostPreview boost={b} />
                    </button>
                    <div class="bst-card-body">
                      <div class="bst-card-text">
                        <h3 title={b.name}>{b.name}</h3>
                        <span class="bst-host">{b.host_pattern}</span>
                      </div>
                      <Toggle label={`${b.name} on or off`} checked={b.enabled} onChange={(on) => void toggle(b, on)} />
                    </div>
                    <div class="bst-card-actions">
                      <button type="button" class="bst-chip is-strong" onClick={() => void floatingEdit(b)}>
                        Edit in Floating Panel
                      </button>
                      <button type="button" class="bst-chip" onClick={() => openEditor(b)}>
                        Details
                      </button>
                      <button type="button" class="bst-chip" onClick={() => downloadShareCard(b)}>
                        Export
                      </button>
                      <button
                        type="button"
                        class="bst-chip is-danger"
                        aria-label={`Delete ${b.name}`}
                        onClick={() => setConfirmDelete(b)}
                      >
                        Delete
                      </button>
                    </div>
                    {b.zapped_elements.length > 0 && (
                      <span class="bst-zaps">
                        {b.zapped_elements.length} Zap{b.zapped_elements.length === 1 ? '' : 's'}
                      </span>
                    )}
                  </article>
                ))}
              </div>
            )}
          </section>

          <section aria-label="Templates" class="bst-templates">
            <div class="bst-section-head">
              <h2>Start from a template</h2>
              <span>You can change everything afterwards.</span>
            </div>
            <div class="bst-grid">
              {BOOST_TEMPLATES.map((t) => {
                const installed = t.host_pattern && boosts.some((b) => b.host_pattern === t.host_pattern && b.name === t.name);
                return (
                  <article key={t.id} class="bst-card is-template">
                    <div class="bst-card-art">
                      <BoostPreview
                        boost={{ ...t.boost, zapped_elements: [] }}
                        page={t.preview.page}
                        ink={t.preview.ink}
                        accent={t.preview.accent}
                      />
                    </div>
                    <div class="bst-card-body">
                      <div class="bst-card-text">
                        <h3>{t.name}</h3>
                        <span class="bst-host">{t.host_pattern || 'Any site you choose'}</span>
                      </div>
                    </div>
                    <p class="bst-card-desc">{t.description}</p>
                    <div class="bst-card-actions">
                      {installed ? (
                        <span class="bst-chip is-done">Added</span>
                      ) : t.host_pattern ? (
                        <button type="button" class="bst-chip is-strong" onClick={() => void applyTemplate(t, t.host_pattern)}>
                          Use Template
                        </button>
                      ) : (
                        <button type="button" class="bst-chip is-strong" onClick={() => setTemplateHost({ template: t, host: '' })}>
                          Choose a Site…
                        </button>
                      )}
                    </div>
                  </article>
                );
              })}
            </div>
          </section>
        </main>
      )}

      <Modal
        open={confirmDelete !== null}
        title="Delete this Boost?"
        onClose={() => setConfirmDelete(null)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setConfirmDelete(null)}>
              Cancel
            </button>
            <button type="button" class="open-btn open-btn-danger" onClick={() => confirmDelete && void remove(confirmDelete)}>
              Delete
            </button>
          </>
        }
      >
        <p class="bst-modal-text">
          “{confirmDelete?.name}” stops changing {confirmDelete?.host_pattern}. Its Zaps go too. You can’t undo this.
        </p>
      </Modal>

      <Modal
        open={templateHost !== null}
        title={templateHost ? `Use “${templateHost.template.name}”` : ''}
        onClose={() => setTemplateHost(null)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setTemplateHost(null)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              disabled={!templateHost || !cleanHost(templateHost.host)}
              onClick={() => {
                const host = templateHost && cleanHost(templateHost.host);
                if (templateHost && host) void applyTemplate(templateHost.template, host);
              }}
            >
              Add Boost
            </button>
          </>
        }
      >
        <form
          class="bst-modal-form"
          onSubmit={(e) => {
            e.preventDefault();
            const host = templateHost && cleanHost(templateHost.host);
            if (templateHost && host) void applyTemplate(templateHost.template, host);
          }}
        >
          <label class="bst-modal-text" for="bst-template-host">
            Which site should it change?
          </label>
          <input
            id="bst-template-host"
            class="open-input"
            placeholder="example.com"
            autoFocus
            value={templateHost?.host ?? ''}
            onInput={(e) =>
              templateHost && setTemplateHost({ ...templateHost, host: (e.currentTarget as HTMLInputElement).value })
            }
          />
        </form>
      </Modal>

      <Modal
        open={importCard !== null}
        title={importCard ? `Import “${importCard.name}”?` : ''}
        onClose={() => setImportCard(null)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setImportCard(null)}>
              Cancel
            </button>
            {importCard?.custom_js ? (
              <>
                <button type="button" class="open-btn" onClick={() => void finishImport(true)}>
                  Import with Script
                </button>
                <button type="button" class="open-btn open-btn-primary" onClick={() => void finishImport(false)}>
                  Import without Script
                </button>
              </>
            ) : (
              <button type="button" class="open-btn open-btn-primary" onClick={() => void finishImport(false)}>
                Import
              </button>
            )}
          </>
        }
      >
        {importCard && (
          <div class="bst-import">
            <BoostPreview boost={importCard} />
            <p class="bst-modal-text">
              Changes <strong>{importCard.host_pattern}</strong>
              {importCard.zapped_elements.length ? ` and hides ${importCard.zapped_elements.length} part(s) of it` : ''}.
            </p>
            {importCard.custom_js && (
              <p class="bst-warn">
                This Boost runs its own JavaScript on {importCard.host_pattern}. Keep the script only if you trust the
                person who shared it.
              </p>
            )}
          </div>
        )}
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
