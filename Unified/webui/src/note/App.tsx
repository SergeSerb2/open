import type { JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { type NoteDocument, type NoteFormatRange, rpc } from '../shared/bridge';
import { Badge, Modal, Toast } from '../shared/components';
import { OpenDoorwayMark } from '../shared/icons';

function escape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function sanitizeHref(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  try {
    const parsed = new URL(trimmed);
    if (
      parsed.protocol === 'http:' ||
      parsed.protocol === 'https:' ||
      parsed.protocol === 'mailto:'
    ) {
      return parsed.href;
    }
  } catch {
    return null;
  }
  return null;
}

function sanitizeImgSrc(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  if (trimmed.startsWith('//')) return null;
  const hasScheme = /^[a-zA-Z][a-zA-Z\d+\-.]*:/.test(trimmed);
  if (!hasScheme) {
    return trimmed;
  }
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol === 'data:' || parsed.protocol === 'blob:') {
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

/**
 * Render NoteDocument (plain UTF-16 text + format ranges) to clean HTML for the rich editor.
 */
function noteDocToHtml(doc: NoteDocument): string {
  const lines = doc.text.split('\n');
  let cursor = 0;
  const htmlBlocks: string[] = [];

  for (const line of lines) {
    const start = cursor;
    const end = start + line.length;
    cursor = end + 1;

    const lineFormats = doc.formats.filter((f) => f.location < end && f.location + f.length > start);
    const blockFmt = lineFormats.find((f) =>
      f.type === 'h1' || f.type === 'h2' || f.type === 'h3' || f.type === 'bulletList' || f.type === 'numberedList' || f.type === 'image',
    );

    const inlineFormats = lineFormats.filter(
      (f) => f.type === 'bold' || f.type === 'italic' || f.type === 'underline' || f.type === 'strikethrough' || f.type === 'link',
    );

    // Apply character-level inline wrapping using UTF-16 offsets
    let rendered = '';
    if (line.length === 0) {
      rendered = '<br>';
    } else {
      let i = 0;
      while (i < line.length) {
        const abs = start + i;
        const active = inlineFormats.filter((f) => abs >= f.location && abs < f.location + f.length);
        let j = i + 1;
        while (j < line.length) {
          const nextAbs = start + j;
          const nextActive = inlineFormats.filter((f) => nextAbs >= f.location && nextAbs < f.location + f.length);
          if (nextActive.length !== active.length || nextActive.some((f, idx) => f !== active[idx])) break;
          j++;
        }
        let chunk = escape(line.slice(i, j));
        for (const f of active) {
          if (f.type === 'bold') chunk = `<strong>${chunk}</strong>`;
          else if (f.type === 'italic') chunk = `<em>${chunk}</em>`;
          else if (f.type === 'underline') chunk = `<u>${chunk}</u>`;
          else if (f.type === 'strikethrough') chunk = `<s>${chunk}</s>`;
          else if (f.type === 'link' && f.url) {
            const safeHref = sanitizeHref(f.url);
            if (safeHref) {
              chunk = `<a href="${escape(safeHref)}">${chunk}</a>`;
            }
          }
        }
        rendered += chunk;
        i = j;
      }
    }

    if (blockFmt?.type === 'h1') htmlBlocks.push(`<h1>${rendered}</h1>`);
    else if (blockFmt?.type === 'h2') htmlBlocks.push(`<h2>${rendered}</h2>`);
    else if (blockFmt?.type === 'h3') htmlBlocks.push(`<h3>${rendered}</h3>`);
    else if (blockFmt?.type === 'bulletList') htmlBlocks.push(`<ul><li>${rendered}</li></ul>`);
    else if (blockFmt?.type === 'numberedList') htmlBlocks.push(`<ol><li>${rendered}</li></ol>`);
    else if (blockFmt?.type === 'image' && blockFmt.url) {
      const safeSrc = sanitizeImgSrc(blockFmt.url);
      if (safeSrc) {
        htmlBlocks.push(`<p><img src="${escape(safeSrc)}" alt="${escape(line || 'Image')}" /></p>`);
      } else {
        htmlBlocks.push(`<p>${rendered}</p>`);
      }
    } else {
      htmlBlocks.push(`<p>${rendered}</p>`);
    }
  }

  return htmlBlocks.join('');
}

/**
 * Serialize contentEditable DOM back to canonical UTF-16 NoteDocument (text + NoteFormatRange[]).
 * JavaScript strings are UTF-16 code units natively, so string.length is exact UTF-16 offset/length.
 */
function serializeDomToNote(rootEl: HTMLElement): { text: string; formats: NoteFormatRange[] } {
  let text = '';
  const formats: NoteFormatRange[] = [];

  const walkInline = (node: Node, activeInline: Array<{ type: NoteFormatRange['type']; url?: string }>) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const val = node.nodeValue ?? '';
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

    if (tag === 'img') {
      const alt = el.getAttribute('alt') || '[image]';
      const safeSrc = sanitizeImgSrc(el.getAttribute('src') || '');
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
    else if (tag === 'a') {
      const safeHref = sanitizeHref(el.getAttribute('href') || '');
      if (safeHref) next.push({ type: 'link', url: safeHref });
    }

    for (const child of Array.from(el.childNodes)) {
      walkInline(child, next);
    }
  };

  const blocks = Array.from(rootEl.childNodes);
  blocks.forEach((node, idx) => {
    const start = text.length;
    if (node.nodeType === Node.TEXT_NODE) {
      text += node.nodeValue ?? '';
    } else if (node.nodeType === Node.ELEMENT_NODE) {
      const el = node as HTMLElement;
      const tag = el.tagName.toLowerCase();
      if (tag === 'ul' || tag === 'ol') {
        const listType: NoteFormatRange['type'] = tag === 'ul' ? 'bulletList' : 'numberedList';
        const items = Array.from(el.querySelectorAll(':scope > li'));
        items.forEach((li, liIdx) => {
          const itemStart = text.length;
          walkInline(li, []);
          const itemLen = text.length - itemStart;
          if (itemLen > 0) {
            formats.push({ type: listType, location: itemStart, length: itemLen, level: 1 });
          }
          if (liIdx < items.length - 1) text += '\n';
        });
      } else {
        walkInline(el, []);
        const len = text.length - start;
        if (len > 0) {
          if (tag === 'h1') formats.push({ type: 'h1', location: start, length: len });
          else if (tag === 'h2') formats.push({ type: 'h2', location: start, length: len });
          else if (tag === 'h3') formats.push({ type: 'h3', location: start, length: len });
        }
      }
    }
    if (idx < blocks.length - 1) text += '\n';
  });

  return { text, formats };
}

export function NoteApp(): JSX.Element {
  const [doc, setDoc] = useState<NoteDocument | null>(null);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [showRanges, setShowRanges] = useState(false);
  const [linkModalOpen, setLinkModalOpen] = useState(false);
  const [linkUrl, setLinkUrl] = useState('https://');
  const [imageModalOpen, setImageModalOpen] = useState(false);
  const [imageUrl, setImageUrl] = useState('');
  const [toast, setToast] = useState<string | null>(null);

  const editorRef = useRef<HTMLDivElement | null>(null);
  const saveTimerRef = useRef<number | null>(null);
  const hydratedRef = useRef(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2200);
  };

  useEffect(() => {
    const idFromPath = window.location.pathname.replace(/^\/+/, '').split('/')[1] || window.location.hash.replace(/^#/, '');
    void rpc('note.load', { id: idFromPath || undefined }).then((res) => {
      setDoc(res.document);
    });
  }, []);

  useEffect(() => {
    if (doc && editorRef.current && !hydratedRef.current) {
      editorRef.current.innerHTML = noteDocToHtml(doc);
      hydratedRef.current = true;
    }
  }, [doc]);

  const scheduleSave = (nextDoc: NoteDocument) => {
    setSaveState('saving');
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      void rpc('note.save', { document: nextDoc }).then(() => setSaveState('saved'));
    }, 450);
  };

  const syncFromEditor = () => {
    if (!doc || !editorRef.current) return;
    const { text, formats } = serializeDomToNote(editorRef.current);
    const nextDoc: NoteDocument = { ...doc, text, formats };
    setDoc(nextDoc);
    scheduleSave(nextDoc);
  };

  const execFormat = (cmd: string, value?: string) => {
    editorRef.current?.focus();
    document.execCommand(cmd, false, value);
    syncFromEditor();
  };

  if (!doc) return <div style={{ padding: '32px' }}>Loading Note…</div>;

  const words = doc.text.trim() ? doc.text.trim().split(/\s+/).length : 0;

  return (
    <div class="note-shell">
      <header class="note-topbar">
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <OpenDoorwayMark size={24} />
          <div class="note-toolbar" role="toolbar" aria-label="Note formatting">
            <button type="button" class="note-tool-btn" title="Bold" onClick={() => execFormat('bold')}>
              <strong>B</strong>
            </button>
            <button type="button" class="note-tool-btn" title="Italic" onClick={() => execFormat('italic')}>
              <em>I</em>
            </button>
            <button type="button" class="note-tool-btn" title="Underline" onClick={() => execFormat('underline')}>
              <u>U</u>
            </button>
            <button type="button" class="note-tool-btn" title="Strikethrough" onClick={() => execFormat('strikeThrough')}>
              <s>S</s>
            </button>
            <span class="note-tool-sep" />
            <button type="button" class="note-tool-btn" onClick={() => execFormat('formatBlock', 'H1')}>
              H1
            </button>
            <button type="button" class="note-tool-btn" onClick={() => execFormat('formatBlock', 'H2')}>
              H2
            </button>
            <button type="button" class="note-tool-btn" onClick={() => execFormat('formatBlock', 'H3')}>
              H3
            </button>
            <span class="note-tool-sep" />
            <button type="button" class="note-tool-btn" onClick={() => execFormat('insertUnorderedList')}>
              • List
            </button>
            <button type="button" class="note-tool-btn" onClick={() => execFormat('insertOrderedList')}>
              1. List
            </button>
            <span class="note-tool-sep" />
            <button type="button" class="note-tool-btn" onClick={() => setLinkModalOpen(true)}>
              Link
            </button>
            <button type="button" class="note-tool-btn" onClick={() => setImageModalOpen(true)}>
              Image
            </button>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <button type="button" class="open-btn open-btn-ghost" onClick={() => setShowRanges((s) => !s)}>
            {showRanges ? 'Hide UTF-16 Ranges' : `Ranges (${doc.formats.length})`}
          </button>
          <Badge tone={saveState === 'saved' ? 'success' : 'accent'}>
            {saveState === 'saved' ? 'Saved' : 'Saving…'}
          </Badge>
        </div>
      </header>

      <main class="note-page">
        <input
          class="note-title-input"
          aria-label="Note title"
          placeholder="Untitled Note"
          value={doc.title}
          onInput={(e) => {
            const nextDoc = { ...doc, title: (e.currentTarget as HTMLInputElement).value };
            setDoc(nextDoc);
            scheduleSave(nextDoc);
          }}
        />

        <div
          ref={editorRef}
          class="note-editor-surface"
          contentEditable
          role="textbox"
          aria-multiline="true"
          aria-label="Note content"
          onInput={syncFromEditor}
        />

        <div class="note-meta-bar">
          <span>
            {words} word{words === 1 ? '' : 's'} · {doc.text.length} UTF-16 code units
          </span>
          <span>NoteDocument v{doc.format_version}</span>
        </div>

        {showRanges && (
          <pre
            style={{
              background: 'var(--bg-card)',
              border: '1px solid var(--border-subtle)',
              borderRadius: '10px',
              padding: '12px',
              fontSize: '11.5px',
              fontFamily: 'var(--font-mono)',
              overflowX: 'auto',
              margin: 0,
            }}
          >
            {JSON.stringify(doc.formats, null, 2)}
          </pre>
        )}
      </main>

      <Modal
        open={linkModalOpen}
        title="Insert Link"
        onClose={() => setLinkModalOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setLinkModalOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              onClick={() => {
                const safeHref = sanitizeHref(linkUrl);
                if (safeHref) {
                  execFormat('createLink', safeHref);
                  showToast('Inserted link.');
                  setLinkModalOpen(false);
                } else {
                  showToast('Only http:, https:, and mailto: links are allowed.');
                }
              }}
            >
              Insert
            </button>
          </>
        }
      >
        <input
          class="open-input"
          value={linkUrl}
          placeholder="https://example.com"
          onInput={(e) => setLinkUrl((e.currentTarget as HTMLInputElement).value)}
        />
      </Modal>

      <Modal
        open={imageModalOpen}
        title="Insert Image URL"
        onClose={() => setImageModalOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setImageModalOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              onClick={() => {
                const safeSrc = sanitizeImgSrc(imageUrl);
                if (safeSrc) {
                  execFormat('insertImage', safeSrc);
                  showToast('Inserted image.');
                  setImageModalOpen(false);
                  setImageUrl('');
                } else {
                  showToast('Only data:, blob:, or local/same-origin image URLs are allowed.');
                }
              }}
            >
              Insert Image
            </button>
          </>
        }
      >
        <input
          class="open-input"
          value={imageUrl}
          placeholder="https://example.com/image.png"
          onInput={(e) => setImageUrl((e.currentTarget as HTMLInputElement).value)}
        />
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
