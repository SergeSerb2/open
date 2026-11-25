import type { JSX } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { type Boost, type ProfileSummary, rpc } from '../shared/bridge';
import { Badge, Card, ProfilePill, SegmentedControl, SettingRow, Toast, Toggle } from '../shared/components';
import { OpenDoorwayMark, PlusIcon, TrashIcon, ZapIcon } from '../shared/icons';
import { currentPageRoute, replacePageRoute } from '../shared/route';

const FONT_OPTIONS = [
  { value: '', label: 'Site Default' },
  { value: 'Inter', label: 'Inter (Sans)' },
  { value: 'Georgia', label: 'Georgia (Serif)' },
  { value: 'SF Mono, ui-monospace, monospace', label: 'Monospace' },
  { value: 'system-ui, sans-serif', label: 'System UI' },
];

// A host from open://boosts/new?host=<host> (Site Control "New Boost"):
// lowercase, no scheme, port or path, no "www.".
function cleanHost(raw: string | null): string | null {
  if (!raw) return null;
  let host = raw.trim().toLowerCase();
  host = host.replace(/^[a-z][a-z0-9+.-]*:\/\//, '').split(/[/?#]/)[0] ?? '';
  host = host.replace(/:\d+$/, '').replace(/^www\./, '');
  return /^[a-z0-9.-]+$/.test(host) && (host.includes('.') || host === 'localhost') ? host : null;
}

function createEmptyBoost(profileId: string, host?: string): Boost {
  const now = Math.floor(Date.now() / 1000);
  return {
    id: `boost-${Date.now()}`,
    profile_id: profileId,
    name: host ? `${host} Boost` : 'New Site Boost',
    host_pattern: host ?? 'example.com',
    enabled: true,
    color: { enabled: false, hue_degrees: 0, saturation: 1, lightness: 0, contrast: 1, invert: false },
    font_family: '',
    text_zoom: 1.0,
    text_transform: '',
    custom_css: '',
    custom_js: '',
    zapped_elements: [],
    created_at: now,
    modified_at: now,
  };
}

export function BoostsApp(): JSX.Element {
  const [profiles, setProfiles] = useState<ProfileSummary[]>([]);
  const [profileId, setProfileId] = useState<string>('');
  const [globalEnabled, setGlobalEnabled] = useState(true);
  const [boosts, setBoosts] = useState<Boost[]>([]);
  const [selectedId, setSelectedId] = useState<string>('');
  const [draft, setDraft] = useState<Boost | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2500);
  };

  useEffect(() => {
    let active = true;
    async function init() {
      const profRes = await rpc('settings.listProfiles', {});
      const firstProfile = profRes.profiles[0]?.id ?? '';
      const listRes = await rpc('boosts.list', { profile_id: firstProfile });
      if (!active) return;
      setProfiles(profRes.profiles);
      setProfileId(firstProfile);
      setGlobalEnabled(listRes.global_enabled);
      setBoosts(listRes.boosts);

      // open://boosts/new?host=<host> starts an unsaved Boost for that
      // site; open://boosts/<id> (or #<id>) selects an existing one.
      const route = currentPageRoute();
      if (route.segments[0] === 'new') {
        const fresh = createEmptyBoost(firstProfile, cleanHost(route.params.get('host')) ?? undefined);
        setBoosts([fresh, ...listRes.boosts]);
        setSelectedId(fresh.id);
        setDraft(fresh);
        replacePageRoute('');
        return;
      }
      const routeId = route.segments[0] === 'edit' ? route.segments[1] : route.segments[0];
      const initial = listRes.boosts.find((b) => b.id === routeId) ?? listRes.boosts[0] ?? null;
      if (initial) {
        setSelectedId(initial.id);
        setDraft({ ...initial, color: { ...initial.color }, zapped_elements: [...initial.zapped_elements] });
      }
    }
    void init();
    return () => {
      active = false;
    };
  }, []);

  const selectBoost = (b: Boost) => {
    setSelectedId(b.id);
    setDraft({ ...b, color: { ...b.color }, zapped_elements: [...b.zapped_elements] });
  };

  const handleSave = async () => {
    if (!draft) return;
    if (!draft.host_pattern.trim()) {
      showToast('Enter a host pattern (e.g. news.ycombinator.com).');
      return;
    }
    const res = await rpc('boosts.save', { boost: draft });
    setBoosts((prev) => {
      const exists = prev.some((x) => x.id === res.boost.id);
      return exists ? prev.map((x) => (x.id === res.boost.id ? res.boost : x)) : [res.boost, ...prev];
    });
    setSelectedId(res.boost.id);
    setDraft({ ...res.boost, color: { ...res.boost.color }, zapped_elements: [...res.boost.zapped_elements] });
    showToast(`Saved Boost "${res.boost.name}".`);
  };

  const handleWheelClick = (e: MouseEvent) => {
    if (!draft) return;
    const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const dx = e.clientX - rect.left - cx;
    const dy = e.clientY - rect.top - cy;
    const angleDeg = ((Math.atan2(dy, dx) * 180) / Math.PI + 450) % 360;
    const hue = angleDeg > 180 ? angleDeg - 360 : angleDeg;
    const dist = Math.min(1, Math.hypot(dx, dy) / cx);
    const sat = Number((0.4 + dist * 1.4).toFixed(2));
    setDraft({
      ...draft,
      color: { ...draft.color, enabled: true, hue_degrees: Math.round(hue), saturation: sat },
    });
  };

  const previewFilter = draft?.color.enabled
    ? `hue-rotate(${draft.color.hue_degrees}deg) saturate(${draft.color.saturation}) brightness(${1 + draft.color.lightness}) contrast(${draft.color.contrast})${draft.color.invert ? ' invert(1)' : ''}`
    : 'none';

  const thumbAngleRad = (((draft?.color.hue_degrees ?? 0) - 90) * Math.PI) / 180;
  const thumbRadius = Math.min(1, Math.max(0, ((draft?.color.saturation ?? 1) - 0.4) / 1.4)) * 66;
  const thumbLeft = 76 + Math.cos(thumbAngleRad) * thumbRadius;
  const thumbTop = 76 + Math.sin(thumbAngleRad) * thumbRadius;

  return (
    <div class="boosts-shell">
      <aside class="boosts-sidebar">
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '8px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <OpenDoorwayMark size={24} />
            <strong>Boosts</strong>
          </div>
          <button
            type="button"
            class="open-btn open-btn-primary"
            onClick={() => {
              const fresh = createEmptyBoost(profileId);
              setBoosts((prev) => [fresh, ...prev]);
              selectBoost(fresh);
            }}
          >
            <PlusIcon size={12} /> New
          </button>
        </div>

        {profiles.length > 0 && (
          <ProfilePill
            profiles={profiles}
            selectedProfileId={profileId}
            onChange={async (pid) => {
              setProfileId(pid);
              const res = await rpc('boosts.list', { profile_id: pid });
              setBoosts(res.boosts);
              if (res.boosts[0]) selectBoost(res.boosts[0]);
              else setDraft(null);
            }}
          />
        )}

        {!globalEnabled && <Badge tone="sun">Boosts globally disabled in Settings</Badge>}

        <div class="boosts-list">
          {boosts.map((b) => (
            <div
              key={b.id}
              class={`boost-list-item${selectedId === b.id ? ' is-active' : ''}`}
              role="button"
              tabIndex={0}
              onClick={() => selectBoost(b)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') selectBoost(b);
              }}
            >
              <div style={{ minWidth: 0 }}>
                <div style={{ fontWeight: 600, fontSize: '12.5px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {b.name}
                </div>
                <div style={{ fontSize: '11px', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)' }}>
                  {b.host_pattern}
                </div>
              </div>
              <Toggle
                label={`Enable ${b.name}`}
                checked={b.enabled}
                onChange={async (enabled) => {
                  const res = await rpc('boosts.toggle', { id: b.id, enabled });
                  setBoosts((prev) => prev.map((x) => (x.id === b.id ? res.boost : x)));
                  if (draft?.id === b.id) setDraft({ ...draft, enabled });
                }}
              />
            </div>
          ))}
        </div>
      </aside>

      <main class="boosts-editor">
        {!draft ? (
          <Card>
            <div style={{ padding: '32px', textAlign: 'center', color: 'var(--text-secondary)' }}>
              Select a Boost or click <strong>New</strong> to restyle any website with colors, fonts, CSS, JS, and Zap.
            </div>
          </Card>
        ) : (
          <>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '12px', flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', gap: '10px', flex: 1, minWidth: '240px' }}>
                <input
                  class="open-input"
                  style={{ flex: 1, fontWeight: 600 }}
                  aria-label="Boost name"
                  value={draft.name}
                  onInput={(e) => setDraft({ ...draft, name: (e.currentTarget as HTMLInputElement).value })}
                />
                <input
                  class="open-input"
                  style={{ width: '210px', fontFamily: 'var(--font-mono)' }}
                  aria-label="Host pattern"
                  placeholder="domain.com"
                  value={draft.host_pattern}
                  onInput={(e) => setDraft({ ...draft, host_pattern: (e.currentTarget as HTMLInputElement).value })}
                />
              </div>
              <div style={{ display: 'flex', gap: '8px' }}>
                <button type="button" class="open-btn open-btn-primary" onClick={() => void handleSave()}>
                  Save Boost
                </button>
                <button
                  type="button"
                  class="open-btn open-btn-danger"
                  onClick={async () => {
                    await rpc('boosts.delete', { id: draft.id });
                    const remaining = boosts.filter((b) => b.id !== draft.id);
                    setBoosts(remaining);
                    if (remaining[0]) selectBoost(remaining[0]);
                    else setDraft(null);
                    showToast('Deleted Boost.');
                  }}
                >
                  <TrashIcon size={13} />
                </button>
              </div>
            </div>

            <div class="boost-preview-card" style={{ filter: previewFilter }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '8px' }}>
                <Badge tone="accent">Live Boost Preview · {draft.host_pattern}</Badge>
                <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>
                  Zoom {Math.round(draft.text_zoom * 100)}% · {draft.zapped_elements.length} Zapped
                </span>
              </div>
              <div
                style={{
                  fontFamily: draft.font_family || 'var(--font-sans)',
                  fontSize: `${Math.round(14 * draft.text_zoom)}px`,
                  textTransform: draft.text_transform || 'none',
                  lineHeight: 1.5,
                }}
              >
                The quick brown fox jumps over the lazy dog — custom color wheel, typography, zoom, and Zapped elements apply in isolated world 6.
              </div>
            </div>

            <Card title="Color Wheel">
              <SettingRow label="Enable color filter" help="Adjust page hue, saturation, lightness, contrast, or invert.">
                <Toggle
                  label="Enable color adjustment"
                  checked={draft.color.enabled}
                  onChange={(enabled) => setDraft({ ...draft, color: { ...draft.color, enabled } })}
                />
              </SettingRow>
              <div class="boost-wheel-row">
                <div
                  class="boost-color-wheel"
                  role="slider"
                  aria-label="Boost color wheel"
                  aria-valuenow={draft.color.hue_degrees}
                  tabIndex={0}
                  onClick={handleWheelClick}
                >
                  <div class="boost-wheel-thumb" style={{ left: `${thumbLeft}px`, top: `${thumbTop}px` }} />
                </div>
                <div class="boost-sliders">
                  <label class="boost-slider-label">
                    <span>Hue ({draft.color.hue_degrees}°)</span>
                    <input
                      type="range"
                      min="-180"
                      max="180"
                      value={draft.color.hue_degrees}
                      onInput={(e) =>
                        setDraft({
                          ...draft,
                          color: {
                            ...draft.color,
                            enabled: true,
                            hue_degrees: Number((e.currentTarget as HTMLInputElement).value),
                          },
                        })
                      }
                    />
                  </label>
                  <label class="boost-slider-label">
                    <span>Saturation ({Math.round(draft.color.saturation * 100)}%)</span>
                    <input
                      type="range"
                      min="0"
                      max="2"
                      step="0.05"
                      value={draft.color.saturation}
                      onInput={(e) =>
                        setDraft({
                          ...draft,
                          color: {
                            ...draft.color,
                            enabled: true,
                            saturation: Number((e.currentTarget as HTMLInputElement).value),
                          },
                        })
                      }
                    />
                  </label>
                  <label class="boost-slider-label">
                    <span>Lightness ({Math.round(draft.color.lightness * 100)}%)</span>
                    <input
                      type="range"
                      min="-0.5"
                      max="0.5"
                      step="0.02"
                      value={draft.color.lightness}
                      onInput={(e) =>
                        setDraft({
                          ...draft,
                          color: {
                            ...draft.color,
                            enabled: true,
                            lightness: Number((e.currentTarget as HTMLInputElement).value),
                          },
                        })
                      }
                    />
                  </label>
                  <label class="boost-slider-label">
                    <span>Contrast ({Math.round(draft.color.contrast * 100)}%)</span>
                    <input
                      type="range"
                      min="0.5"
                      max="2"
                      step="0.05"
                      value={draft.color.contrast}
                      onInput={(e) =>
                        setDraft({
                          ...draft,
                          color: {
                            ...draft.color,
                            enabled: true,
                            contrast: Number((e.currentTarget as HTMLInputElement).value),
                          },
                        })
                      }
                    />
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: '8px', fontSize: '12px' }}>
                    <input
                      type="checkbox"
                      checked={draft.color.invert}
                      onChange={(e) =>
                        setDraft({
                          ...draft,
                          color: {
                            ...draft.color,
                            enabled: true,
                            invert: (e.currentTarget as HTMLInputElement).checked,
                          },
                        })
                      }
                    />
                    <span>Invert page colors (preserves standalone &lt;img&gt; media)</span>
                  </label>
                </div>
              </div>
            </Card>

            <Card title="Typography & Zoom">
              <SettingRow label="Font family" help="Overrides body typography while keeping code and icons legible.">
                <select
                  class="open-select"
                  aria-label="Font family"
                  value={draft.font_family ?? ''}
                  onChange={(e) =>
                    setDraft({ ...draft, font_family: (e.currentTarget as HTMLSelectElement).value || undefined })
                  }
                >
                  {FONT_OPTIONS.map((f) => (
                    <option key={f.label} value={f.value}>
                      {f.label}
                    </option>
                  ))}
                </select>
              </SettingRow>
              <SettingRow label={`Text zoom (${Math.round(draft.text_zoom * 100)}%)`} help="Clamped between 50% and 200%.">
                <input
                  type="range"
                  min="0.5"
                  max="2"
                  step="0.05"
                  aria-label="Text zoom"
                  value={draft.text_zoom}
                  onInput={(e) => setDraft({ ...draft, text_zoom: Number((e.currentTarget as HTMLInputElement).value) })}
                />
              </SettingRow>
              <SettingRow label="Text case" help="Transform text casing across headings and paragraphs.">
                <SegmentedControl<Boost['text_transform']>
                  ariaLabel="Text transform"
                  value={draft.text_transform}
                  options={[
                    { value: '', label: 'Normal' },
                    { value: 'uppercase', label: 'UPPER' },
                    { value: 'lowercase', label: 'lower' },
                    { value: 'capitalize', label: 'Title' },
                  ]}
                  onChange={(text_transform) => setDraft({ ...draft, text_transform })}
                />
              </SettingRow>
            </Card>

            <Card title={`Zap Elements (${draft.zapped_elements.length})`}>
              <div style={{ padding: '12px 14px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '8px', borderBottom: '1px solid var(--border-subtle)' }}>
                <span style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>
                  Hide distracting page elements using isolated-world Zap overlays.
                </span>
                <div style={{ display: 'flex', gap: '8px' }}>
                  <button
                    type="button"
                    class="open-btn open-btn-primary"
                    onClick={async () => {
                      const res = await rpc('boosts.startZap', { boost_id: draft.id, mode: 'zap' });
                      const refreshed = await rpc('boosts.list', { profile_id: profileId });
                      setBoosts(refreshed.boosts);
                      const updated = refreshed.boosts.find((b) => b.id === draft.id);
                      if (updated) selectBoost(updated);
                      showToast(res.message);
                    }}
                  >
                    <ZapIcon size={13} /> Start Zap
                  </button>
                  <button
                    type="button"
                    class="open-btn"
                    onClick={async () => {
                      const res = await rpc('boosts.startZap', { boost_id: draft.id, mode: 'select' });
                      showToast(res.message);
                    }}
                  >
                    Pick Selector
                  </button>
                </div>
              </div>
              {draft.zapped_elements.length === 0 ? (
                <div style={{ padding: '16px 14px', fontSize: '12px', color: 'var(--text-secondary)' }}>
                  No Zapped elements on this site yet.
                </div>
              ) : (
                draft.zapped_elements.map((z) => (
                  <SettingRow key={z.id} label={z.label} help={z.selector}>
                    <button
                      type="button"
                      class="open-btn open-btn-ghost"
                      onClick={async () => {
                        const res = await rpc('boosts.removeZap', { boost_id: draft.id, zap_id: z.id });
                        setBoosts((prev) => prev.map((x) => (x.id === res.boost.id ? res.boost : x)));
                        selectBoost(res.boost);
                        showToast(`Revealed "${z.label}".`);
                      }}
                    >
                      Reveal
                    </button>
                  </SettingRow>
                ))
              )}
            </Card>

            <Card title="Code (CSS & JavaScript)">
              <div style={{ padding: '14px', display: 'flex', flexDirection: 'column', gap: '12px' }}>
                <label class="boost-slider-label">
                  <span>Custom CSS (applied live in Open isolated world)</span>
                  <textarea
                    class="open-textarea code-editor"
                    placeholder="/* Custom CSS rules */"
                    value={draft.custom_css}
                    onInput={(e) => setDraft({ ...draft, custom_css: (e.currentTarget as HTMLTextAreaElement).value })}
                  />
                </label>
                <label class="boost-slider-label">
                  <span>Custom JavaScript (runs at document-start in page world after refresh)</span>
                  <textarea
                    class="open-textarea code-editor"
                    placeholder="// Optional site JavaScript"
                    value={draft.custom_js}
                    onInput={(e) => setDraft({ ...draft, custom_js: (e.currentTarget as HTMLTextAreaElement).value })}
                  />
                </label>
              </div>
            </Card>
          </>
        )}
      </main>

      <Toast message={toast} />
    </div>
  );
}
