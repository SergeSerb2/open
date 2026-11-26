// Typed RPC client for open://note (reuses shared/bridge.ts transport when
// running inside Chromium WebUI, with full preview fallback outside).

import { isNativeWebUI, rpc } from '../shared/bridge';
import { currentPageRoute } from '../shared/route';
import { noteToMarkdown, type RichNoteDocument } from './noteCodec';

export interface UploadNoteAssetResult {
  assetId: string;
  url: string;
  relativeUrl?: string;
  dataUrl: string;
  mimeType?: string;
  sizeBytes?: number;
}

export interface ExportMarkdownResult {
  markdown: string;
  filename: string;
}

export interface ExportHtmlResult {
  html: string;
  filename: string;
}

type RawRpcFn = (method: string, payload?: unknown) => Promise<unknown>;

async function callNative<T>(method: string, payload: unknown): Promise<T> {
  return (await (rpc as unknown as RawRpcFn)(method, payload)) as T;
}

// Fixes Audit 3 P0 bug: open://note/<id> has <id> at path segment [0], NOT [1].
// Supports open://note/<id>, open://note/?id=<id>, and hash routes (#/<id> or #<id>).
export function resolveNoteIdFromLocation(): string | undefined {
  const route = currentPageRoute();
  const fromQuery = route.params.get('id')?.trim();
  if (fromQuery) return fromQuery;
  const firstSegment = route.segments[0]?.trim();
  if (firstSegment && firstSegment !== 'new' && firstSegment !== 'asset') {
    return firstSegment;
  }
  return undefined;
}

const previewAssets = new Map<string, { mimeType: string; dataUrl: string }>();

export async function loadNote(id?: string): Promise<{ document: RichNoteDocument }> {
  return callNative<{ document: RichNoteDocument }>('note.load', { id: id || undefined });
}

export async function saveNote(
  doc: RichNoteDocument,
): Promise<{ ok: boolean; modified_at: number }> {
  return callNative<{ ok: boolean; modified_at: number }>('note.save', { document: doc });
}

export async function uploadNoteAsset(params: {
  docId: string;
  mimeType: string;
  data: string;
  filename?: string;
}): Promise<UploadNoteAssetResult> {
  if (isNativeWebUI()) {
    return callNative<UploadNoteAssetResult>('documents.uploadAsset', {
      ...params,
      docType: 'note',
    });
  }
  const ext = params.mimeType.split('/')[1]?.replace('jpeg', 'jpg') || 'png';
  const assetId = `preview-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
  const dataUrl = params.data.startsWith('data:')
    ? params.data
    : `data:${params.mimeType};base64,${params.data}`;
  previewAssets.set(`${params.docId}/${assetId}`, { mimeType: params.mimeType, dataUrl });
  return {
    assetId,
    url: `open://note/asset/${params.docId}/${assetId}`,
    relativeUrl: `/asset/${params.docId}/${assetId}`,
    dataUrl,
    mimeType: params.mimeType,
  };
}

export async function readNoteAsset(
  docId: string,
  assetId: string,
): Promise<{ assetId: string; mimeType: string; dataUrl: string } | null> {
  if (isNativeWebUI()) {
    try {
      return await callNative<{ assetId: string; mimeType: string; dataUrl: string }>(
        'documents.readAsset',
        { docId, assetId, docType: 'note' },
      );
    } catch {
      return null;
    }
  }
  const found = previewAssets.get(`${docId}/${assetId}`);
  return found ? { assetId, ...found } : null;
}

export async function exportNoteMarkdown(doc: RichNoteDocument): Promise<ExportMarkdownResult> {
  if (isNativeWebUI()) {
    return callNative<ExportMarkdownResult>('documents.exportMarkdown', {
      docId: doc.id,
      document: doc,
    });
  }
  const slug = (doc.title || 'note').toLowerCase().replace(/[^a-z0-9]+/g, '-') || 'note';
  return {
    markdown: noteToMarkdown(doc),
    filename: `${slug}.md`,
  };
}

export async function exportNoteHtml(doc: RichNoteDocument): Promise<ExportHtmlResult> {
  if (isNativeWebUI()) {
    return callNative<ExportHtmlResult>('documents.exportHtml', {
      docType: 'note',
      docId: doc.id,
      document: doc,
    });
  }
  const slug = (doc.title || 'note').toLowerCase().replace(/[^a-z0-9]+/g, '-') || 'note';
  const safeTitle = (doc.title || 'Untitled Note').replace(/[<>&"]/g, '');
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${safeTitle}</title></head><body style="max-width:720px;margin:48px auto;font-family:system-ui,sans-serif;line-height:1.6"><h1>${safeTitle}</h1><pre style="white-space:pre-wrap;font-family:inherit">${doc.text.replace(/[<>&]/g, '')}</pre></body></html>`;
  return { html, filename: `${slug}.html` };
}

export async function duplicateNote(
  docId: string,
): Promise<{ ok: boolean; id: string; title: string; url: string }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean; id: string; title: string; url: string }>(
      'documents.duplicate',
      { docId, docType: 'note', open: true },
    );
  }
  const newId = `note-${Date.now()}`;
  return { ok: true, id: newId, title: 'Note Copy', url: `open://note/${newId}` };
}

export async function renameNote(
  docId: string,
  title: string,
): Promise<{ ok: boolean; title: string }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean; title: string }>('documents.rename', {
      docId,
      docType: 'note',
      title,
    });
  }
  return { ok: true, title };
}

export async function openNoteUrl(
  url: string,
  mode: 'tab' | 'background' | 'peek' = 'tab',
): Promise<{ ok: boolean }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean }>('documents.openUrl', { url, mode, new_tab: true });
  }
  window.open(url, '_blank', 'noopener,noreferrer');
  return { ok: true };
}
