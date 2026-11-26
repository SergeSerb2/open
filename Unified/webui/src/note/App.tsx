import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { Modal, Toast } from '../shared/components';
import { OpenDoorwayMark, RedoIcon, UndoIcon } from '../shared/icons';
import { replacePageRoute } from '../shared/route';
import {
  duplicateNote,
  exportNoteHtml,
  exportNoteMarkdown,
  loadNote,
  openNoteUrl,
  readNoteAsset,
  renameNote,
  resolveNoteIdFromLocation,
  saveNote,
  uploadNoteAsset,
} from './documentsRpc';
import {
  escapeHtml,
  extractAssetIdFromSrc,
  noteDocToHtml,
  noteToMarkdown,
  sanitizeHref,
  serializeDomToNote,
  type RichNoteDocument,
} from './noteCodec';

interface SlashCommand {
  id: string;
  label: string;
  hint: string;
  keywords: string;
}

const SLASH_COMMANDS: readonly SlashCommand[] = [
  { id: 'h1', label: 'Heading 1', hint: '# ', keywords: 'heading h1 title large' },
  { id: 'h2', label: 'Heading 2', hint: '## ', keywords: 'heading h2 subtitle medium' },
  { id: 'h3', label: 'Heading 3', hint: '### ', keywords: 'heading h3 small' },
  { id: 'checklist', label: 'Task Checklist', hint: '- [ ]', keywords: 'todo task checkbox check list' },
  { id: 'bullet', label: 'Bullet List', hint: '- ', keywords: 'bullet unordered list' },
  { id: 'numbered', label: 'Numbered List', hint: '1. ', keywords: 'numbered ordered list' },
  { id: 'blockquote', label: 'Blockquote', hint: '> ', keywords: 'quote callout blockquote' },
  { id: 'codeblock', label: 'Code Block', hint: '```', keywords: 'code pre snippet fence' },
  { id: 'divider', label: 'Horizontal Divider', hint: '---', keywords: 'divider hr line separator' },
  { id: 'image', label: 'Insert Image', hint: 'img', keywords: 'image photo picture upload' },
];

interface ActiveFormats {
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  code: boolean;
  h1: boolean;
  h2: boolean;
  h3: boolean;
  blockquote: boolean;
  codeBlock: boolean;
  bulletList: boolean;
  numberedList: boolean;
  checklist: boolean;
}

const EMPTY_FORMATS: ActiveFormats = {
  bold: false,
  italic: false,
  underline: false,
  strike: false,
  code: false,
  h1: false,
  h2: false,
  h3: false,
  blockquote: false,
  codeBlock: false,
  bulletList: false,
  numberedList: false,
  checklist: false,
};

function readFileAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Could not read file'));
    reader.onload = () => resolve(String(reader.result || ''));
    reader.readAsDataURL(file);
  });
}

function getCurrentBlockElement(editor: HTMLElement): HTMLElement | null {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return null;
  let node: Node | null = sel.anchorNode;
  while (node && node !== editor) {
    if (node.nodeType === Node.ELEMENT_NODE) {
      const el = node as HTMLElement;
      const tag = el.tagName.toLowerCase();
      if (
        tag === 'p' ||
        tag === 'div' ||
        tag === 'h1' ||
        tag === 'h2' ||
        tag === 'h3' ||
        tag === 'blockquote' ||
        tag === 'pre' ||
        tag === 'li'
      ) {
        return el;
      }
    }
    node = node.parentNode;
  }
  return null;
}

function placeCaretAtEnd(el: HTMLElement): void {
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  if (sel) {
    sel.removeAllRanges();
    sel.addRange(range);
  }
}

export function NoteApp(): JSX.Element {
  const [doc, setDoc] = useState<RichNoteDocument | null>(null);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [activeFormats, setActiveFormats] = useState<ActiveFormats>(EMPTY_FORMATS);
  const [floatingBar, setFloatingBar] = useState<{ x: number; y: number } | null>(null);
  const [slashMenu, setSlashMenu] = useState<{ x: number; y: number; query: string; index: number } | null>(null);
  const [exportMenuOpen, setExportMenuOpen] = useState(false);
  const [linkModalOpen, setLinkModalOpen] = useState(false);
  const [linkUrl, setLinkUrl] = useState('https://');
  const [dropActive, setDropActive] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [undoStack, setUndoStack] = useState<string[]>([]);
  const [redoStack, setRedoStack] = useState<string[]>([]);

  const editorRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const savedRangeRef = useRef<Range | null>(null);
  const saveTimerRef = useRef<number | null>(null);
  const hydratedRef = useRef(false);
  const lastHtmlRef = useRef<string>('');
  const docRef = useRef<RichNoteDocument | null>(null);

  docRef.current = doc;

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2400);
  }, []);

  const scheduleSave = useCallback((nextDoc: RichNoteDocument) => {
    setSaveState('saving');
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      void saveNote(nextDoc)
        .then((res) => {
          setSaveState('saved');
          setDoc((cur) => (cur && cur.id === nextDoc.id ? { ...cur, modified_at: res.modified_at } : cur));
        })
        .catch(() => setSaveState('saved'));
    }, 450);
  }, []);

  // Load note using fixed [0] path parser.
  useEffect(() => {
    const idFromUrl = resolveNoteIdFromLocation();
    void loadNote(idFromUrl).then((res) => {
      const loaded = res.document;
      setDoc(loaded);
      document.title = loaded.title || 'Untitled Note';
      if (loaded.id && idFromUrl !== loaded.id) {
        replacePageRoute(loaded.id);
      }
    });
  }, []);

  // Attach image error fallback (loads asset via documents.readAsset if open://note/asset route is pending).
  const hydrateBrokenImages = useCallback(() => {
    const editor = editorRef.current;
    const cur = docRef.current;
    if (!editor || !cur) return;
    for (const img of Array.from(editor.querySelectorAll('img'))) {
      if (img.dataset.fallbackBound) continue;
      img.dataset.fallbackBound = '1';
      img.addEventListener('error', () => {
        const assetId = img.dataset.assetId || extractAssetIdFromSrc(img.getAttribute('src') || '');
        if (!assetId || img.dataset.fallbackTried) return;
        img.dataset.fallbackTried = '1';
        img.setAttribute('data-original-src', img.getAttribute('src') || '');
        void readNoteAsset(cur.id, assetId).then((res) => {
          if (res?.dataUrl) img.src = res.dataUrl;
        });
      });
    }
  }, []);

  useEffect(() => {
    if (doc && editorRef.current && !hydratedRef.current) {
      const html = noteDocToHtml(doc);
      editorRef.current.innerHTML = html;
      lastHtmlRef.current = html;
      hydratedRef.current = true;
      hydrateBrokenImages();
    }
  }, [doc, hydrateBrokenImages]);

  const syncFromEditor = useCallback(
    (pushUndo = true) => {
      const cur = docRef.current;
      const editor = editorRef.current;
      if (!cur || !editor) return;
      const currentHtml = editor.innerHTML;
      if (pushUndo && currentHtml !== lastHtmlRef.current) {
        setUndoStack((prev) => [...prev.slice(-49), lastHtmlRef.current]);
        setRedoStack([]);
      }
      lastHtmlRef.current = currentHtml;
      hydrateBrokenImages();
      const { text, formats } = serializeDomToNote(editor);
      const nextDoc: RichNoteDocument = { ...cur, text, formats };
      setDoc(nextDoc);
      scheduleSave(nextDoc);
    },
    [hydrateBrokenImages, scheduleSave],
  );

  const handleUndo = useCallback(() => {
    const editor = editorRef.current;
    if (!editor || undoStack.length === 0) return;
    const prevHtml = undoStack[undoStack.length - 1]!;
    setUndoStack((s) => s.slice(0, -1));
    setRedoStack((r) => [...r, editor.innerHTML]);
    editor.innerHTML = prevHtml;
    lastHtmlRef.current = prevHtml;
    syncFromEditor(false);
  }, [undoStack, syncFromEditor]);

  const handleRedo = useCallback(() => {
    const editor = editorRef.current;
    if (!editor || redoStack.length === 0) return;
    const nextHtml = redoStack[redoStack.length - 1]!;
    setRedoStack((r) => r.slice(0, -1));
    setUndoStack((s) => [...s, editor.innerHTML]);
    editor.innerHTML = nextHtml;
    lastHtmlRef.current = nextHtml;
    syncFromEditor(false);
  }, [redoStack, syncFromEditor]);

  const updateActiveFormats = useCallback(() => {
    const editor = editorRef.current;
    const sel = window.getSelection();
    if (!editor || !sel || sel.rangeCount === 0 || !editor.contains(sel.anchorNode)) {
      setFloatingBar(null);
      return;
    }

    const block = getCurrentBlockElement(editor);
    const blockTag = block?.tagName.toLowerCase() ?? '';
    let node: Node | null = sel.anchorNode;
    let inCode = false;
    let inTodo = false;
    while (node && node !== editor) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        const el = node as HTMLElement;
        if (el.tagName.toLowerCase() === 'code' && el.parentElement?.tagName.toLowerCase() !== 'pre') inCode = true;
        if (el.classList.contains('note-todo') || el.getAttribute('data-note-todo') === 'true') inTodo = true;
      }
      node = node.parentNode;
    }

    setActiveFormats({
      bold: document.queryCommandState('bold'),
      italic: document.queryCommandState('italic'),
      underline: document.queryCommandState('underline'),
      strike: document.queryCommandState('strikeThrough'),
      code: inCode,
      h1: blockTag === 'h1',
      h2: blockTag === 'h2',
      h3: blockTag === 'h3',
      blockquote: blockTag === 'blockquote',
      codeBlock: blockTag === 'pre',
      bulletList: document.queryCommandState('insertUnorderedList'),
      numberedList: document.queryCommandState('insertOrderedList'),
      checklist: inTodo,
    });

    if (!sel.isCollapsed && sel.toString().trim().length > 0) {
      const rect = sel.getRangeAt(0).getBoundingClientRect();
      if (rect.width > 0 || rect.height > 0) {
        setFloatingBar({
          x: Math.max(150, Math.min(window.innerWidth - 150, rect.left + rect.width / 2)),
          y: Math.max(60, rect.top - 10),
        });
      }
    } else {
      setFloatingBar(null);
    }
  }, []);

  useEffect(() => {
    document.addEventListener('selectionchange', updateActiveFormats);
    return () => document.removeEventListener('selectionchange', updateActiveFormats);
  }, [updateActiveFormats]);

  const insertHtmlAtCaret = useCallback(
    (html: string) => {
      const editor = editorRef.current;
      if (!editor) return;
      editor.focus();
      document.execCommand('insertHTML', false, html);
      syncFromEditor(true);
      updateActiveFormats();
    },
    [syncFromEditor, updateActiveFormats],
  );

  const toggleBlock = useCallback(
    (tag: 'H1' | 'H2' | 'H3' | 'BLOCKQUOTE' | 'P') => {
      const editor = editorRef.current;
      if (!editor) return;
      editor.focus();
      const curBlock = getCurrentBlockElement(editor);
      const nextTag = curBlock?.tagName.toUpperCase() === tag ? 'P' : tag;
      document.execCommand('formatBlock', false, nextTag);
      syncFromEditor(true);
      updateActiveFormats();
    },
    [syncFromEditor, updateActiveFormats],
  );

  const toggleInlineCode = useCallback(() => {
    const editor = editorRef.current;
    const sel = window.getSelection();
    if (!editor || !sel || sel.rangeCount === 0) return;
    const range = sel.getRangeAt(0);
    const parentEl =
      range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
        ? (range.commonAncestorContainer as HTMLElement)
        : range.commonAncestorContainer.parentElement;
    const existingCode = parentEl?.closest('code');
    if (existingCode && editor.contains(existingCode) && existingCode.parentElement?.tagName.toLowerCase() !== 'pre') {
      const textNode = document.createTextNode(existingCode.textContent ?? '');
      existingCode.replaceWith(textNode);
      syncFromEditor(true);
      updateActiveFormats();
      return;
    }
    const text = sel.toString() || 'code';
    insertHtmlAtCaret(`<code>${escapeHtml(text)}</code>&nbsp;`);
  }, [insertHtmlAtCaret, syncFromEditor, updateActiveFormats]);

  const insertChecklistItem = useCallback(
    (checked = false, initialText = '', replaceBlock?: HTMLElement | null) => {
      const editor = editorRef.current;
      if (!editor) return;
      const div = document.createElement('div');
      div.className = 'note-todo';
      div.setAttribute('data-note-todo', 'true');
      div.setAttribute('data-checked', checked ? 'true' : 'false');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.className = 'note-todo-box';
      box.contentEditable = 'false';
      box.checked = checked;
      const span = document.createElement('span');
      span.className = 'note-todo-text';
      if (initialText) span.textContent = initialText;
      else span.innerHTML = '<br>';
      div.appendChild(box);
      div.appendChild(span);

      if (replaceBlock && editor.contains(replaceBlock)) {
        replaceBlock.replaceWith(div);
      } else {
        const curBlock = getCurrentBlockElement(editor);
        if (curBlock && editor.contains(curBlock)) {
          curBlock.after(div);
        } else {
          editor.appendChild(div);
        }
      }
      placeCaretAtEnd(span);
      syncFromEditor(true);
      updateActiveFormats();
    },
    [syncFromEditor, updateActiveFormats],
  );

  const insertCodeBlock = useCallback(
    (replaceBlock?: HTMLElement | null) => {
      const editor = editorRef.current;
      if (!editor) return;
      const pre = document.createElement('pre');
      const code = document.createElement('code');
      code.innerHTML = '<br>';
      pre.appendChild(code);
      if (replaceBlock && editor.contains(replaceBlock)) {
        replaceBlock.replaceWith(pre);
      } else {
        const curBlock = getCurrentBlockElement(editor);
        if (curBlock && editor.contains(curBlock)) curBlock.after(pre);
        else editor.appendChild(pre);
      }
      placeCaretAtEnd(code);
      syncFromEditor(true);
      updateActiveFormats();
    },
    [syncFromEditor, updateActiveFormats],
  );

  const insertDivider = useCallback(
    (replaceBlock?: HTMLElement | null) => {
      const editor = editorRef.current;
      if (!editor) return;
      const hr = document.createElement('hr');
      hr.setAttribute('data-note-divider', 'true');
      const nextP = document.createElement('p');
      nextP.innerHTML = '<br>';
      if (replaceBlock && editor.contains(replaceBlock)) {
        replaceBlock.replaceWith(hr);
        hr.after(nextP);
      } else {
        const curBlock = getCurrentBlockElement(editor);
        if (curBlock && editor.contains(curBlock)) {
          curBlock.after(hr);
          hr.after(nextP);
        } else {
          editor.appendChild(hr);
          editor.appendChild(nextP);
        }
      }
      placeCaretAtEnd(nextP);
      syncFromEditor(true);
    },
    [syncFromEditor],
  );

  const insertUploadedImage = useCallback(
    async (file: File) => {
      const cur = docRef.current;
      const editor = editorRef.current;
      if (!cur || !editor) return;
      try {
        const dataUrl = await readFileAsDataUrl(file);
        const uploaded = await uploadNoteAsset({
          docId: cur.id,
          mimeType: file.type || 'image/png',
          data: dataUrl,
          filename: file.name,
        });
        const fig = document.createElement('figure');
        fig.className = 'note-image-block';
        fig.contentEditable = 'false';
        const img = document.createElement('img');
        img.src = uploaded.dataUrl || uploaded.url;
        img.alt = file.name || 'Image';
        img.setAttribute('data-asset-id', uploaded.assetId);
        img.setAttribute('data-original-src', uploaded.url);
        fig.appendChild(img);
        const nextP = document.createElement('p');
        nextP.innerHTML = '<br>';

        const curBlock = getCurrentBlockElement(editor);
        if (curBlock && editor.contains(curBlock)) {
          curBlock.after(fig);
          fig.after(nextP);
        } else {
          editor.appendChild(fig);
          editor.appendChild(nextP);
        }
        placeCaretAtEnd(nextP);
        syncFromEditor(true);
        showToast('Image embedded in Note');
      } catch (err) {
        showToast(err instanceof Error ? err.message : 'Could not upload image');
      }
    },
    [syncFromEditor, showToast],
  );

  const execFormat = useCallback(
    (cmd: string, value?: string) => {
      editorRef.current?.focus();
      document.execCommand(cmd, false, value);
      syncFromEditor(true);
      updateActiveFormats();
    },
    [syncFromEditor, updateActiveFormats],
  );

  const filteredSlashCommands = useMemo(() => {
    if (!slashMenu) return [];
    const q = slashMenu.query.trim().toLowerCase();
    if (!q) return SLASH_COMMANDS;
    return SLASH_COMMANDS.filter(
      (c) => c.label.toLowerCase().includes(q) || c.keywords.includes(q) || c.id.includes(q),
    );
  }, [slashMenu]);

  const executeSlashCommand = useCallback(
    (cmd: SlashCommand) => {
      const editor = editorRef.current;
      if (!editor) return;
      const block = getCurrentBlockElement(editor);
      if (block) {
        const cleaned = (block.textContent ?? '').replace(/\/[^\s]*$/, '');
        block.textContent = cleaned;
        placeCaretAtEnd(block);
      }
      setSlashMenu(null);

      if (cmd.id === 'h1') toggleBlock('H1');
      else if (cmd.id === 'h2') toggleBlock('H2');
      else if (cmd.id === 'h3') toggleBlock('H3');
      else if (cmd.id === 'blockquote') toggleBlock('BLOCKQUOTE');
      else if (cmd.id === 'bullet') execFormat('insertUnorderedList');
      else if (cmd.id === 'numbered') execFormat('insertOrderedList');
      else if (cmd.id === 'checklist') insertChecklistItem(false, '', block && !block.textContent?.trim() ? block : null);
      else if (cmd.id === 'codeblock') insertCodeBlock(block && !block.textContent?.trim() ? block : null);
      else if (cmd.id === 'divider') insertDivider(block && !block.textContent?.trim() ? block : null);
      else if (cmd.id === 'image') fileInputRef.current?.click();
    },
    [toggleBlock, execFormat, insertChecklistItem, insertCodeBlock, insertDivider],
  );

  // Check for live Markdown block & inline triggers on input.
  const handleEditorInput = useCallback(() => {
    const editor = editorRef.current;
    if (!editor) return;
    const sel = window.getSelection();
    const block = getCurrentBlockElement(editor);

    // 1. Slash command detection
    if (sel && sel.isCollapsed && sel.anchorNode?.nodeType === Node.TEXT_NODE) {
      const textBefore = (sel.anchorNode.nodeValue ?? '').slice(0, sel.anchorOffset);
      const slashMatch = textBefore.match(/(?:^|\s)\/([a-zA-Z0-9]*)$/);
      if (slashMatch) {
        const rect = sel.getRangeAt(0).getBoundingClientRect();
        setSlashMenu({
          x: Math.min(window.innerWidth - 264, Math.max(16, rect.left)),
          y: Math.min(window.innerHeight - 260, rect.bottom + 6),
          query: slashMatch[1] ?? '',
          index: 0,
        });
      } else if (slashMenu) {
        setSlashMenu(null);
      }
    } else if (slashMenu) {
      setSlashMenu(null);
    }

    // 2. Live Markdown block shortcuts at start of a paragraph
    if (block && (block.tagName.toLowerCase() === 'p' || block.tagName.toLowerCase() === 'div') && !block.classList.contains('note-todo')) {
      const raw = (block.textContent ?? '').replace(/\u00A0/g, ' ');
      if (raw === '# ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('formatBlock', false, 'H1');
      } else if (raw === '## ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('formatBlock', false, 'H2');
      } else if (raw === '### ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('formatBlock', false, 'H3');
      } else if (raw === '> ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('formatBlock', false, 'BLOCKQUOTE');
      } else if (raw === '- ' || raw === '* ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('insertUnorderedList');
      } else if (raw === '1. ') {
        block.textContent = '';
        placeCaretAtEnd(block);
        document.execCommand('insertOrderedList');
      } else if (raw === '[] ' || raw === '[ ] ' || raw === '- [ ] ') {
        insertChecklistItem(false, '', block);
        return;
      } else if (raw === '[x] ' || raw === '[X] ' || raw === '- [x] ') {
        insertChecklistItem(true, '', block);
        return;
      } else if (raw === '``` ' || raw === '```') {
        insertCodeBlock(block);
        return;
      } else if (raw === '--- ' || raw === '*** ') {
        insertDivider(block);
        return;
      }
    }

    // 3. Inline Markdown shortcuts (**bold**, *italic*, ~~strike~~, `code`)
    if (sel && sel.isCollapsed && sel.anchorNode?.nodeType === Node.TEXT_NODE) {
      const textNode = sel.anchorNode as Text;
      if (!textNode.parentElement?.closest('pre, code')) {
        const before = (textNode.nodeValue ?? '').slice(0, sel.anchorOffset);
        const patterns: Array<{ re: RegExp; tag: string }> = [
          { re: /\*\*([^*]+)\*\*$/, tag: 'strong' },
          { re: /~~([^~]+)~~$/, tag: 's' },
          { re: /`([^`]+)`$/, tag: 'code' },
          { re: /(?<!\*)\*([^*]+)\*$/, tag: 'em' },
        ];
        for (const p of patterns) {
          const m = before.match(p.re);
          if (m && m[1]) {
            const fullLen = m[0].length;
            const range = document.createRange();
            range.setStart(textNode, sel.anchorOffset - fullLen);
            range.setEnd(textNode, sel.anchorOffset);
            range.deleteContents();
            const styled = document.createElement(p.tag);
            styled.textContent = m[1];
            const spacer = document.createTextNode('\u200B');
            range.insertNode(spacer);
            range.insertNode(styled);
            const after = document.createRange();
            after.setStartAfter(spacer);
            after.collapse(true);
            sel.removeAllRanges();
            sel.addRange(after);
            break;
          }
        }
      }
    }

    syncFromEditor(true);
    updateActiveFormats();
  }, [slashMenu, insertChecklistItem, insertCodeBlock, insertDivider, syncFromEditor, updateActiveFormats]);

  const handleEditorKeyDown = (e: KeyboardEvent) => {
    const mod = e.metaKey || e.ctrlKey;

    // Slash menu keyboard navigation
    if (slashMenu && filteredSlashCommands.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        setSlashMenu((m) => (m ? { ...m, index: (m.index + 1) % filteredSlashCommands.length } : null));
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        setSlashMenu((m) =>
          m ? { ...m, index: (m.index - 1 + filteredSlashCommands.length) % filteredSlashCommands.length } : null,
        );
        return;
      }
      if (e.key === 'Enter') {
        e.preventDefault();
        const chosen = filteredSlashCommands[slashMenu.index] ?? filteredSlashCommands[0];
        if (chosen) executeSlashCommand(chosen);
        return;
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        setSlashMenu(null);
        return;
      }
    }

    if (mod && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      if (e.shiftKey) handleRedo();
      else handleUndo();
      return;
    }

    if (mod && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      const sel = window.getSelection();
      if (sel && sel.rangeCount > 0) savedRangeRef.current = sel.getRangeAt(0).cloneRange();
      setLinkUrl('https://');
      setLinkModalOpen(true);
      return;
    }

    if (mod && e.key.toLowerCase() === 'e') {
      e.preventDefault();
      toggleInlineCode();
      return;
    }

    // Tab / Shift+Tab list nesting (levels 0..5)
    if (e.key === 'Tab') {
      const editor = editorRef.current;
      const block = editor ? getCurrentBlockElement(editor) : null;
      if (block?.tagName.toLowerCase() === 'li') {
        e.preventDefault();
        document.execCommand(e.shiftKey ? 'outdent' : 'indent');
        syncFromEditor(true);
        return;
      }
    }

    // Enter inside a checklist item creates a new checklist item (or exits if empty)
    if (e.key === 'Enter' && !e.shiftKey && editorRef.current) {
      const sel = window.getSelection();
      const anchorEl =
        sel?.anchorNode?.nodeType === Node.ELEMENT_NODE
          ? (sel.anchorNode as HTMLElement)
          : sel?.anchorNode?.parentElement;
      const todoEl = anchorEl?.closest('.note-todo') as HTMLElement | null;
      if (todoEl && editorRef.current.contains(todoEl)) {
        e.preventDefault();
        const textSpan = todoEl.querySelector('.note-todo-text');
        if (!textSpan?.textContent?.trim()) {
          const p = document.createElement('p');
          p.innerHTML = '<br>';
          todoEl.replaceWith(p);
          placeCaretAtEnd(p);
          syncFromEditor(true);
        } else {
          insertChecklistItem(false, '', null);
        }
        return;
      }
    }
  };

  const handleEditorClick = (e: MouseEvent) => {
    setExportMenuOpen(false);
    const target = e.target as HTMLElement | null;
    if (!target) return;

    // Interactive task checklist toggle
    if (target.tagName.toLowerCase() === 'input' && target.classList.contains('note-todo-box')) {
      const box = target as HTMLInputElement;
      const todo = box.closest('.note-todo') as HTMLElement | null;
      if (todo) {
        todo.setAttribute('data-checked', box.checked ? 'true' : 'false');
        syncFromEditor(true);
      }
      return;
    }

    // Click on hyperlink opens URL (Shift+Click opens in Peek)
    const link = target.closest('a') as HTMLAnchorElement | null;
    if (link && link.getAttribute('href')) {
      const href = sanitizeHref(link.getAttribute('href') || '');
      if (href) {
        e.preventDefault();
        void openNoteUrl(href, e.shiftKey ? 'peek' : 'tab');
      }
    }
  };

  const handlePaste = (e: ClipboardEvent) => {
    const items = e.clipboardData?.items;
    if (!items) return;
    for (const item of Array.from(items)) {
      if (item.type.startsWith('image/')) {
        const file = item.getAsFile();
        if (file) {
          e.preventDefault();
          void insertUploadedImage(file);
          return;
        }
      }
    }
  };

  const handleCopyMarkdown = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const md = noteToMarkdown(doc);
    try {
      await navigator.clipboard.writeText(md);
      showToast('Copied Markdown to clipboard');
    } catch {
      showToast('Could not access clipboard');
    }
  };

  const handleExportMarkdown = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const res = await exportNoteMarkdown(doc);
    const blob = new Blob([res.markdown], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    a.click();
    URL.revokeObjectURL(url);
    showToast(`Exported ${res.filename}`);
  };

  const handleExportHtml = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const res = await exportNoteHtml(doc);
    const blob = new Blob([res.html], { type: 'text/html;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    a.click();
    URL.revokeObjectURL(url);
    showToast(`Exported ${res.filename}`);
  };

  const handleDuplicate = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const res = await duplicateNote(doc.id);
    showToast(`Created "${res.title}"`);
  };

  if (!doc) return <div style={{ padding: '32px' }}>Loading Note…</div>;

  const trimmedText = doc.text.trim();
  const wordCount = trimmedText ? trimmedText.split(/\s+/).length : 0;
  const charCount = doc.text.length;
  const readMins = Math.max(1, Math.ceil(wordCount / 220));
  const updatedLabel = doc.modified_at
    ? `Updated ${new Date(doc.modified_at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
    : '';

  return (
    <div class="note-shell">
      <input
        ref={fileInputRef}
        type="file"
        accept="image/png,image/jpeg,image/gif,image/webp,image/avif"
        style={{ display: 'none' }}
        onChange={(e) => {
          const file = (e.currentTarget as HTMLInputElement).files?.[0];
          if (file) void insertUploadedImage(file);
          (e.currentTarget as HTMLInputElement).value = '';
        }}
      />

      <header class="note-topbar">
        <div class="note-topbar-left">
          <OpenDoorwayMark size={24} />
          <div class="note-toolbar" role="toolbar" aria-label="Note formatting">
            <button type="button" class="note-tool-btn" title="Undo (Cmd/Ctrl+Z)" disabled={undoStack.length === 0} onClick={handleUndo}>
              <UndoIcon size={13} />
            </button>
            <button type="button" class="note-tool-btn" title="Redo (Cmd/Ctrl+Shift+Z)" disabled={redoStack.length === 0} onClick={handleRedo}>
              <RedoIcon size={13} />
            </button>
            <span class="note-tool-sep" />
            <button type="button" class={`note-tool-btn${activeFormats.h1 ? ' is-active' : ''}`} title="Heading 1 (# )" onClick={() => toggleBlock('H1')}>
              H1
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.h2 ? ' is-active' : ''}`} title="Heading 2 (## )" onClick={() => toggleBlock('H2')}>
              H2
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.h3 ? ' is-active' : ''}`} title="Heading 3 (### )" onClick={() => toggleBlock('H3')}>
              H3
            </button>
            <span class="note-tool-sep" />
            <button type="button" class={`note-tool-btn${activeFormats.bold ? ' is-active' : ''}`} title="Bold (Cmd/Ctrl+B)" onClick={() => execFormat('bold')}>
              <strong>B</strong>
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.italic ? ' is-active' : ''}`} title="Italic (Cmd/Ctrl+I)" onClick={() => execFormat('italic')}>
              <em>I</em>
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.underline ? ' is-active' : ''}`} title="Underline (Cmd/Ctrl+U)" onClick={() => execFormat('underline')}>
              <u>U</u>
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.strike ? ' is-active' : ''}`} title="Strikethrough" onClick={() => execFormat('strikeThrough')}>
              <s>S</s>
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.code ? ' is-active' : ''}`} title="Inline code (Cmd/Ctrl+E)" onClick={toggleInlineCode}>
              {'</>'}
            </button>
            <span class="note-tool-sep" />
            <button type="button" class={`note-tool-btn${activeFormats.bulletList ? ' is-active' : ''}`} title="Bullet list (- )" onClick={() => execFormat('insertUnorderedList')}>
              • List
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.numberedList ? ' is-active' : ''}`} title="Numbered list (1. )" onClick={() => execFormat('insertOrderedList')}>
              1. List
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.checklist ? ' is-active' : ''}`} title="Task checklist (- [ ])" onClick={() => insertChecklistItem(false)}>
              ☑ Todo
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.blockquote ? ' is-active' : ''}`} title="Blockquote (> )" onClick={() => toggleBlock('BLOCKQUOTE')}>
              ❝
            </button>
            <button type="button" class={`note-tool-btn${activeFormats.codeBlock ? ' is-active' : ''}`} title="Code block (```)" onClick={() => insertCodeBlock()}>
              Code
            </button>
            <button type="button" class="note-tool-btn" title="Horizontal divider (---)" onClick={() => insertDivider()}>
              ―
            </button>
            <span class="note-tool-sep" />
            <button
              type="button"
              class="note-tool-btn"
              title="Insert link (Cmd/Ctrl+K)"
              onClick={() => {
                const sel = window.getSelection();
                if (sel && sel.rangeCount > 0) savedRangeRef.current = sel.getRangeAt(0).cloneRange();
                setLinkUrl('https://');
                setLinkModalOpen(true);
              }}
            >
              Link
            </button>
            <button type="button" class="note-tool-btn" title="Embed image" onClick={() => fileInputRef.current?.click()}>
              Image
            </button>
          </div>
        </div>

        <div class="note-topbar-right">
          <span class={`note-save-pill${saveState === 'saving' ? ' is-saving' : ''}`}>
            {saveState === 'saved' ? 'Saved' : 'Saving…'}
          </span>
          <div class="note-menu-wrap">
            <button type="button" class="open-btn" onClick={() => setExportMenuOpen((o) => !o)}>
              Export ▾
            </button>
            {exportMenuOpen && (
              <div class="note-dropdown" role="menu">
                <button type="button" class="note-dropdown-item" onClick={() => void handleCopyMarkdown()}>
                  <span>Copy Markdown</span>
                </button>
                <button type="button" class="note-dropdown-item" onClick={() => void handleExportMarkdown()}>
                  <span>Export Markdown</span>
                  <span style={{ opacity: 0.55, fontSize: '11px' }}>.md</span>
                </button>
                <button type="button" class="note-dropdown-item" onClick={() => void handleExportHtml()}>
                  <span>Export HTML</span>
                  <span style={{ opacity: 0.55, fontSize: '11px' }}>.html</span>
                </button>
                <button type="button" class="note-dropdown-item" onClick={() => void handleDuplicate()}>
                  <span>Duplicate Note</span>
                </button>
              </div>
            )}
          </div>
        </div>
      </header>

      <main
        class={`note-page${dropActive ? ' is-drop-target' : ''}`}
        onDragOver={(e) => {
          e.preventDefault();
          setDropActive(true);
        }}
        onDragLeave={() => setDropActive(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDropActive(false);
          const files = e.dataTransfer?.files;
          if (files && files.length > 0) {
            for (const file of Array.from(files)) {
              if (file.type.startsWith('image/')) {
                void insertUploadedImage(file);
              }
            }
          }
        }}
      >
        <input
          class="note-title-input"
          aria-label="Note title"
          placeholder="Untitled"
          value={doc.title}
          onInput={(e) => {
            const title = (e.currentTarget as HTMLInputElement).value;
            document.title = title || 'Untitled Note';
            const nextDoc = { ...doc, title };
            setDoc(nextDoc);
            scheduleSave(nextDoc);
          }}
          onBlur={() => {
            if (doc) void renameNote(doc.id, doc.title);
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === 'ArrowDown') {
              e.preventDefault();
              editorRef.current?.focus();
            }
          }}
        />

        <div
          ref={editorRef}
          class={`note-editor-surface${!doc.text && doc.formats.length === 0 ? ' is-empty' : ''}`}
          contentEditable
          role="textbox"
          aria-multiline="true"
          aria-label="Note content"
          onInput={handleEditorInput}
          onKeyDown={handleEditorKeyDown}
          onClick={handleEditorClick}
          onPaste={handlePaste}
        />

        <footer class="note-footer">
          <span>
            {wordCount} {wordCount === 1 ? 'word' : 'words'} · {charCount} {charCount === 1 ? 'character' : 'characters'} · {readMins} min read
          </span>
          <span>{updatedLabel}</span>
        </footer>
      </main>

      {/* Floating Selection Format Bar */}
      {floatingBar && (
        <div
          class="note-floating-bar"
          role="toolbar"
          aria-label="Format selection"
          style={{ left: `${floatingBar.x}px`, top: `${floatingBar.y}px` }}
          onMouseDown={(e) => e.preventDefault()}
        >
          <button type="button" class={`note-tool-btn${activeFormats.h1 ? ' is-active' : ''}`} onClick={() => toggleBlock('H1')}>H1</button>
          <button type="button" class={`note-tool-btn${activeFormats.h2 ? ' is-active' : ''}`} onClick={() => toggleBlock('H2')}>H2</button>
          <button type="button" class={`note-tool-btn${activeFormats.h3 ? ' is-active' : ''}`} onClick={() => toggleBlock('H3')}>H3</button>
          <span class="note-tool-sep" />
          <button type="button" class={`note-tool-btn${activeFormats.bold ? ' is-active' : ''}`} onClick={() => execFormat('bold')}><strong>B</strong></button>
          <button type="button" class={`note-tool-btn${activeFormats.italic ? ' is-active' : ''}`} onClick={() => execFormat('italic')}><em>I</em></button>
          <button type="button" class={`note-tool-btn${activeFormats.underline ? ' is-active' : ''}`} onClick={() => execFormat('underline')}><u>U</u></button>
          <button type="button" class={`note-tool-btn${activeFormats.strike ? ' is-active' : ''}`} onClick={() => execFormat('strikeThrough')}><s>S</s></button>
          <button type="button" class={`note-tool-btn${activeFormats.code ? ' is-active' : ''}`} onClick={toggleInlineCode}>{'<>'}</button>
          <span class="note-tool-sep" />
          <button
            type="button"
            class="note-tool-btn"
            onClick={() => {
              const sel = window.getSelection();
              if (sel && sel.rangeCount > 0) savedRangeRef.current = sel.getRangeAt(0).cloneRange();
              setLinkUrl('https://');
              setLinkModalOpen(true);
            }}
          >
            Link
          </button>
        </div>
      )}

      {/* Slash Command Palette */}
      {slashMenu && filteredSlashCommands.length > 0 && (
        <div
          class="note-slash-menu"
          role="listbox"
          aria-label="Insert block"
          style={{ left: `${slashMenu.x}px`, top: `${slashMenu.y}px` }}
          onMouseDown={(e) => e.preventDefault()}
        >
          <div class="note-slash-header">Insert Block</div>
          {filteredSlashCommands.map((cmd, idx) => (
            <button
              key={cmd.id}
              type="button"
              role="option"
              aria-selected={idx === slashMenu.index}
              class={`note-slash-item${idx === slashMenu.index ? ' is-selected' : ''}`}
              onClick={() => executeSlashCommand(cmd)}
            >
              <span class="note-slash-label">{cmd.label}</span>
              <span class="note-slash-hint">{cmd.hint}</span>
            </button>
          ))}
        </div>
      )}

      {/* Insert Link Modal */}
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
                if (!safeHref) {
                  showToast('Only http:, https:, mailto:, and open:// links are allowed.');
                  return;
                }
                editorRef.current?.focus();
                if (savedRangeRef.current) {
                  const sel = window.getSelection();
                  if (sel) {
                    sel.removeAllRanges();
                    sel.addRange(savedRangeRef.current);
                  }
                }
                const sel = window.getSelection();
                if (sel && sel.isCollapsed) {
                  insertHtmlAtCaret(`<a href="${escapeHtml(safeHref)}">${escapeHtml(safeHref)}</a>&nbsp;`);
                } else {
                  execFormat('createLink', safeHref);
                }
                setLinkModalOpen(false);
                showToast('Inserted link');
              }}
            >
              Insert
            </button>
          </>
        }
      >
        <input
          class="open-input"
          autoFocus
          value={linkUrl}
          placeholder="https://example.com"
          onInput={(e) => setLinkUrl((e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              const safeHref = sanitizeHref(linkUrl);
              if (safeHref) {
                editorRef.current?.focus();
                if (savedRangeRef.current) {
                  const sel = window.getSelection();
                  if (sel) {
                    sel.removeAllRanges();
                    sel.addRange(savedRangeRef.current);
                  }
                }
                const sel = window.getSelection();
                if (sel && sel.isCollapsed) {
                  insertHtmlAtCaret(`<a href="${escapeHtml(safeHref)}">${escapeHtml(safeHref)}</a>&nbsp;`);
                } else {
                  execFormat('createLink', safeHref);
                }
                setLinkModalOpen(false);
                showToast('Inserted link');
              }
            }
          }}
        />
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
