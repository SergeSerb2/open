// Typed RPC client for open://easel (reuses shared/bridge.ts transport when
// running inside Chromium WebUI, and provides a rich preview fallback outside).

import { isNativeWebUI, rpc } from '../shared/bridge';
import { currentPageRoute } from '../shared/route';
import type { RichEaselDocument } from './types';

export interface UploadAssetResult {
  assetId: string;
  url: string;
  relativeUrl?: string;
  dataUrl: string;
  mimeType?: string;
  sizeBytes?: number;
}

export interface CaptureUrlResult {
  ok: boolean;
  url: string;
  title: string;
  imageUrl?: string;
  relativeUrl?: string;
  assetId?: string;
  dataUrl?: string;
  lastRefreshedAt: number;
  source?: string;
}

export interface ExportHtmlResult {
  html: string;
  filename: string;
}

export interface ExportImageResult {
  ok: boolean;
  filename: string;
  savedPath?: string;
  dataUrl: string;
}

export interface DuplicateDocResult {
  ok: boolean;
  id: string;
  title: string;
  url: string;
}

type RawRpcFn = (method: string, payload?: unknown) => Promise<unknown>;

async function callNative<T>(method: string, payload: unknown): Promise<T> {
  return (await (rpc as unknown as RawRpcFn)(method, payload)) as T;
}

// Fixes Audit 3 P0 bug: open://easel/<id> has <id> at path segment [0], NOT [1].
// Also supports open://easel/?id=<id> and hash routes (#/<id> or #<id>).
export function resolveDocumentIdFromLocation(): string | undefined {
  const route = currentPageRoute();
  const fromQuery = route.params.get('id')?.trim();
  if (fromQuery) return fromQuery;
  const firstSegment = route.segments[0]?.trim();
  if (firstSegment && firstSegment !== 'new' && firstSegment !== 'asset') {
    return firstSegment;
  }
  return undefined;
}

// Preview-mode in-memory asset store for Vite dev server.
const previewAssets = new Map<string, { mimeType: string; dataUrl: string }>();

export async function loadEasel(id?: string): Promise<{ document: RichEaselDocument }> {
  const res = await callNative<{ document: RichEaselDocument }>('easel.load', {
    id: id || undefined,
  });
  return res;
}

export async function saveEasel(
  doc: RichEaselDocument,
): Promise<{ ok: boolean; modified_at: number }> {
  return callNative<{ ok: boolean; modified_at: number }>('easel.save', {
    document: doc,
  });
}

export async function uploadDocumentAsset(params: {
  docId: string;
  mimeType: string;
  data: string;
  filename?: string;
}): Promise<UploadAssetResult> {
  if (isNativeWebUI()) {
    return callNative<UploadAssetResult>('documents.uploadAsset', {
      ...params,
      docType: 'easel',
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
    url: `open://easel/asset/${params.docId}/${assetId}`,
    relativeUrl: `/asset/${params.docId}/${assetId}`,
    dataUrl,
    mimeType: params.mimeType,
  };
}

export async function deleteDocumentAsset(docId: string, assetId: string): Promise<{ ok: boolean }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean }>('documents.deleteAsset', {
      docId,
      assetId,
      docType: 'easel',
    });
  }
  previewAssets.delete(`${docId}/${assetId}`);
  return { ok: true };
}

export async function readDocumentAsset(
  docId: string,
  assetId: string,
): Promise<{ assetId: string; mimeType: string; dataUrl: string } | null> {
  if (isNativeWebUI()) {
    try {
      return await callNative<{ assetId: string; mimeType: string; dataUrl: string }>(
        'documents.readAsset',
        { docId, assetId, docType: 'easel' },
      );
    } catch {
      return null;
    }
  }
  const found = previewAssets.get(`${docId}/${assetId}`);
  return found ? { assetId, ...found } : null;
}

export async function captureLiveUrl(params: {
  docId: string;
  url: string;
  width?: number;
  height?: number;
}): Promise<CaptureUrlResult> {
  if (isNativeWebUI()) {
    return callNative<CaptureUrlResult>('documents.captureUrl', params);
  }
  let host = params.url;
  try {
    host = new URL(params.url).hostname;
  } catch {
    // keep raw string
  }
  return {
    ok: true,
    url: params.url,
    title: host,
    lastRefreshedAt: Math.floor(Date.now() / 1000),
    source: 'preview',
  };
}

export async function exportEaselHtml(doc: RichEaselDocument): Promise<ExportHtmlResult> {
  if (isNativeWebUI()) {
    return callNative<ExportHtmlResult>('documents.exportHtml', {
      docType: 'easel',
      document: doc,
    });
  }
  return callNative<ExportHtmlResult>('easel.exportHtml', { document: doc });
}

export async function exportEaselImage(params: {
  docId: string;
  title: string;
  data: string;
}): Promise<ExportImageResult> {
  if (isNativeWebUI()) {
    return callNative<ExportImageResult>('documents.exportImage', params);
  }
  const slug = (params.title || 'easel').toLowerCase().replace(/[^a-z0-9]+/g, '-') || 'easel';
  return {
    ok: true,
    filename: `${slug}.png`,
    dataUrl: params.data.startsWith('data:') ? params.data : `data:image/png;base64,${params.data}`,
  };
}

export async function duplicateEasel(docId: string): Promise<DuplicateDocResult> {
  if (isNativeWebUI()) {
    return callNative<DuplicateDocResult>('documents.duplicate', {
      docId,
      docType: 'easel',
      open: true,
    });
  }
  const newId = `easel-${Date.now()}`;
  return { ok: true, id: newId, title: 'Easel Copy', url: `open://easel/${newId}` };
}

export async function renameEasel(
  docId: string,
  title: string,
): Promise<{ ok: boolean; title: string }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean; title: string }>('documents.rename', {
      docId,
      docType: 'easel',
      title,
    });
  }
  return { ok: true, title };
}

export async function openDocumentUrl(
  url: string,
  mode: 'tab' | 'background' | 'peek' = 'tab',
): Promise<{ ok: boolean }> {
  if (isNativeWebUI()) {
    return callNative<{ ok: boolean }>('documents.openUrl', { url, mode, new_tab: true });
  }
  window.open(url, '_blank', 'noopener,noreferrer');
  return { ok: true };
}
