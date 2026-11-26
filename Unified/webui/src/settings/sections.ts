// The 15 Settings panes, their rail groups, and the search index
// (labels, help, hidden aliases such as Arc's old names, preference keys).

import type { JSX } from 'preact';
import {
  AppearanceIcon,
  CloudIcon,
  ExtensionsIcon,
  GeneralIcon,
  ImportIcon,
  InfoIcon,
  KeyboardIcon,
  KeyIcon,
  LinkIcon,
  LockIcon,
  PersonIcon,
  ShieldLineIcon,
  SlidersIcon,
  SpacesIcon,
  TabsIcon,
} from '../shared/icons';

export type SectionId =
  | 'general'
  | 'profiles'
  | 'spaces'
  | 'links'
  | 'appearance'
  | 'tabs'
  | 'shortcuts'
  | 'extensions'
  | 'privacy'
  | 'adblock'
  | 'passwords'
  | 'sync'
  | 'import'
  | 'advanced'
  | 'about';

export type SectionGroup = 'BROWSING' | 'PRIVACY' | 'OPEN';

export interface SectionDef {
  id: SectionId;
  title: string;
  subtitle: string;
  group: SectionGroup;
  icon: (props: { size?: number }) => JSX.Element;
  /** Shows the Profile pill: the pane edits one Profile's settings. */
  perProfile?: boolean;
}

export const SECTIONS: readonly SectionDef[] = [
  { id: 'general', title: 'General', subtitle: 'How Open starts, updates, and fits into your computer.', group: 'BROWSING', icon: GeneralIcon, perProfile: true },
  { id: 'profiles', title: 'Profiles', subtitle: 'Separate your data across Spaces.', group: 'BROWSING', icon: PersonIcon, perProfile: true },
  { id: 'spaces', title: 'Spaces', subtitle: 'Your Spaces, their colors, and their Profiles.', group: 'BROWSING', icon: SpacesIcon },
  { id: 'links', title: 'Links', subtitle: 'Choose where links open.', group: 'BROWSING', icon: LinkIcon },
  { id: 'appearance', title: 'Appearance', subtitle: 'The window, the sidebar, and the app icon.', group: 'BROWSING', icon: AppearanceIcon },
  { id: 'tabs', title: 'Tabs', subtitle: 'Keep the tabs you need. Let the rest make room.', group: 'BROWSING', icon: TabsIcon, perProfile: true },
  { id: 'shortcuts', title: 'Shortcuts', subtitle: 'Type a name, or press keys to find what they do.', group: 'BROWSING', icon: KeyboardIcon },
  { id: 'extensions', title: 'Extensions', subtitle: 'Add tools to your browser.', group: 'BROWSING', icon: ExtensionsIcon, perProfile: true },
  { id: 'privacy', title: 'Privacy & Security', subtitle: 'Control what websites can use and what Open keeps.', group: 'PRIVACY', icon: LockIcon, perProfile: true },
  { id: 'adblock', title: 'Ad Blocker', subtitle: 'Block lists and allowed sites for this Profile.', group: 'PRIVACY', icon: ShieldLineIcon, perProfile: true },
  { id: 'passwords', title: 'Passwords & Autofill', subtitle: 'Saved passwords, payment methods, and addresses.', group: 'PRIVACY', icon: KeyIcon },
  { id: 'sync', title: 'Account & Sync', subtitle: 'End-to-end encrypted sync for your Open browser setup.', group: 'OPEN', icon: CloudIcon },
  { id: 'import', title: 'Import', subtitle: 'Bring your Spaces, tabs, bookmarks, and history into Open.', group: 'OPEN', icon: ImportIcon },
  { id: 'advanced', title: 'Advanced', subtitle: 'The details that make Open yours.', group: 'OPEN', icon: SlidersIcon },
  { id: 'about', title: 'About', subtitle: 'Version, engine, and diagnostics.', group: 'OPEN', icon: InfoIcon },
];

export const SECTION_BY_ID: Record<SectionId, SectionDef> = Object.fromEntries(SECTIONS.map((s) => [s.id, s])) as Record<
  SectionId,
  SectionDef
>;

/** Old open://settings/<section> links (Swift Open and earlier Unified builds). */
export const LEGACY_SECTIONS: Record<string, { section: SectionId; row?: string }> = {
  'tabs-archive': { section: 'tabs' },
  search: { section: 'profiles', row: 'profiles/search-engine' },
  downloads: { section: 'general', row: 'general/download-location' },
  previews: { section: 'appearance', row: 'appearance/previews' },
  'ad-blocking': { section: 'adblock' },
  'site-permissions': { section: 'privacy', row: 'privacy/site-permissions' },
  'passwords-cards': { section: 'passwords' },
  'browsing-data': { section: 'privacy', row: 'privacy/clear-data' },
  'account-sync': { section: 'sync' },
};

export function isSectionId(value: string | undefined): value is SectionId {
  return !!value && value in SECTION_BY_ID;
}

export interface SearchEntry {
  /** "section/row": also the DOM id of the row (row-<section>-<row>). */
  id: string;
  section: SectionId;
  label: string;
  help?: string;
  /** Hidden search words, including Arc's old names. */
  aliases?: string;
  /** The preference this row edits (is:changed + Reset). */
  prefKey?: string;
}

const e = (section: SectionId, row: string, label: string, help = '', aliases = '', prefKey?: string): SearchEntry => {
  const entry: SearchEntry = { id: `${section}/${row}`, section, label };
  if (help) entry.help = help;
  if (aliases) entry.aliases = aliases;
  if (prefKey) entry.prefKey = prefKey;
  return entry;
};

export const SEARCH_INDEX: readonly SearchEntry[] = [
  e('general', 'default-browser', 'Make Open your default browser', 'Links from other apps will open here.', 'default app handler'),
  e('general', 'restore-windows', 'Restore windows from the previous session', '', 'startup reopen session', 'general.restoreWindows'),
  e('general', 'warn-before-quitting', 'Warn before quitting', 'Ask before quitting with downloads in progress.', 'quit confirm', 'general.warnBeforeQuitting'),
  e('general', 'automatic-updates', 'Update Open automatically', 'Keep Open up to date.', 'updates sparkle', 'general.automaticUpdates'),
  e('general', 'download-location', 'Download location', 'Where this Profile saves your files.', 'downloads folder save', 'downloads.location'),
  e('general', 'ask-each-file', 'Ask where to save each file', '', 'downloads prompt', 'downloads.askEachTime'),
  e('general', 'translate', 'Offer to translate pages', 'Show a prompt for pages in other languages.', 'translate language', 'general.offerTranslate'),
  e('general', 'app-icon', 'App icon', 'Choose one of six original Open icons.', 'dock icon taskbar', 'appearance.appIcon'),
  e('general', 'export', 'Export your Open data', 'Save a snapshot of Spaces, Favorites, settings, and shortcuts.', 'backup snapshot json'),

  e('profiles', 'manage', 'Your Profiles', 'Create, rename, change an icon, or delete a Profile.', 'profile accounts'),
  e('profiles', 'search-engine', 'Search engine', 'The default search engine for this Profile.', 'google duckduckgo kagi bing', 'search.engine'),
  e('profiles', 'search-suggestions', 'Include search engine suggestions', 'We talk to your search engine to help suggest results.', 'autocomplete', 'search.suggestions'),
  e('profiles', 'custom-engines', 'Custom search engines', 'Add, edit, or remove keyword search engines.', 'bangs keyword site search'),
  e('profiles', 'new-documents', 'New documents', 'What New Note creates.', 'note google doc notion', 'profiles.newDocuments'),
  e('profiles', 'cleanup', 'Delete unused Profiles', 'Remove Profiles that have no Spaces.', 'cleanup'),

  e('spaces', 'list', 'Your Spaces', 'Theme, Profile, and name of each Space.', 'workspace theme color'),
  e('spaces', 'new', 'New Space', '', 'create space'),

  e('links', 'little-open-hotkey', 'Open Little Open in any app', 'A global shortcut for a quick window.', 'Little Arc global hotkey', 'links.littleOpenHotkey'),
  e('links', 'option-command-click', 'Open Little Open with Option-Command-click', '', 'Little Arc modifier click', 'links.optionCommandClick'),
  e('links', 'external-links', 'Links from other apps open in Little Open', '', 'Little Arc external', 'links.externalLinksLittleOpen'),
  e('links', 'peek-shift-click', 'Open Peek with Shift-click', '', 'preview overlay', 'links.peekShiftClick'),
  e('links', 'peek-other-sites', 'Open Peek for links to other sites', 'Applies to Favorites and Pinned tabs.', 'preview overlay', 'links.peekOtherSites'),
  e('links', 'destination', 'Default destination', 'Where links open when no rule matches.', 'routing Air Traffic Control'),
  e('links', 'rules', 'Air Traffic Control', 'Send sites to a Space, a Profile, or Little Open.', 'ATC routing rules'),
  e('links', 'test', 'Test a Link', 'See which rule a link matches.', 'ATC trace'),
  e('links', 'recent', 'Recent routing decisions', '', 'ATC log history'),

  e('appearance', 'theme', 'Theme', 'Light, Dark, or Match System for Open and websites.', 'dark mode color scheme website appearance', 'appearance.websiteAppearance'),
  e('appearance', 'sidebar-position', 'Sidebar position', '', 'left right', 'appearance.sidebarPosition'),
  e('appearance', 'sidebar-autohide', 'Hide the sidebar automatically', 'Show it when the pointer reaches the edge.', 'collapse', 'appearance.sidebarAutoHide'),
  e('appearance', 'translucency', 'Translucent window', 'Let the desktop show through the sidebar.', 'vibrancy blur', 'appearance.translucency'),
  e('appearance', 'contrast', 'Increase contrast', '', 'accessibility', 'appearance.increaseContrast'),
  e('appearance', 'toolbar', 'Show the toolbar', 'The address and page controls above each page.', 'url bar', 'appearance.toolbar'),
  e('appearance', 'full-url', 'Show the full URL', 'Show the full address when the toolbar is on.', 'address', 'appearance.fullUrl'),
  e('appearance', 'font-size', 'Font size', '', 'text size', 'appearance.fontSize'),
  e('appearance', 'zoom', 'Page zoom', '', 'zoom default', 'appearance.defaultZoom'),
  e('appearance', 'previews', 'Show Open Previews', 'Preview folders and pages on hover.', 'hover cards', 'previews.enabled'),
  e('appearance', 'previews-calendar', 'Upcoming meetings', 'Google, Outlook, and Notion Calendar.', 'join meeting', 'previews.calendar'),

  e('tabs', 'archive-after', 'Archive tabs after', 'Today tabs you have not used move to the Archive.', 'auto-archive timer', 'tabs.archiveAfter'),
  e('tabs', 'little-open-archive', 'Archive Little Open windows after', '', 'Little Arc', 'tabs.littleOpenArchiveAfter'),
  e('tabs', 'sleep', 'Sleep inactive tabs', 'Sleeping tabs stay in the sidebar.', 'memory saver discard', 'tabs.sleepMode'),
  e('tabs', 'include-favorites', 'Include Favorites in tab numbering', '', 'shortcut', 'tabs.includeFavoritesInSwitcher'),
  e('tabs', 'ninth-tab', 'Ninth tab shortcut goes to the last tab', '', 'shortcut', 'tabs.ninthTabGoesToLast'),
  e('tabs', 'split', 'Split View direction', '', 'split screen', 'tabs.splitOrientation'),

  e('shortcuts', 'list', 'Keyboard shortcuts', 'Rebind, clear, or reset any command.', 'hotkeys keybindings'),
  e('shortcuts', 'priority', 'When shortcuts overlap', 'Prefer Open or the website.', 'conflict priority', 'shortcuts.priority'),
  e('shortcuts', 'import-export', 'Import or export shortcuts', '', 'json backup'),

  e('extensions', 'manage', 'Manage Extensions', 'Pin, turn off, or remove extensions.', 'chrome web store addons'),

  e('privacy', 'site-permissions', 'Site Permissions', 'Camera, microphone, location, and notifications.', 'content settings cookies'),
  e('privacy', 'clear-data', 'Clear Browsing Data', 'History, cookies, cache, and download history.', 'delete history cookies cache'),
  e('privacy', 'https-only', 'Always use secure connections', 'Warn before going to sites without HTTPS.', 'https first', 'privacy.httpsOnly'),
  e('privacy', 'do-not-track', 'Send a "Do Not Track" request', '', 'dnt tracking', 'privacy.doNotTrack'),
  e('privacy', 'safe-browsing', 'Safe Browsing', 'Off by design in Open.', 'google malware phishing'),
  e('privacy', 'chromium-settings', 'More browser settings', 'Chromium settings for this Profile.', 'chrome settings'),

  e('adblock', 'enabled', 'Block ads, trackers, and popups', 'The main switch applies to all Profiles.', 'ublock content blocker'),
  e('adblock', 'lists', 'Block lists', 'Choose lists, update them, or reset list choices.', 'easylist easyprivacy filter'),
  e('adblock', 'allowed-sites', "Don't block on these sites", 'Add or remove an allowed site.', 'exclusions whitelist'),
  e('adblock', 'custom-rules', 'Custom rules', 'Your own filter rules.', 'filters'),

  e('passwords', 'passwords', 'Passwords', 'Saved logins and passkeys.', 'password manager credentials'),
  e('passwords', 'payments', 'Payment methods', '', 'credit cards autofill'),
  e('passwords', 'addresses', 'Addresses', '', 'autofill'),

  e('sync', 'account', 'Open Account', 'Sign in, create an account, or recover your vault.', 'arc sync sign in login register cloud'),
  e('sync', 'server', 'Sync server', 'Your self-hosted Open Sync server.', 'self-hosted docker url'),
  e('sync', 'sync-now', 'Sync Now', '', 'refresh'),
  e('sync', 'categories', 'What to sync', '', 'spaces tabs history passwords'),
  e('sync', 'devices', 'Devices', 'See and disconnect devices.', 'revoke sessions'),
  e('sync', 'security', 'Account security', 'Change your password or delete your account.', 'password recovery key delete'),

  e('import', 'sources', 'Import from another browser', 'Open, Arc, Safari, Chrome, Brave, Edge, and Firefox.', 'migrate Import from Arc chrome firefox safari'),
  e('import', 'html', 'Import Bookmarks HTML', '', 'bookmarks file netscape'),
  e('import', 'undo', 'Undo last import', '', 'revert'),

  e('advanced', 'boosts', 'Enable Boosts on websites you visit', '', 'Arc Boosts zap css', 'advanced.enableBoosts'),
  e('advanced', 'pip', 'Picture in Picture when you leave a video tab', '', 'auto pip video', 'advanced.pictureInPicture'),
  e('advanced', 'pip-hosts', 'Sites without automatic Picture in Picture', '', 'pip exclusions', 'advanced.pipExcludedHosts'),
  e('advanced', 'sound', 'Play Open sound effects', '', 'audio', 'advanced.soundEffects'),
  e('advanced', 'haptics', 'Haptic feedback when reordering tabs', '', 'trackpad', 'advanced.haptics'),
  e('advanced', 'window-dragging', 'Allow window dragging from the top of webpages', '', '', 'advanced.windowDragging'),
  e('advanced', 'shared-quotes', 'Enable Shared Quotes when highlighting text', '', '', 'advanced.sharedQuotes'),
  e('advanced', 'theme-data', 'Allow websites to get your theme data', '', '', 'advanced.themeData'),
  e('advanced', 'developer-mode', 'Developer mode for extensions', '', 'unpacked', 'advanced.developerMode'),
  e('advanced', 'hardware-acceleration', 'Use hardware acceleration', 'Takes effect after you quit and reopen Open.', 'gpu', 'advanced.hardwareAcceleration'),
  e('advanced', 'widevine', 'Play DRM-protected video', "Downloads Google's Widevine module.", 'DRM Widevine netflix streaming', 'advanced.widevine'),
  e('advanced', 'data-folder', 'Show Data Folder', '', 'profile directory files'),
  e('advanced', 'onboarding', 'Replay onboarding', '', 'welcome tour'),

  e('about', 'version', 'Open version', 'Open and Chromium engine versions.', 'build release'),
  e('about', 'updates', 'Check for Updates', '', 'update'),
  e('about', 'system-info', 'Copy system info', '', 'diagnostics support'),
];

/** Folds case and diacritics for search. */
export function fold(text: string): string {
  return text.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}
