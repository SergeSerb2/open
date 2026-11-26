// Row and reply shapes of the Library drawer's library.* methods
// (Unified/src/open_unified/ui/webui/open_library_ui.cc).

import type { Boost, ProfileSummary, SpaceIcon, SpaceStyle } from '../shared/bridge';

export type SectionId = 'media' | 'downloads' | 'easels' | 'spaces' | 'boosts' | 'archive' | 'history';

/** "all" merges every Profile; rows then carry their own profile_id. */
export type ProfileFilter = 'all' | (string & {});

export interface SpaceThemeVars {
  bg: string;
  fg: string;
  accent: string;
  surface: string;
  mode: 'light' | 'dark';
  space_id?: string;
}

export type DownloadState = 'in_progress' | 'paused' | 'completed' | 'cancelled' | 'interrupted';

export interface LibDownload {
  id: string;
  url: string;
  filename: string;
  target_path: string;
  mime_type: string;
  state: DownloadState;
  received_bytes: number;
  total_bytes: number;
  started_at: number;
  ended_at: number;
  profile_id: string;
  fileExists: boolean;
  bytesPerSecond: number;
  canResume: boolean;
  isLive: boolean;
  /** 0..1, or -1 when the size is unknown. */
  progress: number;
  host: string;
  thumb_url?: string;
}

export interface LibHistoryEntry {
  id: number;
  url: string;
  title: string;
  visit_count: number;
  typed_count: number;
  last_visit: number;
  profile_id: string;
  favicon_url: string;
  host: string;
  day_start: number;
}

export interface LibArchivedChild {
  id: string;
  url: string;
  title: string;
  host: string;
  favicon_url: string;
}

export interface LibArchiveItem {
  id: string;
  url: string;
  title: string;
  space_id?: string;
  space_title?: string;
  profile_id: string;
  archived_at: number;
  reason: string;
  original_location: string;
  kind: 'tab' | 'folder';
  favicon_url: string;
  host: string;
  day_start: number;
  child_count?: number;
  children?: LibArchivedChild[];
}

export type MediaSource = 'capture' | 'download' | 'folder';

export interface LibMediaItem {
  id: string;
  title: string;
  source: MediaSource;
  source_url: string;
  folder: string;
  path: string;
  kind: 'image' | 'video';
  ext: string;
  captured_at: number;
  size: number;
  file_url: string;
  thumb_url?: string;
  profile_id: string;
}

export interface LibSpace {
  id: string;
  title: string;
  icon: SpaceIcon;
  profile_id: string;
  style: SpaceStyle;
  pinned_count: number;
  today_count: number;
  profile_name?: string;
  is_active?: boolean;
  theme?: SpaceThemeVars;
}

export interface LibDocument {
  id: string;
  kind: 'easel' | 'note';
  title: string;
  element_count?: number;
  modified_at: number;
  url: string;
  profile_id: string;
}

export type LibBoost = Boost;

// --- Method map: [request, reply] ---------------------------------------------

type Ok = { ok: boolean };
type WithProfile = { profile_id?: ProfileFilter };

export interface LibraryRpcMap {
  'library.close': [{ window_id?: string }, Ok & { closed_tab?: boolean }];
  'library.theme.get': [{ window_id?: string; space_id?: string }, { theme: SpaceThemeVars; system_dark: boolean }];

  'library.history.list': [
    WithProfile & { query?: string; offset?: number; limit?: number },
    { entries: LibHistoryEntry[]; offset: number; has_more: boolean },
  ];
  'library.history.delete': [{ profile_id: string; ids?: number[]; urls?: string[] }, Ok & { remaining: number }];
  'library.history.clear': [
    WithProfile & { range: 'lastHour' | 'today' | 'last7Days' | 'all' },
    Ok & { remaining: number },
  ];

  'library.archive.list': [WithProfile & { query?: string }, { items: LibArchiveItem[] }];
  'library.archive.restore': [
    { id: string; profile_id: string; window_id?: string },
    Ok & { restored_id: string; restored_url: string; kind: string },
  ];
  'library.archive.delete': [{ profile_id: string; ids: string[] }, Ok];
  'library.archive.clearAll': [WithProfile, Ok];
  'library.archive.peek': [{ url: string; window_id?: string }, Ok];

  'library.downloads.list': [WithProfile & { query?: string; limit?: number }, { downloads: LibDownload[]; live_bridge: boolean }];
  'library.downloads.pause': [{ id: string; profile_id: string }, Ok];
  'library.downloads.resume': [{ id: string; profile_id: string }, Ok];
  'library.downloads.cancel': [{ id: string; profile_id: string }, Ok];
  'library.downloads.retry': [{ id: string; profile_id: string }, Ok];
  'library.downloads.open': [{ id: string; profile_id: string }, Ok];
  'library.downloads.reveal': [{ id: string; profile_id: string }, Ok];
  'library.downloads.trash': [{ id: string; profile_id: string }, Ok];
  'library.downloads.remove': [{ id: string; profile_id: string }, Ok];
  'library.downloads.clear': [WithProfile, Ok & { removed?: number }];

  'library.media.list': [WithProfile & { query?: string; source?: MediaSource | 'all' }, { items: LibMediaItem[]; folders: string[] }];
  'library.media.addFolder': [{ profile_id?: string; preset?: string; path?: string }, Ok];
  'library.media.removeFolder': [{ profile_id?: string; path: string }, Ok];
  'library.media.open': [{ id: string }, Ok];
  'library.media.reveal': [{ id: string }, Ok];
  'library.media.copyImage': [{ id: string }, Ok];
  'library.media.delete': [{ id: string }, Ok];

  'library.spaces.list': [WithProfile & { window_id?: string }, { spaces: LibSpace[]; active_space_id: string }];
  'library.spaces.create': [{ profile_id?: string; title?: string; icon?: SpaceIcon; focus?: boolean }, { space: LibSpace }];
  'library.spaces.update': [{ id: string; title?: string; icon?: SpaceIcon; style?: SpaceStyle }, { space: LibSpace }];
  'library.spaces.delete': [{ id: string }, Ok];
  'library.spaces.switch': [{ id: string; window_id?: string; close?: boolean }, Ok];
  'library.spaces.reorder': [{ ids: string[] }, Ok];

  'library.boosts.list': [WithProfile & { query?: string }, { boosts: LibBoost[] }];
  'library.documents.list': [WithProfile & { query?: string }, { easels: LibDocument[]; notes: LibDocument[] }];
  'library.documents.create': [{ kind: 'easel' | 'note'; profile_id?: string; open?: boolean }, { id: string; url: string }];
  'library.documents.delete': [{ kind: 'easel' | 'note'; id: string; profile_id: string }, Ok];

  'library.openUrl': [{ url: string; new_tab?: boolean; background?: boolean; close_library?: boolean }, Ok];

  // Shared domains registered on open://library (open_boosts_ui.cc,
  // open_settings_ui.cc); profile_id selects the row's Profile.
  'boosts.list': [{ profile_id?: string }, { boosts: LibBoost[]; global_enabled: boolean }];
  'boosts.toggle': [{ id: string; enabled: boolean; profile_id?: string }, { boost: LibBoost }];
  'boosts.delete': [{ id: string; profile_id?: string }, Ok];
  'settings.setPreference': [{ key: string; value: unknown; profile_id?: string }, unknown];
  'settings.listProfiles': [Record<string, never>, { profiles: ProfileSummary[] }];
}

export type LibraryMethod = keyof LibraryRpcMap;
export type LibReq<M extends LibraryMethod> = LibraryRpcMap[M][0];
export type LibRes<M extends LibraryMethod> = LibraryRpcMap[M][1];
