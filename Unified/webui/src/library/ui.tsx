// Drawer building blocks: rows, day headings, hover buttons, menus, sheets,
// chips, empty states, the Escape stack and keyboard row navigation.

import type { ComponentChildren, JSX } from 'preact';
import { Fragment, createContext } from 'preact';
import { useContext, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { isMacPlatform } from '../shared/shortcuts';
import { CheckGlyph } from './icons';

// --- Formatting -----------------------------------------------------------------

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '';
  if (n < 1000) return `${Math.round(n)} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1000;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function formatClock(sec: number): string {
  return new Date(sec * 1000).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function startOfDay(sec: number): number {
  const d = new Date(sec * 1000);
  d.setHours(0, 0, 0, 0);
  return d.getTime() / 1000;
}

/** "Today", "Yesterday", "Mon, Nov 24" (+ year when not this year). */
export function dayLabel(sec: number): string {
  const day = startOfDay(sec);
  const today = startOfDay(Date.now() / 1000);
  if (day === today) return 'Today';
  if (Math.round((today - day) / 86400) === 1) return 'Yesterday';
  const d = new Date(day * 1000);
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    ...(sameYear ? {} : { year: 'numeric' }),
  });
}

/** Rows of a time-sorted list with a heading before each new day. */
export function groupByDay<T>(items: T[], time: (item: T) => number): { day: string; items: T[] }[] {
  const groups: { day: string; items: T[] }[] = [];
  for (const item of items) {
    const label = dayLabel(time(item));
    const last = groups[groups.length - 1];
    if (last && last.day === label) last.items.push(item);
    else groups.push({ day: label, items: [item] });
  }
  return groups;
}

export const revealLabel = (): string => (isMacPlatform() ? 'Show in Finder' : 'Show in Folder');
export const modKey = (): string => (isMacPlatform() ? '⌘' : 'Ctrl+');

// --- Escape stack ---------------------------------------------------------------
//
// Escape closes the innermost thing first: a menu, then a sheet, then the
// filter editor, then search, then the Library.

const escapeStack: (() => void)[] = [];

export function useEscape(active: boolean, handler: () => void): void {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    if (!active) return;
    const entry = () => ref.current();
    escapeStack.push(entry);
    return () => {
      const i = escapeStack.lastIndexOf(entry);
      if (i >= 0) escapeStack.splice(i, 1);
    };
  }, [active]);
}

export function popEscape(): boolean {
  const top = escapeStack[escapeStack.length - 1];
  if (!top) return false;
  top();
  return true;
}

export function overlayOpen(): boolean {
  return escapeStack.length > 0;
}

// --- Keyboard row navigation ------------------------------------------------------

export interface NavRow {
  key: string;
  activate: () => void;
  remove?: () => void;
}

export interface NavState {
  focusKey: string | null;
  keyboard: boolean;
  setFocusKey: (key: string | null) => void;
  setRows: (rows: NavRow[]) => void;
}

export const NavContext = createContext<NavState>({
  focusKey: null,
  keyboard: false,
  setFocusKey: () => {},
  setRows: () => {},
});

/** Publishes a section's rows (in visual order) for arrow-key navigation. */
export function useNavRows(rows: NavRow[]): void {
  const nav = useContext(NavContext);
  useEffect(() => {
    nav.setRows(rows);
  });
}

// --- Rows -----------------------------------------------------------------------

export function DayHeading({ label }: { label: string }): JSX.Element {
  return (
    <div class="lib-heading" role="heading" aria-level={3}>
      {label}
    </div>
  );
}

export interface RowProps {
  navKey: string;
  icon: ComponentChildren;
  title: string;
  subtitle?: ComponentChildren;
  /** Right-side content while not hovered (time chip, badge). */
  trailing?: ComponentChildren;
  /** Hover buttons (IconButton). */
  actions?: ComponentChildren;
  progress?: boolean;
  indent?: number;
  dim?: boolean;
  onClick?: (e: MouseEvent) => void;
  onDblClick?: () => void;
  onContextMenu?: (e: MouseEvent) => void;
  ariaLabel?: string;
}

export function Row(props: RowProps): JSX.Element {
  const nav = useContext(NavContext);
  const focused = nav.focusKey === props.navKey;
  return (
    <div
      class={`lib-row${focused ? ' is-selected' : ''}${focused && nav.keyboard ? ' is-focus' : ''}${props.progress ? ' has-progress' : ''}${props.dim ? ' is-dim' : ''}`}
      data-nav-key={props.navKey}
      role="option"
      aria-selected={focused}
      aria-label={props.ariaLabel ?? props.title}
      style={props.indent ? { paddingLeft: `${props.indent}px` } : undefined}
      onMouseDown={() => nav.setFocusKey(props.navKey)}
      onClick={(e) => props.onClick?.(e as unknown as MouseEvent)}
      onDblClick={() => props.onDblClick?.()}
      onContextMenu={(e) => {
        if (props.onContextMenu) {
          e.preventDefault();
          props.onContextMenu(e as unknown as MouseEvent);
        }
      }}
    >
      <div class="lib-row-plate" />
      <div class="lib-row-icon">{props.icon}</div>
      <div class="lib-row-text">
        <div class="lib-row-title">{props.title}</div>
        {props.subtitle !== undefined && <div class="lib-row-sub">{props.subtitle}</div>}
      </div>
      {props.trailing !== undefined && <div class="lib-row-trailing">{props.trailing}</div>}
      {props.actions !== undefined && (
        <div class="lib-row-actions" onClick={(e) => e.stopPropagation()} onDblClick={(e) => e.stopPropagation()}>
          {props.actions}
        </div>
      )}
    </div>
  );
}

export function IconButton({
  label,
  onClick,
  children,
  danger,
  disabled,
  active,
  class: className,
}: {
  label: string;
  onClick: (e: MouseEvent) => void;
  children: ComponentChildren;
  danger?: boolean;
  disabled?: boolean;
  active?: boolean;
  class?: string;
}): JSX.Element {
  return (
    <button
      type="button"
      class={`lib-icon-btn${danger ? ' is-danger' : ''}${active ? ' is-active' : ''}${className ? ` ${className}` : ''}`}
      title={label}
      aria-label={label}
      disabled={disabled}
      onClick={(e) => {
        e.stopPropagation();
        onClick(e as unknown as MouseEvent);
      }}
    >
      {children}
    </button>
  );
}

// --- Favicons -------------------------------------------------------------------

const failedFavicons = new Set<string>();

export function Favicon({ src, host, size = 20 }: { src: string; host: string; size?: number }): JSX.Element {
  const [failed, setFailed] = useState(!src || failedFavicons.has(src));
  if (failed) {
    const letter = (host || '?').replace(/^www\./, '').charAt(0).toUpperCase() || '?';
    return (
      <span class="lib-monogram" style={{ width: `${size}px`, height: `${size}px`, fontSize: `${Math.round(size * 0.55)}px` }} aria-hidden="true">
        {letter}
      </span>
    );
  }
  return (
    <img
      class="lib-favicon"
      src={src}
      width={size}
      height={size}
      alt=""
      loading="lazy"
      decoding="async"
      onError={() => {
        failedFavicons.add(src);
        setFailed(true);
      }}
    />
  );
}

// --- Menus ------------------------------------------------------------------------

export interface MenuItem {
  label: string;
  icon?: ComponentChildren;
  danger?: boolean;
  disabled?: boolean;
  checked?: boolean;
  separatorBefore?: boolean;
  onSelect: () => void;
}

export interface MenuAnchor {
  x: number;
  y: number;
}

export function anchorOf(e: MouseEvent): MenuAnchor {
  const el = e.currentTarget as HTMLElement | null;
  if (el && e.type === 'click') {
    const r = el.getBoundingClientRect();
    return { x: r.right, y: r.bottom + 4 };
  }
  return { x: e.clientX, y: e.clientY };
}

export function Menu({
  anchor,
  items,
  onClose,
  label,
}: {
  anchor: MenuAnchor;
  items: MenuItem[];
  onClose: () => void;
  label: string;
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: anchor.x, top: anchor.y });
  const [active, setActive] = useState(-1);
  useEscape(true, onClose);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const left = Math.max(6, Math.min(anchor.x - w, window.innerWidth - w - 6));
    const top = anchor.y + h > window.innerHeight - 6 ? Math.max(6, anchor.y - h - 8) : anchor.y;
    setPos({ left, top });
    el.focus();
  }, [anchor.x, anchor.y]);

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    window.addEventListener('mousedown', onDown, true);
    return () => window.removeEventListener('mousedown', onDown, true);
  }, [onClose]);

  const enabled = items.map((it, i) => (it.disabled ? -1 : i)).filter((i) => i >= 0);
  return (
    <div
      ref={ref}
      class="lib-menu"
      role="menu"
      aria-label={label}
      tabIndex={-1}
      style={{ left: `${pos.left}px`, top: `${pos.top}px` }}
      onKeyDown={(e) => {
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          e.stopPropagation();
          const at = enabled.indexOf(active);
          const next = e.key === 'ArrowDown' ? enabled[(at + 1) % enabled.length] : enabled[(at - 1 + enabled.length) % enabled.length];
          setActive(next ?? -1);
        } else if (e.key === 'Enter' && active >= 0) {
          e.preventDefault();
          e.stopPropagation();
          const item = items[active];
          onClose();
          item?.onSelect();
        }
      }}
    >
      {items.map((item, i) => (
        <Fragment key={`${i}:${item.label}`}>
          {item.separatorBefore && <div class="lib-menu-sep" role="separator" />}
          <button
            type="button"
            role="menuitem"
            class={`lib-menu-item${item.danger ? ' is-danger' : ''}${active === i ? ' is-active' : ''}`}
            disabled={item.disabled}
            onMouseEnter={() => setActive(i)}
            onClick={() => {
              onClose();
              item.onSelect();
            }}
          >
            <span class="lib-menu-icon">{item.checked ? <CheckGlyph size={13} /> : item.icon}</span>
            <span>{item.label}</span>
          </button>
        </Fragment>
      ))}
    </div>
  );
}

/** One open menu at a time per section. */
export function useMenu(): {
  menu: { anchor: MenuAnchor; items: MenuItem[]; label: string } | null;
  openMenu: (e: MouseEvent, label: string, items: MenuItem[]) => void;
  closeMenu: () => void;
} {
  const [menu, setMenu] = useState<{ anchor: MenuAnchor; items: MenuItem[]; label: string } | null>(null);
  return {
    menu,
    openMenu: (e, label, items) => setMenu({ anchor: anchorOf(e), items, label }),
    closeMenu: () => setMenu(null),
  };
}

// --- Sheets -----------------------------------------------------------------------

export function Sheet({
  title,
  children,
  onClose,
  footer,
  wide,
}: {
  title: string;
  children: ComponentChildren;
  onClose: () => void;
  footer: ComponentChildren;
  wide?: boolean;
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null);
  useEscape(true, onClose);
  useEffect(() => {
    const el = ref.current;
    const first = el?.querySelector<HTMLElement>('[data-autofocus], input, button.lib-btn-primary, button');
    first?.focus();
  }, []);
  return (
    <div
      class="lib-sheet-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div ref={ref} class={`lib-sheet${wide ? ' is-wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <h2 class="lib-sheet-title">{title}</h2>
        <div class="lib-sheet-body">{children}</div>
        <div class="lib-sheet-footer">{footer}</div>
      </div>
    </div>
  );
}

export interface ConfirmRequest {
  title: string;
  body?: string;
  confirm: string;
  danger?: boolean;
  run: () => Promise<void> | void;
}

export function ConfirmSheet({ request, onClose }: { request: ConfirmRequest; onClose: () => void }): JSX.Element {
  const [busy, setBusy] = useState(false);
  return (
    <Sheet
      title={request.title}
      onClose={onClose}
      footer={
        <>
          <button type="button" class="lib-btn" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            class={`lib-btn ${request.danger ? 'lib-btn-danger' : 'lib-btn-primary'}`}
            data-autofocus
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              try {
                await request.run();
              } finally {
                setBusy(false);
                onClose();
              }
            }}
          >
            {request.confirm}
          </button>
        </>
      }
    >
      {request.body && <p class="lib-sheet-text">{request.body}</p>}
    </Sheet>
  );
}

// --- Chips, segmented controls, empty state ---------------------------------------

export function Chip({
  selected,
  onClick,
  children,
  label,
}: {
  selected?: boolean;
  onClick: () => void;
  children: ComponentChildren;
  label?: string;
}): JSX.Element {
  return (
    <button type="button" class={`lib-chip${selected ? ' is-selected' : ''}`} aria-pressed={selected} aria-label={label} onClick={onClick}>
      {children}
    </button>
  );
}

export function EmptyState({
  icon,
  title,
  body,
  action,
}: {
  icon: ComponentChildren;
  title: string;
  body: string;
  action?: { label: string; onClick: () => void };
}): JSX.Element {
  return (
    <div class="lib-empty" role="status">
      <div class="lib-empty-icon">{icon}</div>
      <div class="lib-empty-title">{title}</div>
      <div class="lib-empty-body">{body}</div>
      {action && (
        <button type="button" class="lib-btn" onClick={action.onClick}>
          {action.label}
        </button>
      )}
    </div>
  );
}

export function Skeleton({ rows = 6 }: { rows?: number }): JSX.Element {
  return (
    <div class="lib-skeleton" aria-hidden="true">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} class="lib-skeleton-row">
          <span class="lib-skeleton-icon" />
          <span class="lib-skeleton-lines">
            <span style={{ width: `${70 - (i % 3) * 12}%` }} />
            <span style={{ width: `${45 - (i % 2) * 10}%` }} />
          </span>
        </div>
      ))}
    </div>
  );
}

/** Shows plain skeleton plates only when loading takes longer than 120 ms. */
export function useSlowFlag(loading: boolean, ms = 120): boolean {
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    if (!loading) {
      setSlow(false);
      return;
    }
    const t = window.setTimeout(() => setSlow(true), ms);
    return () => window.clearTimeout(t);
  }, [loading]);
  return slow;
}

/** Shared props of every section component. */
export interface SectionProps {
  profileId: string;
  query: string;
  profileNames: Record<string, string>;
  multiProfile: boolean;
  drawer: boolean;
  /** Bumped by the App when data may have changed (push events). */
  refreshKey: number;
  toast: (message: string) => void;
  confirm: (request: ConfirmRequest) => void;
  closeLibrary: () => void;
  filterOpen: boolean;
  setFilterActive: (active: boolean) => void;
}
