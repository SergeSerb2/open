// In-memory stand-in for the library.* methods outside Chromium WebUI
// (vite dev server, design review). Synthetic data only.

import { rpc, type RpcMethod, type SpaceStyle } from '../shared/bridge';
import type {
  LibArchiveItem,
  LibDocument,
  LibDownload,
  LibHistoryEntry,
  LibMediaItem,
  LibSpace,
  LibraryMethod,
  LibReq,
  LibRes,
  SpaceThemeVars,
} from './types';

const P1 = '00000000-0000-0000-0000-000000000001';
const P2 = '00000000-0000-0000-0000-000000000002';
const NOW = Date.now() / 1000;
const DAY = 86400;

function svgThumb(a: string, b: string, label: string): string {
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">` +
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/>` +
    `<stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="320" height="200" fill="url(#g)"/>` +
    `<rect x="24" y="26" width="150" height="14" rx="7" fill="#fff" opacity=".85"/>` +
    `<rect x="24" y="52" width="230" height="9" rx="4.5" fill="#fff" opacity=".55"/>` +
    `<rect x="24" y="70" width="190" height="9" rx="4.5" fill="#fff" opacity=".55"/>` +
    `<desc>${label.replace(/[<&>]/g, '')}</desc></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function style(r: number, g: number, b: number, appearance: SpaceStyle['appearance'] = 'automatic'): SpaceStyle {
  return {
    math_version: 1,
    key_color: { r, g, b, a: 1 },
    color_count: 2,
    wheel: 'analogous',
    appearance,
    noise_factor: 0.2,
    texture: 'grain',
    intensity_factor: 0.6,
  };
}

interface PreviewState {
  downloads: LibDownload[];
  history: LibHistoryEntry[];
  archive: LibArchiveItem[];
  media: LibMediaItem[];
  folders: string[];
  spaces: LibSpace[];
  easels: LibDocument[];
  notes: LibDocument[];
  activeSpace: string;
}

let state: PreviewState | null = null;
const liveStart = Date.now();

function download(partial: Partial<LibDownload> & Pick<LibDownload, 'id' | 'filename' | 'state'>): LibDownload {
  return {
    url: `https://files.example.test/${partial.filename}`,
    target_path: `/Users/you/Downloads/${partial.filename}`,
    mime_type: 'application/octet-stream',
    received_bytes: 0,
    total_bytes: -1,
    started_at: NOW - 600,
    ended_at: NOW - 590,
    profile_id: P1,
    fileExists: true,
    bytesPerSecond: 0,
    canResume: false,
    isLive: false,
    progress: 1,
    host: 'files.example.test',
    ...partial,
  };
}

const SITES: readonly [string, string][] = [
  ['https://en.wikipedia.org/wiki/Typography', 'Typography – Wikipedia'],
  ['https://developer.mozilla.org/en-US/docs/Web/CSS/color-mix', 'color-mix() - CSS | MDN'],
  ['https://news.example.test/', 'Example News — Front Page'],
  ['https://github.com/preactjs/preact', 'preactjs/preact: Fast 3kB React alternative'],
  ['https://www.example.com/recipes/focaccia', 'Rosemary Focaccia Recipe'],
  ['https://maps.example.test/place/lighthouse', 'Lighthouse Point · Maps'],
  ['https://docs.example.test/guide/getting-started', 'Getting Started · Example Docs'],
  ['https://weather.example.test/vancouver', 'Weather Forecast · Vancouver'],
  ['https://store.example.test/headphones', 'Wireless Headphones – Example Store'],
  ['https://blog.example.test/posts/design-systems', 'Notes on Design Systems'],
];

function seed(): PreviewState {
  const downloads: LibDownload[] = [
    download({
      id: 'dl-live',
      filename: 'Design Assets.zip',
      state: 'in_progress',
      total_bytes: 184_000_000,
      received_bytes: 32_000_000,
      progress: 0.17,
      bytesPerSecond: 4_200_000,
      isLive: true,
      canResume: true,
      started_at: NOW - 40,
      ended_at: 0,
    }),
    download({
      id: 'dl-paused',
      filename: 'Conference Talk.mp4',
      state: 'paused',
      total_bytes: 512_000_000,
      received_bytes: 201_000_000,
      progress: 0.39,
      isLive: true,
      canResume: true,
      started_at: NOW - 900,
      ended_at: 0,
      mime_type: 'video/mp4',
    }),
    download({
      id: 'dl-img',
      filename: 'harbor-sunset.jpg',
      state: 'completed',
      total_bytes: 2_400_000,
      received_bytes: 2_400_000,
      mime_type: 'image/jpeg',
      thumb_url: svgThumb('#f97316', '#7c3aed', 'harbor-sunset.jpg'),
      started_at: NOW - 3_000,
      ended_at: NOW - 2_990,
    }),
    download({
      id: 'dl-pdf',
      filename: 'Quarterly Report.pdf',
      state: 'completed',
      total_bytes: 880_000,
      received_bytes: 880_000,
      mime_type: 'application/pdf',
      started_at: NOW - DAY - 400,
      ended_at: NOW - DAY - 380,
      profile_id: P2,
    }),
    download({
      id: 'dl-missing',
      filename: 'old-installer.dmg',
      state: 'completed',
      total_bytes: 96_000_000,
      received_bytes: 96_000_000,
      fileExists: false,
      started_at: NOW - 3 * DAY,
      ended_at: NOW - 3 * DAY + 50,
    }),
    download({
      id: 'dl-failed',
      filename: 'dataset.csv',
      state: 'interrupted',
      total_bytes: 12_000_000,
      received_bytes: 4_100_000,
      progress: 0.34,
      started_at: NOW - 3 * DAY - 600,
      ended_at: NOW - 3 * DAY - 500,
    }),
  ];

  const history: LibHistoryEntry[] = [];
  let id = 1;
  for (let d = 0; d < 12; d++) {
    const perDay = d === 0 ? 9 : 6;
    for (let i = 0; i < perDay; i++) {
      const site = SITES[(d * 3 + i) % SITES.length]!;
      const last = NOW - d * DAY - i * 2_700 - 120;
      const day = new Date(last * 1000);
      day.setHours(0, 0, 0, 0);
      history.push({
        id: id++,
        url: site[0],
        title: site[1],
        visit_count: 1 + ((d + i) % 5),
        typed_count: 0,
        last_visit: last,
        profile_id: i % 4 === 3 ? P2 : P1,
        favicon_url: '',
        host: new URL(site[0]).hostname.replace(/^www\./, ''),
        day_start: day.getTime() / 1000,
      });
    }
  }

  const dayStart = (t: number) => {
    const d = new Date(t * 1000);
    d.setHours(0, 0, 0, 0);
    return d.getTime() / 1000;
  };
  const archive: LibArchiveItem[] = [
    {
      id: 'ar-1',
      url: 'https://docs.example.test/guide/routing',
      title: 'Routing · Example Docs',
      space_id: 'sp-1',
      space_title: 'Personal',
      profile_id: P1,
      archived_at: NOW - 1_800,
      reason: 'auto-archive',
      original_location: 'today',
      kind: 'tab',
      favicon_url: '',
      host: 'docs.example.test',
      day_start: dayStart(NOW - 1_800),
    },
    {
      id: 'ar-folder',
      url: '',
      title: 'Trip Planning',
      space_id: 'sp-1',
      space_title: 'Personal',
      profile_id: P1,
      archived_at: NOW - 7_200,
      reason: 'closed',
      original_location: 'today',
      kind: 'folder',
      favicon_url: '',
      host: '',
      day_start: dayStart(NOW - 7_200),
      child_count: 3,
      children: [
        { id: 'c1', url: 'https://maps.example.test/place/lighthouse', title: 'Lighthouse Point · Maps', host: 'maps.example.test', favicon_url: '' },
        { id: 'c2', url: 'https://weather.example.test/vancouver', title: 'Weather Forecast', host: 'weather.example.test', favicon_url: '' },
        { id: 'c3', url: 'https://www.example.com/hotels', title: 'Harbour Hotels', host: 'example.com', favicon_url: '' },
      ],
    },
    {
      id: 'ar-2',
      url: 'https://store.example.test/headphones',
      title: 'Wireless Headphones – Example Store',
      space_id: 'sp-2',
      space_title: 'Work',
      profile_id: P2,
      archived_at: NOW - DAY - 3_600,
      reason: 'closed',
      original_location: 'today',
      kind: 'tab',
      favicon_url: '',
      host: 'store.example.test',
      day_start: dayStart(NOW - DAY - 3_600),
    },
    {
      id: 'ar-3',
      url: 'https://blog.example.test/posts/design-systems',
      title: 'Notes on Design Systems',
      space_id: 'sp-1',
      space_title: 'Personal',
      profile_id: P1,
      archived_at: NOW - 4 * DAY,
      reason: 'clear-today',
      original_location: 'today',
      kind: 'tab',
      favicon_url: '',
      host: 'blog.example.test',
      day_start: dayStart(NOW - 4 * DAY),
    },
  ];

  const media: LibMediaItem[] = [
    ['cap-1', 'Example Docs — Routing', 'capture', '#2563eb', '#06b6d4', NOW - 900],
    ['cap-2', 'Weather Forecast · Vancouver', 'capture', '#0ea5e9', '#22c55e', NOW - 5_000],
    ['dlm-1', 'harbor-sunset.jpg', 'download', '#f97316', '#7c3aed', NOW - 3_000],
    ['fold-1', 'Screenshot 2026-11-20.png', 'folder', '#64748b', '#0f172a', NOW - 6 * DAY],
    ['cap-3', 'Notes on Design Systems', 'capture', '#db2777', '#f59e0b', NOW - 2 * DAY],
  ].map(([itemId, title, source, a, b, t]) => ({
    id: itemId as string,
    title: title as string,
    source: source as LibMediaItem['source'],
    source_url: source === 'capture' ? 'https://docs.example.test/' : '',
    folder: source === 'folder' ? 'Desktop' : source === 'download' ? 'Downloads' : 'Captures',
    path: `/Users/you/${source === 'folder' ? 'Desktop' : 'Library/Captures'}/${title}`,
    kind: 'image' as const,
    ext: 'png',
    captured_at: t as number,
    size: 420_000,
    file_url: svgThumb(a as string, b as string, title as string),
    thumb_url: svgThumb(a as string, b as string, title as string),
    profile_id: P1,
  }));

  const spaces: LibSpace[] = [
    { id: 'sp-1', title: 'Personal', icon: { kind: 'emoji', value: '🪐' }, profile_id: P1, style: style(0.35, 0.42, 0.98), pinned_count: 4, today_count: 7, profile_name: 'Personal', is_active: true },
    { id: 'sp-2', title: 'Work', icon: { kind: 'emoji', value: '💼' }, profile_id: P2, style: style(0.95, 0.55, 0.25), pinned_count: 6, today_count: 3, profile_name: 'Work' },
    { id: 'sp-3', title: 'Reading', icon: { kind: 'emoji', value: '📚' }, profile_id: P1, style: style(0.2, 0.7, 0.5, 'dark'), pinned_count: 2, today_count: 11, profile_name: 'Personal' },
  ];

  const easels: LibDocument[] = [
    { id: 'e1', kind: 'easel', title: 'Moodboard — Spring', element_count: 14, modified_at: NOW - 3_600, url: 'open://easel/e1', profile_id: P1 },
    { id: 'e2', kind: 'easel', title: 'Launch Plan', element_count: 6, modified_at: NOW - 3 * DAY, url: 'open://easel/e2', profile_id: P2 },
  ];
  const notes: LibDocument[] = [
    { id: 'n1', kind: 'note', title: 'Groceries', modified_at: NOW - 600, url: 'open://note/n1', profile_id: P1 },
    { id: 'n2', kind: 'note', title: 'Meeting notes — Thursday', modified_at: NOW - 2 * DAY, url: 'open://note/n2', profile_id: P2 },
  ];

  return { downloads, history, archive, media, folders: ['/Users/you/Desktop'], spaces, easels, notes, activeSpace: 'sp-1' };
}

function st(): PreviewState {
  if (!state) state = seed();
  return state;
}

function profileMatch(filter: string | undefined, profile: string): boolean {
  return !filter || filter === 'all' || filter === profile;
}

function words(query: string | undefined): string[] {
  return (query ?? '').toLowerCase().split(/\s+/).filter(Boolean);
}

function matches(query: string | undefined, ...fields: string[]): boolean {
  const hay = fields.join('\n').toLowerCase();
  return words(query).every((w) => hay.includes(w));
}

/** Advances the simulated running transfer. */
function tick(dl: LibDownload): LibDownload {
  if (dl.id !== 'dl-live' || dl.state !== 'in_progress') return dl;
  const elapsed = (Date.now() - liveStart) / 1000;
  const received = Math.min(dl.total_bytes, 32_000_000 + elapsed * dl.bytesPerSecond);
  if (received >= dl.total_bytes) {
    return { ...dl, state: 'completed', received_bytes: dl.total_bytes, progress: 1, bytesPerSecond: 0, ended_at: Date.now() / 1000, isLive: false };
  }
  return { ...dl, received_bytes: received, progress: received / dl.total_bytes };
}

function themeFor(space: LibSpace): SpaceThemeVars {
  const dark =
    space.style.appearance === 'dark' ||
    (space.style.appearance === 'automatic' && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
  const { r, g, b } = space.style.key_color;
  const mix = (c: number, t: number, to: number) => Math.round((c + (to - c) * t) * 255);
  return dark
    ? { bg: `rgb(${mix(r, 0.8, 0.075)}, ${mix(g, 0.8, 0.075)}, ${mix(b, 0.8, 0.095)})`, fg: 'rgb(245, 245, 247)', accent: `rgb(${mix(r, 0.3, 1)}, ${mix(g, 0.3, 1)}, ${mix(b, 0.3, 1)})`, surface: 'rgba(255, 255, 255, 0.09)', mode: 'dark', space_id: space.id }
    : { bg: `rgb(${mix(r, 0.84, 1)}, ${mix(g, 0.84, 1)}, ${mix(b, 0.84, 1)})`, fg: 'rgb(28, 28, 33)', accent: `rgb(${mix(r, 0, 0)}, ${mix(g, 0, 0)}, ${mix(b, 0, 0)})`, surface: 'rgba(0, 0, 0, 0.06)', mode: 'light', space_id: space.id };
}

const delay = (ms = 40) => new Promise((r) => window.setTimeout(r, ms));

export async function previewCall<M extends LibraryMethod>(method: M, payload: LibReq<M>): Promise<LibRes<M>> {
  await delay();
  const s = st();
  const p = payload as Record<string, unknown>;
  const ok = { ok: true };
  const out = (v: unknown) => v as LibRes<M>;
  const fail = (msg: string): never => {
    throw new Error(msg);
  };
  switch (method) {
    case 'library.close':
      return out({ ok: true, closed_tab: false });
    case 'library.theme.get': {
      const space = s.spaces.find((x) => x.id === (p.space_id ?? s.activeSpace)) ?? s.spaces[0]!;
      return out({ theme: themeFor(space), system_dark: false });
    }

    case 'library.history.list': {
      const offset = Number(p.offset ?? 0);
      const limit = Number(p.limit ?? 200);
      const rows = s.history
        .filter((h) => profileMatch(p.profile_id as string, h.profile_id) && matches(p.query as string, h.title, h.url))
        .sort((a, b) => b.last_visit - a.last_visit);
      return out({ entries: rows.slice(offset, offset + limit), offset, has_more: rows.length > offset + limit });
    }
    case 'library.history.delete': {
      const ids = new Set((p.ids as number[] | undefined) ?? []);
      s.history = s.history.filter((h) => !ids.has(h.id));
      return out({ ok: true, remaining: s.history.length });
    }
    case 'library.history.clear': {
      const range = p.range as string;
      const now = Date.now() / 1000;
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const since =
        range === 'lastHour' ? now - 3600 : range === 'today' ? today.getTime() / 1000 : range === 'last7Days' ? today.getTime() / 1000 - 6 * DAY : -Infinity;
      s.history = s.history.filter((h) => !(profileMatch(p.profile_id as string, h.profile_id) && h.last_visit >= since));
      return out({ ok: true, remaining: s.history.length });
    }

    case 'library.archive.list':
      return out({
        items: s.archive.filter(
          (a) =>
            profileMatch(p.profile_id as string, a.profile_id) &&
            matches(p.query as string, a.title, a.url, ...(a.children ?? []).map((c) => c.title)),
        ),
      });
    case 'library.archive.restore': {
      const item = s.archive.find((a) => a.id === p.id) ?? fail('no such item');
      s.archive = s.archive.filter((a) => a.id !== p.id);
      return out({ ok: true, restored_id: item.id, restored_url: item.url, kind: item.kind });
    }
    case 'library.archive.delete': {
      const ids = new Set(p.ids as string[]);
      s.archive = s.archive.filter((a) => !ids.has(a.id));
      return out(ok);
    }
    case 'library.archive.clearAll':
      s.archive = s.archive.filter((a) => !profileMatch(p.profile_id as string, a.profile_id));
      return out(ok);
    case 'library.archive.peek':
      return out(ok);

    case 'library.downloads.list':
      s.downloads = s.downloads.map(tick);
      return out({
        downloads: s.downloads.filter(
          (d) => profileMatch(p.profile_id as string, d.profile_id) && matches(p.query as string, d.filename, d.url),
        ),
        live_bridge: true,
      });
    case 'library.downloads.pause':
    case 'library.downloads.resume':
    case 'library.downloads.cancel':
    case 'library.downloads.retry': {
      const action = method.split('.').pop();
      s.downloads = s.downloads.map((d) => {
        if (d.id !== p.id) return d;
        if (action === 'pause') return { ...d, state: 'paused', bytesPerSecond: 0 };
        if (action === 'resume') return { ...d, state: 'in_progress', bytesPerSecond: 3_100_000 };
        if (action === 'cancel') return { ...d, state: 'cancelled', bytesPerSecond: 0, isLive: false };
        return { ...d, state: 'in_progress', bytesPerSecond: 2_000_000, isLive: true };
      });
      return out(ok);
    }
    case 'library.downloads.open':
    case 'library.downloads.reveal':
      return out(ok);
    case 'library.downloads.trash':
    case 'library.downloads.remove':
      s.downloads = s.downloads.filter((d) => d.id !== p.id);
      return out(ok);
    case 'library.downloads.clear': {
      const before = s.downloads.length;
      s.downloads = s.downloads.filter(
        (d) => !profileMatch(p.profile_id as string, d.profile_id) || d.state === 'in_progress' || d.state === 'paused',
      );
      return out({ ok: true, removed: before - s.downloads.length });
    }

    case 'library.media.list': {
      const source = (p.source as string) || 'all';
      return out({
        items: s.media.filter(
          (m) =>
            profileMatch(p.profile_id as string, m.profile_id) &&
            (source === 'all' || m.source === source) &&
            matches(p.query as string, m.title, m.folder),
        ),
        folders: [...s.folders],
      });
    }
    case 'library.media.addFolder': {
      const preset = p.preset as string | undefined;
      const path = preset ? `/Users/you/${preset.charAt(0).toUpperCase()}${preset.slice(1)}` : String(p.path ?? '');
      if (!path.startsWith('/')) fail('choose a full folder path');
      if (!s.folders.includes(path)) s.folders.push(path);
      return out(ok);
    }
    case 'library.media.removeFolder':
      s.folders = s.folders.filter((f) => f !== p.path);
      return out(ok);
    case 'library.media.delete':
      s.media = s.media.filter((m) => m.id !== p.id);
      return out(ok);
    case 'library.media.open':
    case 'library.media.reveal':
    case 'library.media.copyImage':
      return out(ok);

    case 'library.spaces.list':
      return out({
        spaces: s.spaces
          .filter((x) => profileMatch(p.profile_id as string, x.profile_id))
          .map((x) => ({ ...x, is_active: x.id === s.activeSpace, theme: themeFor(x) })),
        active_space_id: s.activeSpace,
      });
    case 'library.spaces.create': {
      const space: LibSpace = {
        id: `sp-${Date.now()}`,
        title: (p.title as string) || 'New Space',
        icon: { kind: 'emoji', value: '✨' },
        profile_id: (p.profile_id as string) || P1,
        style: style(0.6, 0.35, 0.95),
        pinned_count: 0,
        today_count: 0,
        profile_name: 'Personal',
      };
      s.spaces.push(space);
      return out({ space });
    }
    case 'library.spaces.update': {
      const space = s.spaces.find((x) => x.id === p.id) ?? fail('no such space');
      if (typeof p.title === 'string') space.title = p.title;
      if (p.icon) space.icon = p.icon as LibSpace['icon'];
      if (p.style) space.style = p.style as SpaceStyle;
      return out({ space: { ...space } });
    }
    case 'library.spaces.delete':
      if (s.spaces.length <= 1) fail('the last space cannot be deleted');
      s.spaces = s.spaces.filter((x) => x.id !== p.id);
      return out(ok);
    case 'library.spaces.switch':
      s.activeSpace = String(p.id);
      return out(ok);
    case 'library.spaces.reorder': {
      const order = p.ids as string[];
      s.spaces.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
      return out(ok);
    }

    case 'library.boosts.list': {
      const res = await rpc('boosts.list', { profile_id: 'all' });
      return out({ boosts: res.boosts.filter((b) => profileMatch(p.profile_id as string, b.profile_id) && matches(p.query as string, b.name, b.host_pattern)) });
    }
    case 'library.documents.list':
      return out({
        easels: s.easels.filter((d) => profileMatch(p.profile_id as string, d.profile_id) && matches(p.query as string, d.title)),
        notes: s.notes.filter((d) => profileMatch(p.profile_id as string, d.profile_id) && matches(p.query as string, d.title)),
      });
    case 'library.documents.create': {
      const kind = p.kind as 'easel' | 'note';
      const doc: LibDocument = {
        id: `${kind}-${Date.now()}`,
        kind,
        title: kind === 'easel' ? 'Untitled Easel' : 'Untitled Note',
        element_count: 0,
        modified_at: Date.now() / 1000,
        url: `open://${kind}/${kind}-${Date.now()}`,
        profile_id: (p.profile_id as string) || P1,
      };
      (kind === 'easel' ? s.easels : s.notes).unshift(doc);
      return out({ id: doc.id, url: doc.url });
    }
    case 'library.documents.delete':
      s.easels = s.easels.filter((d) => d.id !== p.id);
      s.notes = s.notes.filter((d) => d.id !== p.id);
      return out(ok);

    case 'library.openUrl':
      return out(ok);

    default:
      // boosts.*, settings.* — the shared preview adapter.
      return (await rpc(method as unknown as RpcMethod, payload as never)) as LibRes<M>;
  }
}
