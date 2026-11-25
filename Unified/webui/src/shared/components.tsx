// Shared reusable Preact UI primitives for Open Unified WebUI.

import type { ComponentChildren, JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import type { ProfileSummary, RGBAColor, SpaceStyle, ThemeAppearance, ThemeTexture, ThemeWheel } from './bridge';
import { CloseIcon, SearchIcon } from './icons';
import { formatShortcut, isMacPlatform, shortcutFromKeyboardEvent } from './shortcuts';

// --- Color & OKLab-approximated Space Theme Math ---

export function rgbaToCss(c: RGBAColor): string {
  return `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${c.a})`;
}

export function rgbaToHex(c: RGBAColor): string {
  const h = (v: number) => Math.max(0, Math.min(255, Math.round(v * 255))).toString(16).padStart(2, '0');
  return `#${h(c.r)}${h(c.g)}${h(c.b)}`;
}

export function hexToRgba(hex: string): RGBAColor {
  const clean = hex.replace('#', '');
  const full = clean.length === 3 ? clean.split('').map((x) => x + x).join('') : clean;
  const n = parseInt(full, 16);
  if (Number.isNaN(n)) return { r: 0.19, g: 0.22, b: 1, a: 1 };
  return {
    r: ((n >> 16) & 255) / 255,
    g: ((n >> 8) & 255) / 255,
    b: (n & 255) / 255,
    a: 1,
  };
}

function rgbToHsl(c: RGBAColor): [number, number, number] {
  const max = Math.max(c.r, c.g, c.b);
  const min = Math.min(c.r, c.g, c.b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h = 0;
  if (max === c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0);
  else if (max === c.g) h = (c.b - c.r) / d + 2;
  else h = (c.r - c.g) / d + 4;
  return [h * 60, s, l];
}

function hslToCss(h: number, s: number, l: number): string {
  const hh = ((h % 360) + 360) % 360;
  const ss = Math.max(0, Math.min(1, s)) * 100;
  const ll = Math.max(0.08, Math.min(0.92, l)) * 100;
  return `hsl(${hh.toFixed(1)} ${ss.toFixed(1)}% ${ll.toFixed(1)}%)`;
}

/**
 * Generates an OKLab-inspired dual-angle CSS gradient approximating Open's 64x64 Space theme shader.
 */
export function computeSpaceGradientCss(style: SpaceStyle): string {
  const [h, s, l] = rgbToHsl(style.key_color);
  const sat = Math.max(0.18, Math.min(0.95, s * (0.55 + style.intensity_factor * 0.65)));
  const baseL =
    style.appearance === 'dark'
      ? Math.min(0.36, Math.max(0.18, l * 0.58))
      : style.appearance === 'light'
        ? Math.max(0.64, Math.min(0.84, l + 0.18))
        : Math.max(0.28, Math.min(0.58, l * 0.85));

  const c1 = hslToCss(h, sat, baseL);
  if (style.color_count === 1) {
    return `linear-gradient(145deg, ${c1}, ${hslToCss(h, sat * 0.9, baseL * 0.86)})`;
  }
  const delta = style.wheel === 'complementary' ? 155 : 42;
  const c2 = hslToCss(h + delta, sat * 0.92, Math.min(0.82, baseL + 0.08));
  if (style.color_count === 2) {
    return `radial-gradient(circle at 82% 18%, ${c2} 0%, transparent 64%), linear-gradient(138deg, ${c1} 0%, ${c2} 100%)`;
  }
  const c3 = hslToCss(h - (style.wheel === 'complementary' ? 40 : 38), sat * 0.88, Math.max(0.16, baseL - 0.06));
  return `radial-gradient(circle at 18% 85%, ${c3} 0%, transparent 62%), radial-gradient(circle at 85% 15%, ${c2} 0%, transparent 58%), linear-gradient(135deg, ${c1} 0%, ${c2} 54%, ${c3} 100%)`;
}

export function isLightSpaceStyle(style: SpaceStyle): boolean {
  if (style.appearance === 'light') return true;
  if (style.appearance === 'dark') return false;
  const lum = 0.2126 * style.key_color.r + 0.7152 * style.key_color.g + 0.0722 * style.key_color.b;
  return lum > 0.6;
}

// --- Toggle ---

export interface ToggleProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
  label?: string;
}

export function Toggle({ checked, onChange, disabled, label }: ToggleProps): JSX.Element {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      class="open-toggle"
      onClick={() => onChange(!checked)}
    >
      <span class="open-toggle-knob" />
    </button>
  );
}

// --- Card ---

export interface CardProps {
  title?: string;
  children: ComponentChildren;
  class?: string;
}

export function Card({ title, children, class: className }: CardProps): JSX.Element {
  return (
    <div class={`open-card ${className ?? ''}`.trim()}>
      {title && <div class="open-card-header">{title}</div>}
      {children}
    </div>
  );
}

// --- SettingRow ---

export interface SettingRowProps {
  id?: string;
  label: string;
  help?: string;
  changed?: boolean;
  onReset?: () => void;
  disabled?: boolean;
  pulsing?: boolean;
  children: ComponentChildren;
}

export function SettingRow({
  id,
  label,
  help,
  changed,
  onReset,
  disabled,
  pulsing,
  children,
}: SettingRowProps): JSX.Element {
  return (
    <div
      id={id}
      class={`open-setting-row${disabled ? ' is-disabled' : ''}${pulsing ? ' is-pulsing' : ''}`}
      data-changed={changed ? 'true' : 'false'}
    >
      <div class="open-setting-row-meta">
        <div class="open-setting-row-label-line">
          {changed && <span class="open-changed-dot" title="Changed from default" />}
          <span class="open-setting-row-label">{label}</span>
        </div>
        {help && <div class="open-setting-row-help">{help}</div>}
      </div>
      <div class="open-setting-row-control">
        {changed && onReset && (
          <button type="button" class="open-reset-btn" onClick={onReset}>
            Reset
          </button>
        )}
        {children}
      </div>
    </div>
  );
}

// --- ProfilePill ---

export interface ProfilePillProps {
  profiles: ProfileSummary[];
  selectedProfileId: string;
  onChange: (profileId: string) => void;
  includeAllOption?: boolean;
}

export function ProfilePill({
  profiles,
  selectedProfileId,
  onChange,
  includeAllOption,
}: ProfilePillProps): JSX.Element {
  const active = profiles.find((p) => p.id === selectedProfileId);
  return (
    <label class="open-profile-pill" title="Scope setting to Profile">
      <span aria-hidden="true">{selectedProfileId === 'all' ? '🌐' : (active?.icon.value ?? '👤')}</span>
      <select
        aria-label="Select Profile"
        value={selectedProfileId}
        onChange={(e) => onChange((e.currentTarget as HTMLSelectElement).value)}
      >
        {includeAllOption && <option value="all">All Profiles</option>}
        {profiles.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>
    </label>
  );
}

// --- SearchInput ---

export interface SearchInputProps {
  value: string;
  onInput: (value: string) => void;
  placeholder?: string;
  inputRef?: { current: HTMLInputElement | null };
  onKeyDown?: (e: KeyboardEvent) => void;
  ariaLabel?: string;
}

export function SearchInput({
  value,
  onInput,
  placeholder = 'Search…',
  inputRef,
  onKeyDown,
  ariaLabel,
}: SearchInputProps): JSX.Element {
  return (
    <div class="open-search-wrap">
      <span class="open-search-icon" aria-hidden="true">
        <SearchIcon size={13} />
      </span>
      <input
        ref={inputRef}
        type="text"
        class="open-search-input"
        value={value}
        placeholder={placeholder}
        aria-label={ariaLabel ?? placeholder}
        onInput={(e) => onInput((e.currentTarget as HTMLInputElement).value)}
        onKeyDown={onKeyDown}
      />
      {value && (
        <button
          type="button"
          class="open-search-clear"
          aria-label="Clear search"
          onClick={() => onInput('')}
        >
          <CloseIcon size={12} />
        </button>
      )}
    </div>
  );
}

// --- Badge ---

export interface BadgeProps {
  tone?: 'default' | 'accent' | 'sun' | 'success' | 'danger';
  children: ComponentChildren;
}

export function Badge({ tone = 'default', children }: BadgeProps): JSX.Element {
  const cls = tone === 'default' ? 'open-badge' : `open-badge open-badge-${tone}`;
  return <span class={cls}>{children}</span>;
}

// --- SegmentedControl ---

export interface SegmentedOption<T extends string> {
  value: T;
  label: string;
}

export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  ariaLabel,
}: {
  options: readonly SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
  ariaLabel?: string;
}): JSX.Element {
  return (
    <div class="open-segmented" role="group" aria-label={ariaLabel}>
      {options.map((opt) => (
        <button
          key={opt.value}
          type="button"
          class="open-segmented-btn"
          aria-pressed={opt.value === value}
          onClick={() => onChange(opt.value)}
        >
          {opt.label}
        </button>
      ))}
    </div>
  );
}

// --- ShortcutRecorder ---

const MODIFIER_KEYS = new Set(['Meta', 'Control', 'Alt', 'Shift']);

export interface ShortcutRecorderProps {
  value: string;
  onRecord: (keys: string) => void;
  onClear?: () => void;
}

export function ShortcutRecorder({ value, onRecord, onClear }: ShortcutRecorderProps): JSX.Element {
  const [recording, setRecording] = useState(false);
  const [hint, setHint] = useState<string | null>(null);
  const btnRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    if (!recording) return;
    const onKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();

      if (e.key === 'Escape') {
        setRecording(false);
        setHint(null);
        return;
      }
      if ((e.key === 'Backspace' || e.key === 'Delete') && !e.metaKey && !e.ctrlKey && !e.altKey) {
        setRecording(false);
        setHint(null);
        onClear?.();
        return;
      }
      if (MODIFIER_KEYS.has(e.key)) return;

      const hasMod = e.metaKey || e.ctrlKey || e.altKey;
      if (!hasMod) {
        setHint(isMacPlatform() ? 'Add a modifier key (⌘ / ⌃ / ⌥)' : 'Add a modifier key (Ctrl / Alt)');
        return;
      }

      // Canonical "Mod+Shift+T" (Mod = ⌘ on macOS, Ctrl elsewhere), from the
      // physical key so Option/Shift never change the recorded letter.
      const keys = shortcutFromKeyboardEvent(e);
      if (!keys) {
        setHint('That key cannot be used in a shortcut');
        return;
      }

      setRecording(false);
      setHint(null);
      onRecord(keys);
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [recording, onRecord, onClear]);

  const cls = `open-shortcut-btn${recording ? ' is-recording' : ''}${!value && !recording ? ' is-empty' : ''}`;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '3px' }}>
      <button
        ref={btnRef}
        type="button"
        class={cls}
        onClick={() => {
          setRecording((r) => !r);
          setHint(null);
        }}
        onBlur={() => {
          setRecording(false);
          setHint(null);
        }}
      >
        {recording ? 'Press shortcut…' : value ? formatShortcut(value) : 'Add shortcut'}
      </button>
      {hint && <span style={{ fontSize: '10.5px', color: 'var(--open-sun)' }}>{hint}</span>}
    </div>
  );
}

// --- SpaceThemeEditor ---

const THEME_SWATCHES = [
  '#3139FF',
  '#7C3AED',
  '#DB2777',
  '#E5484D',
  '#EA580C',
  '#D97706',
  '#16A34A',
  '#0D9488',
  '#0284C7',
  '#475569',
];

export interface SpaceThemeEditorProps {
  style: SpaceStyle;
  title?: string;
  onChange: (style: SpaceStyle) => void;
}

export function SpaceThemeEditor({ style, title = 'Space Preview', onChange }: SpaceThemeEditorProps): JSX.Element {
  const gradient = computeSpaceGradientCss(style);
  const lightText = !isLightSpaceStyle(style);
  const hex = rgbaToHex(style.key_color);

  const patch = (partial: Partial<SpaceStyle>) => onChange({ ...style, ...partial });

  return (
    <div class="open-space-theme-editor">
      <div
        class="open-theme-preview"
        style={{
          background: gradient,
          color: lightText ? '#ffffff' : '#14151f',
        }}
      >
        <div
          class="open-theme-preview-noise"
          style={{
            opacity: style.noise_factor * 0.65,
            backgroundSize:
              style.texture === 'sand'
                ? '3px 3px'
                : style.texture === 'denim'
                  ? '6px 3px'
                  : style.texture === 'tweed'
                    ? '5px 5px'
                    : '4px 4px',
          }}
        />
        <div style={{ position: 'relative', zIndex: 1, display: 'flex', justifyContent: 'space-between', width: '100%', alignItems: 'center' }}>
          <div>
            <div style={{ fontWeight: 600, fontSize: '14px' }}>{title}</div>
            <div style={{ fontSize: '11px', opacity: 0.8 }}>
              {style.color_count}-color {style.wheel} · {style.texture}
            </div>
          </div>
          <span
            style={{
              fontSize: '11px',
              padding: '3px 8px',
              borderRadius: '999px',
              background: lightText ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.1)',
            }}
          >
            {Math.round(style.intensity_factor * 100)}%
          </span>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '10px', flexWrap: 'wrap' }}>
        <div class="open-theme-swatches">
          {THEME_SWATCHES.map((swatch) => (
            <button
              key={swatch}
              type="button"
              class={`open-theme-swatch${hex.toLowerCase() === swatch.toLowerCase() ? ' is-active' : ''}`}
              style={{ background: swatch }}
              aria-label={`Select color ${swatch}`}
              onClick={() => patch({ key_color: hexToRgba(swatch) })}
            />
          ))}
          <input
            type="color"
            value={hex}
            aria-label="Custom Space color"
            style={{ width: '26px', height: '24px', border: 'none', background: 'transparent', padding: 0, cursor: 'pointer' }}
            onInput={(e) => patch({ key_color: hexToRgba((e.currentTarget as HTMLInputElement).value) })}
          />
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
          <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>Colors</span>
          <SegmentedControl
            ariaLabel="Color count"
            value={String(style.color_count) as '1' | '2' | '3'}
            options={[
              { value: '1', label: '1' },
              { value: '2', label: '2' },
              { value: '3', label: '3' },
            ]}
            onChange={(v) => patch({ color_count: Number(v) as 1 | 2 | 3 })}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
          <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>Harmony</span>
          <SegmentedControl<ThemeWheel>
            ariaLabel="Color wheel harmony"
            value={style.wheel}
            options={[
              { value: 'analogous', label: 'Analogous' },
              { value: 'complementary', label: 'Complement' },
            ]}
            onChange={(wheel) => patch({ wheel })}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
          <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>Appearance</span>
          <SegmentedControl<ThemeAppearance>
            ariaLabel="Space appearance"
            value={style.appearance}
            options={[
              { value: 'automatic', label: 'Auto' },
              { value: 'light', label: 'Light' },
              { value: 'dark', label: 'Dark' },
            ]}
            onChange={(appearance) => patch({ appearance })}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
          <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>Texture</span>
          <select
            class="open-select"
            aria-label="Noise texture"
            value={style.texture}
            onChange={(e) => patch({ texture: (e.currentTarget as HTMLSelectElement).value as ThemeTexture })}
          >
            <option value="grain">Grain</option>
            <option value="sand">Sand</option>
            <option value="denim">Denim</option>
            <option value="tweed">Tweed</option>
          </select>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
        <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11px', color: 'var(--text-secondary)' }}>
          <span>Texture Grain ({Math.round(style.noise_factor * 100)}%)</span>
          <input
            type="range"
            min="0"
            max="1"
            step="0.02"
            value={style.noise_factor}
            onInput={(e) => patch({ noise_factor: parseFloat((e.currentTarget as HTMLInputElement).value) })}
          />
        </label>
        <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11px', color: 'var(--text-secondary)' }}>
          <span>Intensity ({Math.round(style.intensity_factor * 100)}%)</span>
          <input
            type="range"
            min="0.1"
            max="1"
            step="0.02"
            value={style.intensity_factor}
            onInput={(e) => patch({ intensity_factor: parseFloat((e.currentTarget as HTMLInputElement).value) })}
          />
        </label>
      </div>
    </div>
  );
}

// --- Modal ---

export interface ModalProps {
  open: boolean;
  title: string;
  onClose: () => void;
  footer?: ComponentChildren;
  children: ComponentChildren;
}

export function Modal({ open, title, onClose, footer, children }: ModalProps): JSX.Element | null {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      class="open-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div class="open-modal">
        <div class="open-modal-header">
          <h2 class="open-modal-title">{title}</h2>
          <button type="button" class="open-btn open-btn-ghost" aria-label="Close modal" onClick={onClose}>
            <CloseIcon />
          </button>
        </div>
        <div class="open-modal-body">{children}</div>
        {footer && <div class="open-modal-footer">{footer}</div>}
      </div>
    </div>
  );
}

// --- Toast ---

export function Toast({ message }: { message: string | null }): JSX.Element | null {
  if (!message) return null;
  return (
    <div class="open-toast" role="status" aria-live="polite">
      {message}
    </div>
  );
}
