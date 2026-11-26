import { createContext } from 'preact';
import { useContext } from 'preact/hooks';
import type { ProfileSummary, SettingsSnapshot, SettingsSpace, SettingsTheme } from '../shared/bridge';
import type { SectionId } from './sections';

export type ToastTone = 'default' | 'success' | 'danger';

export interface SettingsContext {
  snapshot: SettingsSnapshot | null;
  prefs: Record<string, unknown>;
  defaults: Record<string, unknown>;
  theme: SettingsTheme | null;
  /** The Profile the per-Profile panes edit (the Profile pill). */
  profileId: string;
  profile: ProfileSummary | undefined;
  profiles: ProfileSummary[];
  spaces: SettingsSpace[];
  setProfileId: (id: string) => void;
  reloadProfiles: () => Promise<void>;
  reloadSpaces: () => Promise<void>;
  setPref: (key: string, value: unknown, options?: { applyAll?: boolean }) => Promise<boolean>;
  resetPref: (key: string) => Promise<void>;
  isChanged: (key: string) => boolean;
  /** Updates preferences from an RPC reply (folder picker, profile switch). */
  applyPreferences: (prefs: Record<string, unknown>) => void;
  toast: (message: string, tone?: ToastTone) => void;
  navigate: (section: SectionId, row?: string) => void;
  pulsingRow: string | null;
  /** Runs an RPC; shows its error as a toast and returns null on failure. */
  run: <T>(task: () => Promise<T>, success?: string | ((value: T) => string | null)) => Promise<T | null>;
}

export const SettingsCtx = createContext<SettingsContext | null>(null);

export function useSettings(): SettingsContext {
  const ctx = useContext(SettingsCtx);
  if (!ctx) throw new Error('SettingsCtx is missing');
  return ctx;
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return typeof error === 'string' ? error : 'Something went wrong.';
}

/** "Just now", "5 minutes ago", "Yesterday", or a date. */
export function relativeTime(epochSeconds: number | undefined): string {
  if (!epochSeconds) return 'Never';
  const diff = Date.now() / 1000 - epochSeconds;
  if (diff < 45) return 'Just now';
  if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.round(diff / 3600)} h ago`;
  if (diff < 172800) return 'Yesterday';
  return new Date(epochSeconds * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

export function formatCount(n: number | undefined): string {
  return (n ?? 0).toLocaleString();
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${n.toLocaleString()} ${n === 1 ? one : many}`;
}
