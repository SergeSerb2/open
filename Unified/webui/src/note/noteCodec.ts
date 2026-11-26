// Bidirectional UTF-16 NoteDocument <-> Rich HTML DOM & Markdown codec.
// Preserves all Open/Arc Note formats: H1-H3, bold, italic, underline, strike,
// inline code, code blocks, blockquotes, nested bullet & numbered lists (0..5),
// interactive task checklists, horizontal dividers, links, and local images.

export type RichNoteFormatType =
  | 'bold'
  | 'italic'
  | 'underline'
  | 'strikethrough'
  | 'code'
  | 'codeBlock'
  | 'blockquote'
  | 'h1'
  | 'h2'
  | 'h3'
  | 'link'
  | 'bulletList'
  | 'numberedList'
  | 'checklist'
  | 'checklistChecked'
  | 'divider'
  | 'image';

export interface RichNoteFormatRange {
  type: RichNoteFormatType | string;
  location: number; // UTF-16 offset
  length: number; // UTF-16 length
  url?: string;
  level?: number;
}

export interface RichNoteDocument {
  format_version: number;
  id: string;
  title: string;
  text: string;
  formats: RichNoteFormatRange[];
  created_at: number;
  modified_at: number;
}

const BLOCK_TYPES = new Set<string>([
  'h1',
  'h2',
  'h3',
  'bulletList',
  'numberedList',
  'checklist',
  'checklistChecked',
  'blockquote',
  'codeBlock',
  'divider',
  'image',
]);

const INLINE_TYPES = new Set<string>([
  'bold',
  'italic',
  'underline',
  'strikethrough',
  'code',
  'link',
]);

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function sanitizeHref(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  const candidate =
    !/^[a-zA-Z][a-zA-Z\d+\-.]*:/.test(trimmed) && /^[^\s]+\.[^\s]+/.test(trimmed)
      ? `https://${trimmed}`
      : trimmed;
  try {
    const parsed = new URL(candidate);
    if (
      parsed.protocol === 'http:' ||
      parsed.protocol === 'https:' ||
      parsed.protocol === 'mailto:' ||
      parsed.protocol === 'open:'
    ) {
      return parsed.href;
    }
  } catch {
    return null;
  }
  return null;
}

export function sanitizeImgSrc(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  if (trimmed.startsWith('//')) return null;
  const hasScheme = /^[a-zA-Z][a-zA-Z\d+\-.]*:/.test(trimmed);
  if (!hasScheme) {
    return trimmed;
  }
  try {
    const parsed = new URL(trimmed);
    if (
      parsed.protocol === 'data:' ||
      parsed.protocol === 'blob:' ||
      parsed.protocol === 'open:'
    ) {
      return trimmed;
    }
    if (
      typeof window !== 'undefined' &&
      window.location &&
      window.location.origin !== 'null' &&
      parsed.origin === window.location.origin
    ) {
      return parsed.href;
    }
  } catch {
    return null;
  }
  return null;
}

export function extractAssetIdFromSrc(src: string): string | null {
  const m = src.match(/\/asset\/[^/]+\/([^/?#]+)$/);
  return m?.[1] ?? null;
}

function clampLevel(level?: number): number {
  if (typeof level !== 'number' || !Number.isFinite(level)) return 0;
  return Math.max(0, Math.min(5, Math.floor(level)));
}

/**
 * Renders canonical UTF-16 NoteDocument to structured editor HTML, properly
 * grouping contiguous bullet/numbered list items with nesting levels 0..5.
 */
export function noteDocToHtml(doc: RichNoteDocument): string {
  if (!doc.text && doc.formats.length === 0) {
    return '<p><br></p>';
  }
  const lines = doc.text.split('\n');
  let cursor = 0;
  const out: string[] = [];

  // Stack of open lists: { tag: 'ul' | 'ol', level: number }
  const openLists: Array<{ tag: 'ul' | 'ol'; level: number }> = [];
  const closeListsDownTo = (level: number) => {
    while (openLists.length > 0 && openLists[openLists.length - 1]!.level >= level) {
      const top = openLists.pop()!;
      out.push(`</li></${top.tag}>`);
    }
  };
  const closeListsDeeperThan = (level: number) => {
    while (openLists.length > 0 && openLists[openLists.length - 1]!.level > level) {
      const top = openLists.pop()!;
      out.push(`</li></${top.tag}>`);
    }
  };

  for (const line of lines) {
    const start = cursor;
    const end = start + line.length;
    cursor = end + 1;

    const lineFormats = doc.formats.filter((f) => {
      const fEnd = Math.max(f.location + f.length, f.location + 1);
      return f.location <= start && start < fEnd && BLOCK_TYPES.has(f.type)
        ? true
        : f.location < end && f.location + f.length > start;
    });

    const blockFmt = lineFormats.find((f) => BLOCK_TYPES.has(f.type));
    const inlineFormats = lineFormats.filter((f) => INLINE_TYPES.has(f.type));

    let rendered = '';
    if (line.length === 0) {
      rendered = '<br>';
    } else if (blockFmt?.type === 'codeBlock') {
      rendered = escapeHtml(line);
    } else {
      let i = 0;
      while (i < line.length) {
        const abs = start + i;
        const active = inlineFormats.filter(
          (f) => abs >= f.location && abs < f.location + f.length,
        );
        let j = i + 1;
        while (j < line.length) {
          const nextAbs = start + j;
          const nextActive = inlineFormats.filter(
            (f) => nextAbs >= f.location && nextAbs < f.location + f.length,
          );
          if (
            nextActive.length !== active.length ||
            nextActive.some((f, idx) => f !== active[idx])
          ) {
            break;
          }
          j++;
        }
        let chunk = escapeHtml(line.slice(i, j));
        for (const f of active) {
          if (f.type === 'code') chunk = `<code>${chunk}</code>`;
          else if (f.type === 'bold') chunk = `<strong>${chunk}</strong>`;
          else if (f.type === 'italic') chunk = `<em>${chunk}</em>`;
          else if (f.type === 'underline') chunk = `<u>${chunk}</u>`;
          else if (f.type === 'strikethrough') chunk = `<s>${chunk}</s>`;
          else if (f.type === 'link' && f.url) {
            const safeHref = sanitizeHref(f.url);
            if (safeHref) {
              chunk = `<a href="${escapeHtml(safeHref)}">${chunk}</a>`;
            }
          }
        }
        rendered += chunk;
        i = j;
      }
    }

    if (blockFmt?.type === 'bulletList' || blockFmt?.type === 'numberedList') {
      const tag: 'ul' | 'ol' = blockFmt.type === 'bulletList' ? 'ul' : 'ol';
      const level = clampLevel(blockFmt.level);
      const top = openLists[openLists.length - 1];
      if (top && top.level === level && top.tag === tag) {
        out.push(`</li><li>${rendered}`);
      } else if (top && top.level < level) {
        openLists.push({ tag, level });
        out.push(`<${tag}><li>${rendered}`);
      } else {
        closeListsDeeperThan(level);
        const after = openLists[openLists.length - 1];
        if (after && after.level === level && after.tag === tag) {
          out.push(`</li><li>${rendered}`);
        } else {
          if (after && after.level === level) {
            const popped = openLists.pop()!;
            out.push(`</li></${popped.tag}>`);
          }
          openLists.push({ tag, level });
          out.push(`<${tag}><li>${rendered}`);
        }
      }
      continue;
    }

    closeListsDownTo(0);

    if (blockFmt?.type === 'h1') {
      out.push(`<h1>${rendered}</h1>`);
    } else if (blockFmt?.type === 'h2') {
      out.push(`<h2>${rendered}</h2>`);
    } else if (blockFmt?.type === 'h3') {
      out.push(`<h3>${rendered}</h3>`);
    } else if (blockFmt?.type === 'blockquote') {
      out.push(`<blockquote>${rendered}</blockquote>`);
    } else if (blockFmt?.type === 'codeBlock') {
      out.push(`<pre><code>${rendered}</code></pre>`);
    } else if (blockFmt?.type === 'divider') {
      out.push(`<hr data-note-divider="true">`);
    } else if (blockFmt?.type === 'checklist' || blockFmt?.type === 'checklistChecked') {
      const checked = blockFmt.type === 'checklistChecked';
      out.push(
        `<div class="note-todo" data-note-todo="true" data-checked="${checked ? 'true' : 'false'}"><input type="checkbox" class="note-todo-box" contenteditable="false"${checked ? ' checked' : ''}><span class="note-todo-text">${rendered}</span></div>`,
      );
    } else if (blockFmt?.type === 'image' && blockFmt.url) {
      const safeSrc = sanitizeImgSrc(blockFmt.url);
      if (safeSrc) {
        const assetId = extractAssetIdFromSrc(safeSrc);
        out.push(
          `<figure class="note-image-block" contenteditable="false"><img src="${escapeHtml(safeSrc)}" alt="${escapeHtml(line === '[image]' ? '' : line)}"${assetId ? ` data-asset-id="${escapeHtml(assetId)}"` : ''} /></figure>`,
        );
      } else {
        out.push(`<p>${rendered}</p>`);
      }
    } else {
      out.push(`<p>${rendered}</p>`);
    }
  }

  closeListsDownTo(0);
  return out.join('');
}

/**
 * Serializes the contentEditable DOM back to canonical UTF-16 text + formats.
 */
export function serializeDomToNote(rootEl: HTMLElement): {
  text: string;
  formats: RichNoteFormatRange[];
} {
  let text = '';
  const formats: RichNoteFormatRange[] = [];
  let hasOutputBlock = false;

  const startNewLine = () => {
    if (hasOutputBlock) text += '\n';
    hasOutputBlock = true;
  };

  const walkInline = (
    node: Node,
    activeInline: Array<{ type: RichNoteFormatType; url?: string }>,
  ) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const val = (node.nodeValue ?? '').replace(/\u200B/g, '');
      if (!val) return;
      const loc = text.length;
      text += val;
      for (const fmt of activeInline) {
        formats.push({ type: fmt.type, location: loc, length: val.length, url: fmt.url });
      }
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const el = node as HTMLElement;
    const tag = el.tagName.toLowerCase();
    if (tag === 'input' || tag === 'br') return;

    if (tag === 'img') {
      const alt = el.getAttribute('alt') || '[image]';
      const rawSrc = el.getAttribute('data-original-src') || el.getAttribute('src') || '';
      const safeSrc = sanitizeImgSrc(rawSrc);
      const loc = text.length;
      text += alt;
      if (safeSrc) {
        formats.push({ type: 'image', location: loc, length: alt.length, url: safeSrc });
      }
      return;
    }

    const next = [...activeInline];
    if (tag === 'strong' || tag === 'b') next.push({ type: 'bold' });
    else if (tag === 'em' || tag === 'i') next.push({ type: 'italic' });
    else if (tag === 'u') next.push({ type: 'underline' });
    else if (tag === 's' || tag === 'strike' || tag === 'del') next.push({ type: 'strikethrough' });
    else if (tag === 'code') next.push({ type: 'code' });
    else if (tag === 'a') {
      const safeHref = sanitizeHref(el.getAttribute('href') || '');
      if (safeHref) next.push({ type: 'link', url: safeHref });
    }

    for (const child of Array.from(el.childNodes)) {
      walkInline(child, next);
    }
  };

  const walkList = (listEl: HTMLElement, level: number) => {
    const listType: RichNoteFormatType =
      listEl.tagName.toLowerCase() === 'ol' ? 'numberedList' : 'bulletList';
    for (const child of Array.from(listEl.children)) {
      const childTag = child.tagName.toLowerCase();
      if (childTag === 'ul' || childTag === 'ol') {
        walkList(child as HTMLElement, Math.min(5, level + 1));
        continue;
      }
      if (childTag !== 'li') continue;
      startNewLine();
      const itemStart = text.length;
      const nestedLists: HTMLElement[] = [];
      for (const liChild of Array.from(child.childNodes)) {
        if (
          liChild.nodeType === Node.ELEMENT_NODE &&
          ((liChild as HTMLElement).tagName.toLowerCase() === 'ul' ||
            (liChild as HTMLElement).tagName.toLowerCase() === 'ol')
        ) {
          nestedLists.push(liChild as HTMLElement);
        } else {
          walkInline(liChild, []);
        }
      }
      const itemLen = text.length - itemStart;
      formats.push({
        type: listType,
        location: itemStart,
        length: itemLen,
        level: clampLevel(level),
      });
      for (const nested of nestedLists) {
        walkList(nested, Math.min(5, level + 1));
      }
    }
  };

  for (const node of Array.from(rootEl.childNodes)) {
    if (node.nodeType === Node.TEXT_NODE) {
      const val = (node.nodeValue ?? '').replace(/\u200B/g, '');
      if (!val && hasOutputBlock) continue;
      startNewLine();
      text += val;
      continue;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) continue;
    const el = node as HTMLElement;
    const tag = el.tagName.toLowerCase();

    if (tag === 'ul' || tag === 'ol') {
      walkList(el, 0);
      continue;
    }

    if (tag === 'hr') {
      startNewLine();
      const loc = text.length;
      text += '---';
      formats.push({ type: 'divider', location: loc, length: 3 });
      continue;
    }

    if (tag === 'figure' && el.querySelector('img')) {
      const img = el.querySelector('img')!;
      startNewLine();
      walkInline(img, []);
      continue;
    }

    if (el.getAttribute('data-note-todo') === 'true' || el.classList.contains('note-todo')) {
      startNewLine();
      const start = text.length;
      const box = el.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
      const checked = box ? box.checked : el.getAttribute('data-checked') === 'true';
      const textSpan = el.querySelector('.note-todo-text') ?? el;
      walkInline(textSpan, []);
      formats.push({
        type: checked ? 'checklistChecked' : 'checklist',
        location: start,
        length: text.length - start,
      });
      continue;
    }

    if (tag === 'pre') {
      const rawCode = (el.textContent ?? '').replace(/\r\n/g, '\n');
      const codeLines = rawCode.split('\n');
      for (const cl of codeLines) {
        startNewLine();
        const start = text.length;
        text += cl;
        formats.push({ type: 'codeBlock', location: start, length: cl.length });
      }
      continue;
    }

    startNewLine();
    const start = text.length;
    walkInline(el, []);
    const len = text.length - start;
    if (tag === 'h1') formats.push({ type: 'h1', location: start, length: len });
    else if (tag === 'h2') formats.push({ type: 'h2', location: start, length: len });
    else if (tag === 'h3') formats.push({ type: 'h3', location: start, length: len });
    else if (tag === 'blockquote') formats.push({ type: 'blockquote', location: start, length: len });
  }

  return { text, formats };
}

export function noteToMarkdown(doc: RichNoteDocument): string {
  const lines: string[] = [];
  if (doc.title.trim()) {
    lines.push(`# ${doc.title.trim()}`, '');
  }
  const rawLines = doc.text.split('\n');
  let cursor = 0;
  const counters = new Map<number, number>();
  let inCodeBlock = false;

  for (const line of rawLines) {
    const start = cursor;
    const end = start + line.length;
    cursor = end + 1;

    const lineFormats = doc.formats.filter((f) => {
      const fEnd = Math.max(f.location + f.length, f.location + 1);
      return f.location <= start && start < fEnd && BLOCK_TYPES.has(f.type)
        ? true
        : f.location < end && f.location + f.length > start;
    });
    const blockFmt = lineFormats.find((f) => BLOCK_TYPES.has(f.type));
    const inlineFormats = lineFormats.filter((f) => INLINE_TYPES.has(f.type));

    if (blockFmt?.type === 'codeBlock') {
      if (!inCodeBlock) {
        lines.push('```');
        inCodeBlock = true;
      }
      lines.push(line);
      continue;
    } else if (inCodeBlock) {
      lines.push('```');
      inCodeBlock = false;
    }

    if (blockFmt?.type === 'divider') {
      counters.clear();
      lines.push('---');
      continue;
    }

    if (blockFmt?.type === 'image' && blockFmt.url) {
      counters.clear();
      const alt = line === '[image]' ? '' : line;
      lines.push(`![${alt}](${blockFmt.url})`);
      continue;
    }

    let body = '';
    let i = 0;
    while (i < line.length) {
      const abs = start + i;
      const active = inlineFormats.filter((f) => abs >= f.location && abs < f.location + f.length);
      let j = i + 1;
      while (j < line.length) {
        const nextAbs = start + j;
        const nextActive = inlineFormats.filter(
          (f) => nextAbs >= f.location && nextAbs < f.location + f.length,
        );
        if (
          nextActive.length !== active.length ||
          nextActive.some((f, idx) => f !== active[idx])
        ) {
          break;
        }
        j++;
      }
      let chunk = line.slice(i, j);
      const hasCode = active.some((f) => f.type === 'code');
      if (hasCode) {
        chunk = `\`${chunk}\``;
      } else {
        if (active.some((f) => f.type === 'strikethrough')) chunk = `~~${chunk}~~`;
        if (active.some((f) => f.type === 'underline')) chunk = `<u>${chunk}</u>`;
        if (active.some((f) => f.type === 'italic')) chunk = `*${chunk}*`;
        if (active.some((f) => f.type === 'bold')) chunk = `**${chunk}**`;
      }
      const linkFmt = active.find((f) => f.type === 'link' && f.url);
      if (linkFmt?.url) chunk = `[${chunk}](${linkFmt.url})`;
      body += chunk;
      i = j;
    }

    const level = clampLevel(blockFmt?.level);
    if (blockFmt?.type === 'h1') {
      counters.clear();
      lines.push(`## ${body}`);
    } else if (blockFmt?.type === 'h2') {
      counters.clear();
      lines.push(`### ${body}`);
    } else if (blockFmt?.type === 'h3') {
      counters.clear();
      lines.push(`#### ${body}`);
    } else if (blockFmt?.type === 'blockquote') {
      counters.clear();
      lines.push(`> ${body}`);
    } else if (blockFmt?.type === 'bulletList') {
      lines.push(`${'  '.repeat(level)}- ${body}`);
    } else if (blockFmt?.type === 'numberedList') {
      const n = (counters.get(level) ?? 0) + 1;
      counters.set(level, n);
      for (const k of Array.from(counters.keys())) {
        if (k > level) counters.delete(k);
      }
      lines.push(`${'   '.repeat(level)}${n}. ${body}`);
    } else if (blockFmt?.type === 'checklist') {
      counters.clear();
      lines.push(`- [ ] ${body}`);
    } else if (blockFmt?.type === 'checklistChecked') {
      counters.clear();
      lines.push(`- [x] ${body}`);
    } else {
      counters.clear();
      lines.push(body);
    }
  }

  if (inCodeBlock) lines.push('```');
  return `${lines.join('\n').trimEnd()}\n`;
}
