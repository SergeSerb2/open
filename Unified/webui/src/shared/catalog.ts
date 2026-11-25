// Canonical AdBlock 46-list catalog, built-in search engines, default shortcuts,
// and Onboarding favorite suggestions. Matches OpenKit's catalog.json (3/2/5/35/1 = 46).

export type AdBlockListCategory = 'generic' | 'cookies' | 'privacy' | 'regional' | 'bcny';

export interface AdBlockCatalogEntry {
  id: string;
  display_name: string;
  info_url: string;
  category: AdBlockListCategory;
  bundled: boolean;
  default_enabled: boolean;
  unavailable_reason?: string;
}

export const ADBLOCK_CATALOG: readonly AdBlockCatalogEntry[] = [
  // generic (3)
  { id: 'EasyList', display_name: 'EasyList', info_url: 'https://easylist.to/', category: 'generic', bundled: true, default_enabled: true },
  { id: 'AdGuardAds', display_name: 'AdGuard - Ads', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'generic', bundled: false, default_enabled: false },
  { id: 'uBlock', display_name: 'uBlock Origin filters', info_url: 'https://github.com/uBlockOrigin/uAssets', category: 'generic', bundled: false, default_enabled: false },
  // cookies (2)
  { id: 'CookieMonster', display_name: 'CookieMonster by Fanboy', info_url: 'https://github.com/easylist/easylist#fanboy-lists', category: 'cookies', bundled: false, default_enabled: false },
  { id: 'AdGuardCookies', display_name: 'AdGuard – Cookie Notices', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'cookies', bundled: false, default_enabled: false },
  // privacy (5)
  { id: 'EasyPrivacy', display_name: 'EasyPrivacy', info_url: 'https://easylist.to/', category: 'privacy', bundled: true, default_enabled: true },
  { id: 'AdGuardSpyware', display_name: 'AdGuard Tracking Protection', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'privacy', bundled: false, default_enabled: false },
  { id: 'EasyListSocial', display_name: 'EasyList - Social Widgets', info_url: 'https://easylist.to/', category: 'privacy', bundled: false, default_enabled: false },
  { id: 'AdGuardSocial', display_name: 'AdGuard – Social Widgets', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'privacy', bundled: false, default_enabled: false },
  { id: 'FanBoyThirdParty', display_name: 'Fanboy – Anti-Facebook', info_url: 'https://github.com/easylist/easylist#fanboy-lists', category: 'privacy', bundled: false, default_enabled: false },
  // regional (35)
  { id: 'pl', display_name: 'EasyList - Polska lista', info_url: 'https://github.com/MajkiIT/polish-ads-filter', category: 'regional', bundled: false, default_enabled: false },
  { id: 'ua', display_name: 'RU AdList', info_url: 'https://forums.lanik.us/viewtopic.php?f=102&t=22512', category: 'regional', bundled: false, default_enabled: false },
  { id: 'al', display_name: 'Adblock List for Albania', info_url: 'https://github.com/AnXh3L0/blocklist', category: 'regional', bundled: false, default_enabled: false },
  { id: 'bg', display_name: 'Adblock List for Bulgaria', info_url: 'https://stanev.org/abp/', category: 'regional', bundled: false, default_enabled: false },
  { id: 'zn', display_name: 'AdGuard Chinese (中文)', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'cssk', display_name: 'EasyList Czech and Slovak', info_url: 'https://github.com/tomasko126/easylistczechandslovak', category: 'regional', bundled: false, default_enabled: false },
  { id: 'de', display_name: 'EasyList Germany', info_url: 'https://forums.lanik.us/viewforum.php?f=90', category: 'regional', bundled: false, default_enabled: false },
  { id: 'ee', display_name: 'Eesti saitidele kohandatud filter (Estonian)', info_url: 'https://adblock.ee/', category: 'regional', bundled: false, default_enabled: false },
  { id: 'ar', display_name: 'Liste AR', info_url: 'https://forums.lanik.us/viewforum.php?f=98', category: 'regional', bundled: false, default_enabled: false },
  { id: 'espt', display_name: 'AdGuard Spanish/Portuguese', info_url: 'https://kb.adguard.com/en/general/adguard-ad-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'es', display_name: 'EasyList Spanish', info_url: 'https://forums.lanik.us/viewforum.php?f=103', category: 'regional', bundled: false, default_enabled: false },
  { id: 'fi', display_name: 'Adblock List for Finland', info_url: 'https://github.com/finnish-easylist-addition/finnish-easylist-addition', category: 'regional', bundled: false, default_enabled: false },
  { id: 'fr', display_name: 'AdGuard Français', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'gr', display_name: 'Greek AdBlock Filter', info_url: 'https://github.com/kargig/greek-adblockplus-filter', category: 'regional', bundled: false, default_enabled: false },
  { id: 'hr', display_name: "Dandelion Sprout's Serbo-Croatian filters", info_url: 'https://github.com/DandelionSprout/adfilt#readme', category: 'regional', bundled: false, default_enabled: false },
  { id: 'hu', display_name: 'hufilter (Hungarian)', info_url: 'https://github.com/hufilter/hufilter', category: 'regional', bundled: false, default_enabled: false },
  { id: 'ind', display_name: 'ABPindo (Indonesia/Malaysia)', info_url: 'https://github.com/ABPindo/indonesianadblockrules', category: 'regional', bundled: false, default_enabled: false },
  { id: 'il', display_name: 'EasyList Hebrew', info_url: 'https://github.com/easylist/EasyListHebrew', category: 'regional', bundled: false, default_enabled: false },
  { id: 'in', display_name: 'IndianList', info_url: 'https://github.com/mediumkreation/IndianList', category: 'regional', bundled: false, default_enabled: false },
  { id: 'persian', display_name: 'PersianBlocker', info_url: 'https://github.com/MasterKia/PersianBlocker', category: 'regional', bundled: false, default_enabled: false },
  { id: 'cold', display_name: 'Icelandic ABP List', info_url: 'https://github.com/brave/adblock-lists', category: 'regional', bundled: false, default_enabled: false },
  { id: 'it', display_name: 'EasyList Italy', info_url: 'https://forums.lanik.us/viewforum.php?f=96', category: 'regional', bundled: false, default_enabled: false },
  { id: 'jp', display_name: 'AdGuard Japanese', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'kr', display_name: 'List-KR (Korean)', info_url: 'https://github.com/List-KR/List-KR#readme', category: 'regional', bundled: false, default_enabled: false },
  { id: 'lt', display_name: 'EasyList Lithuania', info_url: 'https://github.com/EasyList-Lithuania/easylist_lithuania', category: 'regional', bundled: false, default_enabled: false },
  { id: 'lv', display_name: 'Latvian List', info_url: 'https://github.com/Latvian-List/adblock-latvian', category: 'regional', bundled: false, default_enabled: false },
  { id: 'mk', display_name: 'Macedonian adBlock Filters', info_url: 'https://github.com/DeepSpaceHarbor/Macedonian-adBlock-Filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'dk', display_name: 'AdGuard Dutch', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'nodkice', display_name: 'Dandelion Sprouts nordiske filtre (Norway/Denmark/Iceland)', info_url: 'https://github.com/DandelionSprout/adfilt', category: 'regional', bundled: false, default_enabled: false },
  { id: 'ro', display_name: 'Romanian Ad (ROad) Block List Light', info_url: 'https://github.com/tcptomato/ROad-Block', category: 'regional', bundled: false, default_enabled: false },
  { id: 'se', display_name: "Frellwit's Swedish Filter", info_url: 'https://github.com/lassekongo83/Frellwits-filter-lists', category: 'regional', bundled: false, default_enabled: false },
  { id: 'slovenia', display_name: 'Slovenian List', info_url: 'https://github.com/betterwebleon/slovenian-list', category: 'regional', bundled: false, default_enabled: false },
  { id: 'th', display_name: 'EasyList Thailand', info_url: 'https://github.com/easylist-thailand/easylist-thailand', category: 'regional', bundled: false, default_enabled: false },
  { id: 'tr', display_name: 'AdGuard Turkish', info_url: 'https://github.com/AdguardTeam/AdguardFilters#adguard-filters', category: 'regional', bundled: false, default_enabled: false },
  { id: 'vn', display_name: 'ABPVN List (Vietnamese)', info_url: 'https://abpvn.com/', category: 'regional', bundled: false, default_enabled: false },
  // bcny (1)
  {
    id: 'BCNYBlocklists',
    display_name: 'BCNY Blocklists',
    info_url: 'https://diabrowser.com',
    category: 'bcny',
    bundled: false,
    default_enabled: false,
    unavailable_reason: 'No public upstream source. The reference lists are proprietary mirror-only additions.',
  },
] as const;

export interface BuiltInSearchEngine {
  id: string;
  name: string;
  keyword: string;
  url_template: string;
}

export const BUILTIN_SEARCH_ENGINES: readonly BuiltInSearchEngine[] = [
  { id: 'google', name: 'Google', keyword: 'g', url_template: 'https://www.google.com/search?q=%s' },
  { id: 'duckduckgo', name: 'DuckDuckGo', keyword: 'ddg', url_template: 'https://duckduckgo.com/?q=%s' },
  { id: 'kagi', name: 'Kagi', keyword: 'kagi', url_template: 'https://kagi.com/search?q=%s' },
  { id: 'bing', name: 'Bing', keyword: 'bing', url_template: 'https://www.bing.com/search?q=%s' },
  { id: 'perplexity', name: 'Perplexity', keyword: 'px', url_template: 'https://www.perplexity.ai/search?q=%s' },
  { id: 'ecosia', name: 'Ecosia', keyword: 'eco', url_template: 'https://www.ecosia.org/search?q=%s' },
];

export interface OnboardingFavoriteOption {
  id: string;
  title: string;
  url: string;
  monogram: string;
  hueColor: string;
  defaultSelected?: boolean;
}

export const ONBOARDING_FAVORITES: readonly OnboardingFavoriteOption[] = [
  { id: 'gmail', title: 'Gmail', url: 'https://mail.google.com/', monogram: 'Gm', hueColor: '#C5463E', defaultSelected: true },
  { id: 'maps', title: 'Google Maps', url: 'https://maps.google.com/', monogram: 'GM', hueColor: '#2E8457' },
  { id: 'calendar', title: 'Calendar', url: 'https://calendar.google.com/', monogram: 'Ca', hueColor: '#3B6EC5', defaultSelected: true },
  { id: 'github', title: 'GitHub', url: 'https://github.com/', monogram: 'GH', hueColor: '#3A3E47', defaultSelected: true },
  { id: 'youtube', title: 'YouTube', url: 'https://www.youtube.com/', monogram: 'YT', hueColor: '#C13D3D' },
  { id: 'notion', title: 'Notion', url: 'https://www.notion.com/', monogram: 'No', hueColor: '#4A4E59' },
  { id: 'linear', title: 'Linear', url: 'https://linear.app/', monogram: 'Li', hueColor: '#5B59B8' },
  { id: 'figma', title: 'Figma', url: 'https://www.figma.com/', monogram: 'Fg', hueColor: '#9D468E' },
  { id: 'wikipedia', title: 'Wikipedia', url: 'https://en.wikipedia.org/', monogram: 'Wi', hueColor: '#5F6673' },
  { id: 'spotify', title: 'Spotify', url: 'https://open.spotify.com/', monogram: 'Sp', hueColor: '#2D8553' },
  { id: 'reddit', title: 'Reddit', url: 'https://www.reddit.com/', monogram: 'Re', hueColor: '#BE562C' },
  { id: 'hn', title: 'Hacker News', url: 'https://news.ycombinator.com/', monogram: 'HN', hueColor: '#B86424' },
];

export const SYNC_CATEGORIES: readonly { id: string; title: string; description: string }[] = [
  { id: 'workspace', title: 'Workspace', description: 'Profiles, Spaces, pinned tabs, folders, splits, Favorites, and Air Traffic Control rules.' },
  { id: 'today_tabs', title: 'Today Tabs', description: 'Unpinned Today tabs, folders, and splits per Space.' },
  { id: 'archive', title: 'Archive', description: 'Archived tabs and folders per Profile (up to 2,000 most recent).' },
  { id: 'settings_shortcuts', title: 'Settings & Shortcuts', description: 'Portable browser preferences and custom Keyboard Shortcuts.' },
  { id: 'ad_blocking', title: 'Ad Blocking', description: 'Native ad-blocker state, filter list choices, and allowed domains.' },
  { id: 'boosts_documents', title: 'Boosts, Easels & Notes', description: 'Per-Profile Boosts, Easels, and Notes with encrypted asset blobs.' },
  { id: 'history', title: 'Browsing History', description: 'Visited URLs, titles, and timestamps per Profile (up to 5,000 most recent).' },
  { id: 'extensions', title: 'Chrome Extensions', description: 'Extension IDs, enabled state, and pinned toolbar order.' },
  { id: 'credentials_permissions', title: 'Passwords, Autofill & Site Permissions', description: 'Encrypted logins, autofill settings, and per-origin Site Permissions.' },
];
