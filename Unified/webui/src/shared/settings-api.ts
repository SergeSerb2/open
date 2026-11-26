// Types and method names of the Settings redesign RPCs
// (Unified/src/open_unified/ui/webui/open_settings_ui.cc kSettings* constants).
// bridge.ts merges them into RPC_METHODS, RpcRequestMap and RpcResponseMap.

import type {
  AdBlockState,
  ExtensionItem,
  ProfileSummary,
  RoutingDestination,
  RoutingRule,
  SpaceIcon,
  SpaceSummary,
  SyncDevice,
} from './bridge';

export const SETTINGS_RPC_METHODS = {
  settingsGetTheme: 'settings.getTheme',
  settingsOpenChromeUrl: 'settings.openChromeUrl',
  settingsPickFolder: 'settings.pickFolder',
  settingsPickDownloadFolder: 'settings.pickDownloadFolder',
  settingsExportSnapshot: 'settings.exportSnapshot',

  profilesList: 'settings.profiles.list',
  profilesSwitch: 'settings.profiles.switch',
  profilesCreate: 'settings.profiles.create',
  profilesRename: 'settings.profiles.rename',
  profilesSetIcon: 'settings.profiles.setIcon',
  profilesSetSearchEngine: 'settings.profiles.setSearchEngine',
  profilesSetCustomSearchEngines: 'settings.profiles.setCustomSearchEngines',
  profilesDelete: 'settings.profiles.delete',
  profilesCleanupUnused: 'settings.profiles.cleanupUnused',

  spacesList: 'settings.spaces.list',
  spacesCreate: 'settings.spaces.create',
  spacesRename: 'settings.spaces.rename',
  spacesSetProfile: 'settings.spaces.setProfile',

  atcGet: 'settings.atc.get',
  atcSetDefaultDestination: 'settings.atc.setDefaultDestination',
  atcAddRule: 'settings.atc.addRule',
  atcUpdateRule: 'settings.atc.updateRule',
  atcDeleteRule: 'settings.atc.deleteRule',
  atcReorderRules: 'settings.atc.reorderRules',
  atcListRunningApps: 'settings.atc.listRunningApps',
  atcTestUrl: 'settings.atc.testUrl',
  atcRecentDecisions: 'settings.atc.recentDecisions',

  shortcutsList: 'settings.shortcuts.list',
  shortcutsSet: 'settings.shortcuts.set',
  shortcutsClear: 'settings.shortcuts.clear',
  shortcutsReset: 'settings.shortcuts.reset',
  shortcutsResetAll: 'settings.shortcuts.resetAll',
  shortcutsSetPriority: 'settings.shortcuts.setPriority',
  shortcutsExportJson: 'settings.shortcuts.exportJson',
  shortcutsImportJson: 'settings.shortcuts.importJson',

  adblockGet: 'settings.adblock.get',
  adblockUpdateNow: 'settings.adblock.updateNow',
  adblockResetLists: 'settings.adblock.resetLists',
  adblockSetCustomRules: 'settings.adblock.setCustomRules',
  adblockCopyDebugInfo: 'settings.adblock.copyDebugInfo',
  adblockDetectConflicts: 'settings.adblock.detectConflictingExtensions',

  extensionsRemove: 'settings.extensions.remove',
  extensionsOpenOptions: 'settings.extensions.openOptions',

  syncGetDetailed: 'settings.sync.getStatus',
  syncSignIn: 'settings.sync.signIn',
  syncSignUp: 'settings.sync.signUp',
  syncSignOut: 'settings.sync.signOut',
  syncCompleteInitialSync: 'settings.sync.completeInitialSync',
  syncSyncNow: 'settings.sync.syncNow',
  syncChangePassword: 'settings.sync.changePassword',
  syncUpdateDisplayName: 'settings.sync.updateDisplayName',
  syncDeleteAccount: 'settings.sync.deleteAccount',
  syncRevokeDeviceDetailed: 'settings.sync.revokeDevice',
  syncSetServerUrl: 'settings.sync.setServerUrl',
  syncSetCategory: 'settings.sync.setCategory',
  syncRecoverDetailed: 'settings.sync.recover',

  importDetect: 'settings.import.detect',
  importPickHtml: 'settings.import.pickHtml',
  importRunDetailed: 'settings.import.run',
  importUndo: 'settings.import.undo',
  importReceipts: 'settings.import.receipts',

  aboutGet: 'settings.about.get',
  aboutShowDataFolder: 'settings.about.showDataFolder',
  aboutCopySystemInfo: 'settings.about.copySystemInfo',
  aboutCheckForUpdates: 'settings.about.checkForUpdates',
  aboutReplayOnboarding: 'settings.about.replayOnboarding',
} as const;

export type SettingsRpcMethod = (typeof SETTINGS_RPC_METHODS)[keyof typeof SETTINGS_RPC_METHODS];

// --- Theme ---------------------------------------------------------------------

/** The focused Space's accessible accent (WCAG AA on the Settings cards). */
export interface SettingsTheme {
  mode: 'light' | 'dark';
  preference: string;
  accent: string;
  accent_hover: string;
  accent_soft: string;
  on_accent: string;
  space_bg: string;
  contrast: number;
  space_id?: string;
  space_title?: string;
}

// --- Profiles & Spaces ------------------------------------------------------------

export interface ProfilesListResult {
  profiles: ProfileSummary[];
  active_profile_id: string;
  page_profile_id: string;
}

export interface ProfileSwitchResult {
  profile_id: string;
  profile: ProfileSummary;
  preferences: Record<string, unknown>;
  adblock: AdBlockState;
  extensions: ExtensionItem[];
}

export interface CleanupResult {
  profiles: { id: string; name: string }[];
  orphan_directories: string[];
  deleted: boolean;
}

export interface SettingsSpace extends SpaceSummary {
  accent: string;
  bg: string;
  display_title: string;
}

// --- Air Traffic Control ------------------------------------------------------------

export interface AtcState {
  rules: RoutingRule[];
  default_destination: RoutingDestination;
  default_destination_label: string;
  external_links_little_open: boolean;
  source_apps_supported: boolean;
  rule_id?: string;
}

export interface SourceApp {
  id: string;
  name: string;
}

export type RoutingOutcome =
  | 'matched'
  | 'disabled'
  | 'source_unknown'
  | 'source_mismatch'
  | 'host_mismatch'
  | 'path_mismatch'
  | 'space_missing'
  | 'profile_missing';

export interface RoutingTrace {
  index: number;
  rule_id: string;
  rule_name: string;
  outcome: RoutingOutcome;
}

export interface RoutingDecisionInfo {
  url: string;
  host?: string;
  source_app_id?: string;
  at: number;
  via: string;
  explanation: string;
  matched_rule_id?: string;
  matched_rule_name?: string;
  destination: RoutingDestination;
  destination_label: string;
  traces: RoutingTrace[];
}

// --- Shortcuts ------------------------------------------------------------------------

export type CommandPriority = 'browser' | 'site' | 'site-then-browser';

export interface ShortcutEntry {
  id: string;
  title: string;
  menu_title: string;
  category: string;
  menu: string;
  keys: string;
  all_keys: string[];
  default_keys: string;
  modified: boolean;
  customizable: boolean;
  global: boolean;
  priority: CommandPriority;
  default_priority: CommandPriority;
  aliases: string[];
  conflict_with?: string;
}

export interface ShortcutsState {
  shortcuts: ShortcutEntry[];
  priority: 'open' | 'website';
  counts: { modified: number; unassigned: number; conflicts: number };
  conflict?: string;
  ok?: boolean;
  canceled?: boolean;
  applied?: number;
  skipped?: number;
}

// --- Ad blocking ---------------------------------------------------------------------

export interface AdBlockConflict {
  id: string;
  name: string;
  enabled: boolean;
}

// --- Account & Sync ------------------------------------------------------------------

export interface SyncPendingExtension {
  profile_id: string;
  extension_id: string;
  name: string;
}

export interface SyncDetailedStatus {
  signed_in: boolean;
  state: string;
  status_message: string;
  email: string;
  display_name: string;
  server_url: string;
  device_id: string;
  device_name: string;
  last_sync_at_ms?: number;
  last_pulled_revision: number;
  pending_push_count: number;
  ws_connected: boolean;
  initial_sync_required: boolean;
  cloud_summary?: { server_revision: number; has_cloud_data: boolean; collection_counts: Record<string, number> };
  devices: SyncDevice[];
  categories: Record<string, boolean>;
  pending_extensions: SyncPendingExtension[];
  warnings: string[];
  is_busy: boolean;
  error_message?: string;
  devices_error?: string;
}

export interface SyncMutationResult {
  status: SyncDetailedStatus;
  recovery_key?: string;
  needs_initial_choice: boolean;
}

export type InitialSyncStrategy = 'merge' | 'use_server' | 'use_local';

// --- Import ----------------------------------------------------------------------------

export type ImportSourceKind = 'arc' | 'chromium' | 'firefox' | 'safari' | 'open_legacy' | 'html';

export interface ImportSource {
  id: string;
  kind: ImportSourceKind;
  browser_id: string;
  browser_name: string;
  profile_name: string;
  is_default: boolean;
  bookmarks_count: number;
  history_count: number;
  access_denied: boolean;
  access_error?: string;
  read_only: boolean;
}

export type ImportKind = 'bookmarks' | 'history' | 'spaces' | 'favorites' | 'archive' | 'boosts' | 'documents' | 'settings';

export interface ImportReceiptInfo {
  receipt_id: string;
  source_name: string;
  source_kind: string;
  imported_at: number;
  counts: Record<string, number>;
  undone: boolean;
}

export interface ImportRunResult {
  ok: boolean;
  receipt?: ImportReceiptInfo;
  access_denied?: boolean;
  error?: string;
}

// --- About -------------------------------------------------------------------------------

export interface AboutInfo {
  app_version: string;
  chromium_version: string;
  platform: string;
  os_version: string;
  architecture: string;
  data_folder: string;
  widevine: { session_enabled: boolean; preference: boolean; restart_required: boolean };
}

export interface UpdateCheckResult {
  status: 'unavailable' | 'up_to_date' | 'update_available' | 'checking' | 'error';
  current_version: string;
  message: string;
  latest_version?: string;
  release_url?: string;
  download_url?: string;
  release_notes?: string;
}

export interface FilePickResult {
  canceled: boolean;
  path?: string;
  name?: string;
  preferences?: Record<string, unknown>;
}

export interface FileWriteResult {
  ok: boolean;
  canceled?: boolean;
  path?: string;
}

// --- Request / response maps ------------------------------------------------------------

export interface CustomSearchEngineDraft {
  id?: string;
  name: string;
  keyword: string;
  url_template: string;
}

export interface SettingsRpcRequestMap {
  'settings.getTheme': Record<string, never>;
  'settings.openChromeUrl': { url: string };
  'settings.pickFolder': { title?: string; default_path?: string };
  'settings.pickDownloadFolder': { profile_id: string };
  'settings.exportSnapshot': { to_downloads?: boolean };

  'settings.profiles.list': Record<string, never>;
  'settings.profiles.switch': { profile_id: string };
  'settings.profiles.create': { name: string; icon?: SpaceIcon };
  'settings.profiles.rename': { profile_id: string; name: string; icon?: SpaceIcon };
  'settings.profiles.setIcon': { profile_id: string; icon: SpaceIcon };
  'settings.profiles.setSearchEngine': { profile_id: string; engine_id: string };
  'settings.profiles.setCustomSearchEngines': { profile_id: string; engines: CustomSearchEngineDraft[] };
  'settings.profiles.delete': { profile_id: string; confirm_name: string; move_spaces_to?: string };
  'settings.profiles.cleanupUnused': { dry_run: boolean };

  'settings.spaces.list': Record<string, never>;
  'settings.spaces.create': { profile_id: string; title: string };
  'settings.spaces.rename': { space_id: string; title: string };
  'settings.spaces.setProfile': { space_id: string; profile_id: string };

  'settings.atc.get': Record<string, never>;
  'settings.atc.setDefaultDestination': { destination: RoutingDestination };
  'settings.atc.addRule': { rule: RoutingRule };
  'settings.atc.updateRule': { rule: RoutingRule };
  'settings.atc.deleteRule': { id: string };
  'settings.atc.reorderRules': { ids: string[] };
  'settings.atc.listRunningApps': Record<string, never>;
  'settings.atc.testUrl': { url: string; source_app_id?: string };
  'settings.atc.recentDecisions': Record<string, never>;

  'settings.shortcuts.list': Record<string, never>;
  'settings.shortcuts.set': { id: string; keys: string };
  'settings.shortcuts.clear': { id: string };
  'settings.shortcuts.reset': { id: string };
  'settings.shortcuts.resetAll': Record<string, never>;
  'settings.shortcuts.setPriority': { id?: string; priority: string };
  'settings.shortcuts.exportJson': Record<string, never>;
  'settings.shortcuts.importJson': { json?: string };

  'settings.adblock.get': { profile_id: string };
  'settings.adblock.updateNow': { profile_id: string };
  'settings.adblock.resetLists': { profile_id: string };
  'settings.adblock.setCustomRules': { profile_id: string; rules: string };
  'settings.adblock.copyDebugInfo': { profile_id: string };
  'settings.adblock.detectConflictingExtensions': { profile_id: string };

  'settings.extensions.remove': { profile_id: string; id: string };
  'settings.extensions.openOptions': { profile_id: string; id: string };

  'settings.sync.getStatus': { refresh_devices?: boolean };
  'settings.sync.signIn': { server_url: string; email: string; password: string; strategy?: InitialSyncStrategy };
  'settings.sync.signUp': { server_url: string; email: string; password: string; display_name: string };
  'settings.sync.signOut': Record<string, never>;
  'settings.sync.completeInitialSync': { strategy: InitialSyncStrategy };
  'settings.sync.syncNow': Record<string, never>;
  'settings.sync.changePassword': { current_password: string; new_password: string; revoke_other_sessions: boolean };
  'settings.sync.updateDisplayName': { display_name: string };
  'settings.sync.deleteAccount': { password: string };
  'settings.sync.revokeDevice': { device_id: string };
  'settings.sync.setServerUrl': { server_url: string };
  'settings.sync.setCategory': { category: string; enabled: boolean };
  'settings.sync.recover': { server_url: string; email: string; recovery_key: string; new_password: string; strategy?: InitialSyncStrategy };

  'settings.import.detect': Record<string, never>;
  'settings.import.pickHtml': Record<string, never>;
  'settings.import.run': { source_id: string; kinds: ImportKind[]; target_profile_id?: string };
  'settings.import.undo': { receipt_id: string };
  'settings.import.receipts': Record<string, never>;

  'settings.about.get': Record<string, never>;
  'settings.about.showDataFolder': Record<string, never>;
  'settings.about.copySystemInfo': Record<string, never>;
  'settings.about.checkForUpdates': Record<string, never>;
  'settings.about.replayOnboarding': Record<string, never>;
}

export interface SettingsRpcResponseMap {
  'settings.getTheme': SettingsTheme;
  'settings.openChromeUrl': { ok: boolean };
  'settings.pickFolder': FilePickResult;
  'settings.pickDownloadFolder': FilePickResult;
  'settings.exportSnapshot': FileWriteResult;

  'settings.profiles.list': ProfilesListResult;
  'settings.profiles.switch': ProfileSwitchResult;
  'settings.profiles.create': { profile: ProfileSummary };
  'settings.profiles.rename': { profile: ProfileSummary };
  'settings.profiles.setIcon': { profile: ProfileSummary };
  'settings.profiles.setSearchEngine': { profile: ProfileSummary };
  'settings.profiles.setCustomSearchEngines': { profile: ProfileSummary };
  'settings.profiles.delete': { ok: boolean };
  'settings.profiles.cleanupUnused': CleanupResult;

  'settings.spaces.list': { spaces: SettingsSpace[] };
  'settings.spaces.create': { spaces: SettingsSpace[] };
  'settings.spaces.rename': { spaces: SettingsSpace[] };
  'settings.spaces.setProfile': { spaces: SettingsSpace[] };

  'settings.atc.get': AtcState;
  'settings.atc.setDefaultDestination': AtcState;
  'settings.atc.addRule': AtcState;
  'settings.atc.updateRule': AtcState;
  'settings.atc.deleteRule': AtcState;
  'settings.atc.reorderRules': AtcState;
  'settings.atc.listRunningApps': { apps: SourceApp[]; supported: boolean };
  'settings.atc.testUrl': RoutingDecisionInfo;
  'settings.atc.recentDecisions': { decisions: RoutingDecisionInfo[] };

  'settings.shortcuts.list': ShortcutsState;
  'settings.shortcuts.set': ShortcutsState;
  'settings.shortcuts.clear': ShortcutsState;
  'settings.shortcuts.reset': ShortcutsState;
  'settings.shortcuts.resetAll': ShortcutsState;
  'settings.shortcuts.setPriority': ShortcutsState;
  'settings.shortcuts.exportJson': FileWriteResult;
  'settings.shortcuts.importJson': ShortcutsState;

  'settings.adblock.get': AdBlockState;
  'settings.adblock.updateNow': AdBlockState;
  'settings.adblock.resetLists': AdBlockState;
  'settings.adblock.setCustomRules': AdBlockState;
  'settings.adblock.copyDebugInfo': { ok: boolean; text: string };
  'settings.adblock.detectConflictingExtensions': { conflicts: AdBlockConflict[] };

  'settings.extensions.remove': { profile_id: string; extensions: ExtensionItem[] };
  'settings.extensions.openOptions': { ok: boolean };

  'settings.sync.getStatus': SyncDetailedStatus;
  'settings.sync.signIn': SyncMutationResult;
  'settings.sync.signUp': SyncMutationResult;
  'settings.sync.signOut': SyncMutationResult;
  'settings.sync.completeInitialSync': SyncMutationResult;
  'settings.sync.syncNow': SyncMutationResult;
  'settings.sync.changePassword': SyncMutationResult;
  'settings.sync.updateDisplayName': SyncMutationResult;
  'settings.sync.deleteAccount': SyncMutationResult;
  'settings.sync.revokeDevice': SyncMutationResult;
  'settings.sync.setServerUrl': SyncDetailedStatus;
  'settings.sync.setCategory': SyncDetailedStatus;
  'settings.sync.recover': SyncMutationResult;

  'settings.import.detect': { sources: ImportSource[] };
  'settings.import.pickHtml': FilePickResult;
  'settings.import.run': ImportRunResult;
  'settings.import.undo': { ok: boolean; receipt: ImportReceiptInfo };
  'settings.import.receipts': { receipts: ImportReceiptInfo[] };

  'settings.about.get': AboutInfo;
  'settings.about.showDataFolder': { ok: boolean };
  'settings.about.copySystemInfo': { ok: boolean; text: string };
  'settings.about.checkForUpdates': UpdateCheckResult;
  'settings.about.replayOnboarding': { ok: boolean };
}
