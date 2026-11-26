// The Boost editor (open://boosts/<id>, open://boosts/new): colors, type,
// Zap and code. The floating editor on the site itself is
// "Edit in Floating Panel" (boosts.editOnSite).

import type { JSX } from 'preact';
import type { Boost } from '../shared/bridge';
import { Badge, Card, SegmentedControl, SettingRow, Toggle } from '../shared/components';
import { TrashIcon, ZapIcon } from '../shared/icons';

const FONT_OPTIONS = [
  { value: '', label: 'Site Default' },
  { value: 'Inter', label: 'Inter (Sans)' },
  { value: 'Georgia', label: 'Georgia (Serif)' },
  { value: 'SF Mono, ui-monospace, monospace', label: 'Monospace' },
  { value: 'system-ui, sans-serif', label: 'System UI' },
];

export interface EditorProps {
  draft: Boost;
  isNew: boolean;
  dirty: boolean;
  setDraft: (next: Boost) => void;
  onBack: () => void;
  onSave: () => void;
  onDelete: () => void;
  onEditOnSite: () => void;
  onExport: () => void;
  onZap: () => void;
  onPickSelector: () => void;
  onRemoveZap: (zapId: string, label: string) => void;
}

export function BoostEditor({
  draft,
  isNew,
  dirty,
  setDraft,
  onBack,
  onSave,
  onDelete,
  onEditOnSite,
  onExport,
  onZap,
  onPickSelector,
  onRemoveZap,
}: EditorProps): JSX.Element {
  const handleWheelClick = (e: MouseEvent) => {
    const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const dx = e.clientX - rect.left - cx;
    const dy = e.clientY - rect.top - cy;
    const angleDeg = ((Math.atan2(dy, dx) * 180) / Math.PI + 450) % 360;
    const hue = angleDeg > 180 ? angleDeg - 360 : angleDeg;
    const dist = Math.min(1, Math.hypot(dx, dy) / cx);
    const sat = Number((0.4 + dist * 1.4).toFixed(2));
    setDraft({ ...draft, color: { ...draft.color, enabled: true, hue_degrees: Math.round(hue), saturation: sat } });
  };

  const previewFilter = draft.color.enabled
    ? `hue-rotate(${draft.color.hue_degrees}deg) saturate(${draft.color.saturation}) brightness(${1 + draft.color.lightness}) contrast(${draft.color.contrast})${draft.color.invert ? ' invert(1)' : ''}`
    : 'none';

  const thumbAngleRad = ((draft.color.hue_degrees - 90) * Math.PI) / 180;
  const thumbRadius = Math.min(1, Math.max(0, (draft.color.saturation - 0.4) / 1.4)) * 66;
  const thumbLeft = 76 + Math.cos(thumbAngleRad) * thumbRadius;
  const thumbTop = 76 + Math.sin(thumbAngleRad) * thumbRadius;

  return (
    <main class="boosts-editor">
      <div class="bst-editor-bar">
        <button type="button" class="open-btn open-btn-ghost" onClick={onBack}>
          ← All Boosts
        </button>
        <span class="bst-editor-spacer" />
        {!isNew && (
          <>
            <button type="button" class="open-btn" onClick={onEditOnSite} title="Open the site with the floating Boost editor">
              Edit in Floating Panel
            </button>
            <button type="button" class="open-btn" onClick={onExport}>
              Export
            </button>
          </>
        )}
        <button type="button" class="open-btn open-btn-primary" disabled={!dirty && !isNew} onClick={onSave}>
          {isNew ? 'Create Boost' : dirty ? 'Save Boost' : 'Saved'}
        </button>
        {!isNew && (
          <button type="button" class="open-btn open-btn-danger" aria-label="Delete Boost" onClick={onDelete}>
            <TrashIcon size={13} />
          </button>
        )}
      </div>

      <div class="bst-editor-names">
        <input
          class="open-input"
          style={{ flex: 1, fontWeight: 600 }}
          aria-label="Boost name"
          value={draft.name}
          onInput={(e) => setDraft({ ...draft, name: (e.currentTarget as HTMLInputElement).value })}
        />
        <input
          class="open-input"
          style={{ width: '220px', fontFamily: 'var(--font-mono)' }}
          aria-label="Site"
          placeholder="example.com"
          value={draft.host_pattern}
          onInput={(e) => setDraft({ ...draft, host_pattern: (e.currentTarget as HTMLInputElement).value })}
        />
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
              onClick={() => onZap()}
            >
              <ZapIcon size={13} /> Start Zap
            </button>
            <button
              type="button"
              class="open-btn"
              onClick={() => onPickSelector()}
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
                onClick={() => onRemoveZap(z.id, z.label)}
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
    </main>
  );
}
