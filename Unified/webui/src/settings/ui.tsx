// Settings-only controls in the Swift Open Settings style: grouped cards,
// rows with a changed dot and Reset, bordered buttons, native selects.

import type { ComponentChildren, JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { Modal, ProfilePill, Toggle } from '../shared/components';
import { InfoIcon, WarningIcon } from '../shared/icons';
import { isMacPlatform, shortcutFromKeyboardEvent, shortcutKeycaps } from '../shared/shortcuts';
import { useSettings } from './context';
import { SECTION_BY_ID, type SectionId } from './sections';

export function rowDomId(id: string): string {
  return `row-${id.replace(/[^a-z0-9-]+/gi, '-')}`;
}

export function PaneHeader({ section, right }: { section: SectionId; right?: ComponentChildren }): JSX.Element {
  const ctx = useSettings();
  const def = SECTION_BY_ID[section];
  return (
    <header class="st-pane-header">
      <div class="st-pane-heading">
        <h1 class="st-pane-title">{def.title}</h1>
        <p class="st-pane-subtitle">{def.subtitle}</p>
      </div>
      <div class="st-pane-header-right">
        {right}
        {def.perProfile && ctx.profiles.length > 0 && (
          <ProfilePill profiles={ctx.profiles} selectedProfileId={ctx.profileId} onChange={ctx.setProfileId} />
        )}
      </div>
    </header>
  );
}

export function Group({
  title,
  action,
  children,
  plain,
  id,
}: {
  title?: string;
  action?: ComponentChildren;
  children: ComponentChildren;
  plain?: boolean;
  id?: string;
}): JSX.Element {
  return (
    <section class="st-group" id={id}>
      {(title || action) && (
        <div class="st-group-head">
          {title && <h2 class="st-group-title">{title}</h2>}
          {action && <div class="st-group-action">{action}</div>}
        </div>
      )}
      {plain ? children : <div class="st-card">{children}</div>}
    </section>
  );
}

export interface RowProps {
  id: string;
  label: ComponentChildren;
  help?: ComponentChildren;
  prefKey?: string;
  changed?: boolean;
  onReset?: () => void;
  stacked?: boolean;
  disabled?: boolean;
  children?: ComponentChildren;
}

export function Row({ id, label, help, prefKey, changed, onReset, stacked, disabled, children }: RowProps): JSX.Element {
  const ctx = useSettings();
  const isChanged = changed ?? (prefKey ? ctx.isChanged(prefKey) : false);
  const reset = onReset ?? (prefKey ? () => void ctx.resetPref(prefKey) : undefined);
  const domId = rowDomId(id);
  return (
    <div
      id={domId}
      class={`st-row${stacked ? ' is-stacked' : ''}${disabled ? ' is-disabled' : ''}${ctx.pulsingRow === domId ? ' is-pulsing' : ''}`}
    >
      <div class="st-row-meta">
        <div class="st-row-label">
          {isChanged && <span class="st-changed-dot" title="Changed from the default" />}
          {label}
        </div>
        {help && <div class="st-row-help">{help}</div>}
      </div>
      {(children || (isChanged && reset)) && (
        <div class="st-row-control">
          {isChanged && reset && (
            <button type="button" class="st-reset" onClick={reset}>
              Reset
            </button>
          )}
          {children}
        </div>
      )}
    </div>
  );
}

export function PrefToggle({
  id,
  label,
  help,
  prefKey,
  disabled,
  onChanged,
}: {
  id: string;
  label: string;
  help?: ComponentChildren;
  prefKey: string;
  disabled?: boolean;
  onChanged?: (value: boolean) => void;
}): JSX.Element {
  const ctx = useSettings();
  const value = ctx.prefs[prefKey] === true;
  return (
    <Row id={id} label={label} help={help} prefKey={prefKey} disabled={disabled}>
      <Toggle
        checked={value}
        disabled={disabled}
        label={label}
        onChange={async (next) => {
          if (await ctx.setPref(prefKey, next)) onChanged?.(next);
        }}
      />
    </Row>
  );
}

export interface Option<T extends string> {
  value: T;
  label: string;
}

export function Select<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
  wide,
  disabled,
}: {
  value: T;
  options: readonly Option<T>[];
  onChange: (value: T) => void;
  ariaLabel: string;
  wide?: boolean;
  disabled?: boolean;
}): JSX.Element {
  return (
    <span class={`st-select${wide ? ' is-wide' : ''}`}>
      <select
        aria-label={ariaLabel}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange((e.currentTarget as HTMLSelectElement).value as T)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <svg class="st-select-arrows" width="9" height="12" viewBox="0 0 9 12" aria-hidden="true">
        <path d="M1.5 4.5L4.5 1.5 7.5 4.5M1.5 7.5L4.5 10.5 7.5 7.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </span>
  );
}

export function PrefSelect<T extends string>({
  id,
  label,
  help,
  prefKey,
  options,
  wide,
}: {
  id: string;
  label: string;
  help?: ComponentChildren;
  prefKey: string;
  options: readonly Option<T>[];
  wide?: boolean;
}): JSX.Element {
  const ctx = useSettings();
  const raw = ctx.prefs[prefKey];
  const value = (typeof raw === 'number' ? String(raw) : (raw as string | undefined)) ?? options[0]?.value ?? '';
  return (
    <Row id={id} label={label} help={help} prefKey={prefKey}>
      <Select
        ariaLabel={label}
        value={value as T}
        options={options}
        wide={wide}
        onChange={(v) => {
          const def = ctx.defaults[prefKey];
          void ctx.setPref(prefKey, typeof def === 'number' ? Number(v) : v);
        }}
      />
    </Row>
  );
}

export function Btn({
  kind = 'default',
  onClick,
  disabled,
  busy,
  children,
  title,
  small,
  type = 'button',
}: {
  kind?: 'default' | 'primary' | 'danger' | 'link' | 'ghost';
  onClick?: (e: MouseEvent) => void;
  disabled?: boolean;
  busy?: boolean;
  children: ComponentChildren;
  title?: string;
  small?: boolean;
  type?: 'button' | 'submit';
}): JSX.Element {
  return (
    <button
      type={type}
      class={`st-btn st-btn-${kind}${small ? ' is-small' : ''}${busy ? ' is-busy' : ''}`}
      disabled={disabled || busy}
      title={title}
      onClick={onClick}
    >
      {busy && <Spinner />}
      {children}
    </button>
  );
}

export function Spinner(): JSX.Element {
  return <span class="st-spinner" aria-hidden="true" />;
}

export function TextInput({
  value,
  onInput,
  placeholder,
  ariaLabel,
  type = 'text',
  invalid,
  onEnter,
  mono,
  autoFocus,
}: {
  value: string;
  onInput: (value: string) => void;
  placeholder?: string;
  ariaLabel: string;
  type?: 'text' | 'email' | 'password' | 'url';
  invalid?: boolean;
  onEnter?: () => void;
  mono?: boolean;
  autoFocus?: boolean;
}): JSX.Element {
  const ref = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (autoFocus) ref.current?.focus();
  }, [autoFocus]);
  return (
    <input
      ref={ref}
      class={`st-input${invalid ? ' is-invalid' : ''}${mono ? ' is-mono' : ''}`}
      type={type}
      value={value}
      placeholder={placeholder}
      aria-label={ariaLabel}
      aria-invalid={invalid ? 'true' : undefined}
      spellcheck={false}
      autocomplete="off"
      onInput={(e) => onInput((e.currentTarget as HTMLInputElement).value)}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && onEnter) {
          e.preventDefault();
          onEnter();
        }
      }}
    />
  );
}

export function Banner({
  tone = 'info',
  title,
  children,
  action,
}: {
  tone?: 'info' | 'warning' | 'danger' | 'success';
  title?: string;
  children?: ComponentChildren;
  action?: ComponentChildren;
}): JSX.Element {
  return (
    <div class={`st-banner st-banner-${tone}`} role={tone === 'danger' || tone === 'warning' ? 'alert' : 'status'}>
      <span class="st-banner-icon" aria-hidden="true">
        {tone === 'warning' || tone === 'danger' ? <WarningIcon size={15} /> : <InfoIcon size={15} />}
      </span>
      <div class="st-banner-body">
        {title && <div class="st-banner-title">{title}</div>}
        {children && <div class="st-banner-text">{children}</div>}
      </div>
      {action && <div class="st-banner-action">{action}</div>}
    </div>
  );
}

export function Pill({ tone = 'default', children }: { tone?: 'default' | 'accent' | 'success' | 'warning' | 'danger'; children: ComponentChildren }): JSX.Element {
  return <span class={`st-pill st-pill-${tone}`}>{children}</span>;
}

export function Keycaps({ keys, muted }: { keys: string; muted?: boolean }): JSX.Element {
  const caps = shortcutKeycaps(keys);
  if (!caps.length) return <span class="st-keycaps-empty">{muted ? '' : 'None'}</span>;
  return (
    <span class="st-keycaps" aria-label={caps.join(' ')}>
      {caps.map((cap, i) => (
        <kbd key={`${cap}-${i}`} class="st-keycap">
          {cap}
        </kbd>
      ))}
    </span>
  );
}

/** Records one key combination. Escape cancels; Backspace alone clears. */
export function KeyRecorder({
  value,
  onRecord,
  onCancel,
}: {
  value: string;
  onRecord: (keys: string) => void;
  onCancel: () => void;
}): JSX.Element {
  const [held, setHeld] = useState<string>('');
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === 'Escape') {
        onCancel();
        return;
      }
      if ((e.key === 'Backspace' || e.key === 'Delete') && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
        onRecord('');
        return;
      }
      const keys = shortcutFromKeyboardEvent(e);
      if (!keys) {
        const mods = isMacPlatform()
          ? [e.ctrlKey && '⌃', e.altKey && '⌥', e.shiftKey && '⇧', e.metaKey && '⌘'].filter(Boolean).join('')
          : [e.ctrlKey && 'Ctrl', e.altKey && 'Alt', e.shiftKey && 'Shift', e.metaKey && 'Super'].filter(Boolean).join('+');
        setHeld(mods);
        return;
      }
      // A bare letter is not a shortcut (it would swallow typing).
      if (!keys.includes('+') && !/^F\d{1,2}$/.test(keys)) {
        setHeld('Add a modifier key');
        return;
      }
      onRecord(keys);
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [onRecord, onCancel]);
  return (
    <span class="st-recorder" role="status" aria-live="polite">
      {held || (value ? 'Press new keys…' : 'Press keys…')}
    </span>
  );
}

export function ConfirmDialog({
  open,
  title,
  children,
  confirmLabel,
  danger,
  busy,
  confirmDisabled,
  onConfirm,
  onClose,
}: {
  open: boolean;
  title: string;
  children: ComponentChildren;
  confirmLabel: string;
  danger?: boolean;
  busy?: boolean;
  confirmDisabled?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}): JSX.Element | null {
  return (
    <Modal
      open={open}
      title={title}
      onClose={onClose}
      footer={
        <>
          <Btn onClick={onClose}>Cancel</Btn>
          <Btn kind={danger ? 'danger' : 'primary'} busy={busy} disabled={confirmDisabled} onClick={onConfirm}>
            {confirmLabel}
          </Btn>
        </>
      }
    >
      {children}
    </Modal>
  );
}

export function Field({ label, children, hint }: { label: string; children: ComponentChildren; hint?: ComponentChildren }): JSX.Element {
  return (
    <label class="st-field">
      <span class="st-field-label">{label}</span>
      {children}
      {hint && <span class="st-field-hint">{hint}</span>}
    </label>
  );
}

export function Checkbox({ checked, onChange, label, help, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: string; help?: string; disabled?: boolean }): JSX.Element {
  return (
    <label class={`st-check${disabled ? ' is-disabled' : ''}`}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange((e.currentTarget as HTMLInputElement).checked)} />
      <span class="st-check-box" aria-hidden="true" />
      <span class="st-check-text">
        <span>{label}</span>
        {help && <span class="st-check-help">{help}</span>}
      </span>
    </label>
  );
}

export function EmptyRow({ children }: { children: ComponentChildren }): JSX.Element {
  return <div class="st-empty-row">{children}</div>;
}

/** Highlights each search word in |text| with <mark>. */
export function Highlight({ text, words }: { text: string; words: string[] }): JSX.Element {
  if (!words.length) return <>{text}</>;
  const lower = text.toLowerCase();
  const marks: [number, number][] = [];
  for (const w of words) {
    if (!w) continue;
    let from = 0;
    for (;;) {
      const at = lower.indexOf(w, from);
      if (at < 0) break;
      marks.push([at, at + w.length]);
      from = at + w.length;
    }
  }
  if (!marks.length) return <>{text}</>;
  marks.sort((a, b) => a[0] - b[0]);
  const out: (string | JSX.Element)[] = [];
  let cursor = 0;
  for (const [start, end] of marks) {
    if (start < cursor) continue;
    if (start > cursor) out.push(text.slice(cursor, start));
    out.push(<mark key={start}>{text.slice(start, end)}</mark>);
    cursor = end;
  }
  if (cursor < text.length) out.push(text.slice(cursor));
  return <>{out}</>;
}
