import type { JSX } from 'preact';
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { Modal, SegmentedControl, Toast } from '../shared/components';
import { OpenDoorwayMark, RedoIcon, TrashIcon, UndoIcon } from '../shared/icons';
import { replacePageRoute } from '../shared/route';
import {
  captureLiveUrl,
  deleteDocumentAsset,
  duplicateEasel,
  exportEaselHtml,
  exportEaselImage,
  loadEasel,
  openDocumentUrl,
  readDocumentAsset,
  renameEasel,
  resolveDocumentIdFromLocation,
  saveEasel,
  uploadDocumentAsset,
} from './documentsRpc';
import { renderEaselToPngDataUrl } from './exportCanvas';
import {
  FONT_FAMILY_CSS,
  MAX_ZOOM,
  MIN_ZOOM,
  PALETTES,
  SNAP_THRESHOLD_PX,
  STICKY_COLORS,
  type CanvasBackground,
  type EaselFontFamily,
  type EaselItem,
  type EaselTextAlign,
  type EaselViewport,
  type RichEaselDocument,
  type ToolKind,
} from './types';

type ResizeDir = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w';

interface SnapGuide {
  vertical: boolean;
  pos: number;
  start: number;
  end: number;
}

interface MarqueeBox {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

interface ToolDef {
  id: ToolKind;
  label: string;
  key: string;
  icon: () => JSX.Element;
}

const TOOL_DEFS: readonly ToolDef[] = [
  {
    id: 'select',
    label: 'Select / Marquee',
    key: 'V',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round">
        <path d="M4.5 3.5l11 6.2-5.1 1.4-2.1 5.1-3.8-12.7z" />
      </svg>
    ),
  },
  {
    id: 'text',
    label: 'Text',
    key: 'T',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
        <path d="M4.5 5h11M10 5v10.5M7.5 15.5h5" />
      </svg>
    ),
  },
  {
    id: 'sticky',
    label: 'Sticky Note',
    key: 'S',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round">
        <path d="M4 4h12v8.5L12.5 16H4V4z" />
        <path d="M12.5 16v-3.5H16" />
      </svg>
    ),
  },
  {
    id: 'rect',
    label: 'Rectangle',
    key: 'R',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7">
        <rect x="3.5" y="4.5" width="13" height="11" rx="2.5" />
      </svg>
    ),
  },
  {
    id: 'ellipse',
    label: 'Ellipse',
    key: 'O',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7">
        <ellipse cx="10" cy="10" rx="6.8" ry="5.5" />
      </svg>
    ),
  },
  {
    id: 'line',
    label: 'Line',
    key: 'L',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
        <path d="M4 15.5L16 4.5" />
      </svg>
    ),
  },
  {
    id: 'arrow',
    label: 'Arrow / Connector',
    key: 'A',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <path d="M4.5 15.5L15.5 4.5M9.5 4.5h6v6" />
      </svg>
    ),
  },
  {
    id: 'freehand',
    label: 'Freehand Pen',
    key: 'P',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
        <path d="M3.5 15.5c2-4 3.5-7 5-5s2 4 4 1 3-6.5 4-7" />
      </svg>
    ),
  },
  {
    id: 'image',
    label: 'Image',
    key: 'I',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round">
        <rect x="3" y="4" width="14" height="12" rx="2" />
        <circle cx="7.2" cy="8" r="1.3" />
        <path d="M3.5 14l4-4 3 3 2.2-2.2L16.5 14" />
      </svg>
    ),
  },
  {
    id: 'live_card',
    label: 'Live Web Capture',
    key: 'W',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round">
        <rect x="2.8" y="4" width="14.4" height="12" rx="2.2" />
        <path d="M2.8 7.6h14.4" />
        <circle cx="5.4" cy="5.8" r="0.6" fill="currentColor" />
        <circle cx="7.4" cy="5.8" r="0.6" fill="currentColor" />
      </svg>
    ),
  },
  {
    id: 'frame',
    label: 'Frame / Group',
    key: 'F',
    icon: () => (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-dasharray="3 2.2">
        <rect x="3.5" y="4" width="13" height="12" rx="2" />
      </svg>
    ),
  },
];

function smoothSvgPath(pts: readonly [number, number][], offsetX: number, offsetY: number): string {
  if (pts.length === 0) return '';
  const first = pts[0]!;
  if (pts.length === 1) return `M${(first[0] - offsetX).toFixed(1)},${(first[1] - offsetY).toFixed(1)}`;
  let d = `M${(first[0] - offsetX).toFixed(1)},${(first[1] - offsetY).toFixed(1)}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const cur = pts[i]!;
    const next = pts[i + 1]!;
    const midX = (cur[0] + next[0]) / 2 - offsetX;
    const midY = (cur[1] + next[1]) / 2 - offsetY;
    d += ` Q${(cur[0] - offsetX).toFixed(1)},${(cur[1] - offsetY).toFixed(1)} ${midX.toFixed(1)},${midY.toFixed(1)}`;
  }
  const last = pts[pts.length - 1]!;
  d += ` L${(last[0] - offsetX).toFixed(1)},${(last[1] - offsetY).toFixed(1)}`;
  return d;
}

function formatTimestamp(sec?: number): string {
  if (!sec) return 'Not refreshed yet';
  const d = new Date(sec * 1000);
  return `Refreshed ${d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
}

function readFileAsDataUrl(file: File): Promise<{ dataUrl: string; width: number; height: number }> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Could not read image file'));
    reader.onload = () => {
      const dataUrl = String(reader.result || '');
      const img = new Image();
      img.onload = () => resolve({ dataUrl, width: img.naturalWidth || 320, height: img.naturalHeight || 220 });
      img.onerror = () => resolve({ dataUrl, width: 320, height: 220 });
      img.src = dataUrl;
    };
    reader.readAsDataURL(file);
  });
}

function computeSnapping(
  movingIds: Set<string>,
  proposed: { x: number; y: number; width: number; height: number },
  all: readonly EaselItem[],
  zoom: number,
): { dx: number; dy: number; guides: SnapGuide[] } {
  const threshold = SNAP_THRESHOLD_PX / Math.max(zoom, 0.25);
  const others = all.filter((el) => !movingIds.has(el.id));
  if (others.length === 0) return { dx: 0, dy: 0, guides: [] };

  const mXs = [proposed.x, proposed.x + proposed.width / 2, proposed.x + proposed.width];
  const mYs = [proposed.y, proposed.y + proposed.height / 2, proposed.y + proposed.height];

  let bestX: { d: number; pos: number; other: EaselItem } | null = null;
  let bestY: { d: number; pos: number; other: EaselItem } | null = null;

  for (const o of others) {
    const oXs = [o.x, o.x + o.width / 2, o.x + o.width];
    const oYs = [o.y, o.y + o.height / 2, o.y + o.height];
    for (const a of mXs) {
      for (const b of oXs) {
        const diff = b - a;
        if (Math.abs(diff) <= threshold && (!bestX || Math.abs(diff) < Math.abs(bestX.d))) {
          bestX = { d: diff, pos: b, other: o };
        }
      }
    }
    for (const a of mYs) {
      for (const b of oYs) {
        const diff = b - a;
        if (Math.abs(diff) <= threshold && (!bestY || Math.abs(diff) < Math.abs(bestY.d))) {
          bestY = { d: diff, pos: b, other: o };
        }
      }
    }
  }

  const dx = bestX?.d ?? 0;
  const dy = bestY?.d ?? 0;
  const guides: SnapGuide[] = [];
  if (bestX) {
    const top = Math.min(proposed.y + dy, bestX.other.y) - 10;
    const bottom = Math.max(proposed.y + dy + proposed.height, bestX.other.y + bestX.other.height) + 10;
    guides.push({ vertical: true, pos: bestX.pos, start: top, end: bottom });
  }
  if (bestY) {
    const left = Math.min(proposed.x + dx, bestY.other.x) - 10;
    const right = Math.max(proposed.x + dx + proposed.width, bestY.other.x + bestY.other.width) + 10;
    guides.push({ vertical: false, pos: bestY.pos, start: left, end: right });
  }
  return { dx, dy, guides };
}

export function EaselApp(): JSX.Element {
  const [doc, setDoc] = useState<RichEaselDocument | null>(null);
  const [tool, setTool] = useState<ToolKind>('select');
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [activeColor, setActiveColor] = useState<string>('#3139FB');
  const [strokeWidth, setStrokeWidth] = useState<number>(3);
  const [viewport, setViewport] = useState<EaselViewport>({ x: 80, y: 40, zoom: 1 });
  const [background, setBackground] = useState<CanvasBackground>('dots');
  const [presenting, setPresenting] = useState(false);
  const [spaceDown, setSpaceDown] = useState(false);
  const [isPanning, setIsPanning] = useState(false);
  const [dropActive, setDropActive] = useState(false);
  const [exportMenuOpen, setExportMenuOpen] = useState(false);
  const [liveModalOpen, setLiveModalOpen] = useState(false);
  const [liveModalUrl, setLiveModalUrl] = useState('https://');
  const [liveModalPos, setLiveModalPos] = useState<{ x: number; y: number }>({ x: 160, y: 120 });
  const [refreshingIds, setRefreshingIds] = useState<Record<string, boolean>>({});
  const [resolvedImgSrcs, setResolvedImgSrcs] = useState<Record<string, string>>({});

  const [undoStack, setUndoStack] = useState<EaselItem[][]>([]);
  const [redoStack, setRedoStack] = useState<EaselItem[][]>([]);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [toast, setToast] = useState<string | null>(null);
  const [guides, setGuides] = useState<SnapGuide[]>([]);
  const [marquee, setMarquee] = useState<MarqueeBox | null>(null);
  const [drawingFreehand, setDrawingFreehand] = useState<{ id: string; points: [number, number][] } | null>(null);
  const [drawingShape, setDrawingShape] = useState<{
    type: 'rect' | 'ellipse' | 'line' | 'arrow' | 'frame';
    x1: number;
    y1: number;
    x2: number;
    y2: number;
  } | null>(null);

  const stageRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const pendingImagePosRef = useRef<{ x: number; y: number } | null>(null);
  const clipboardRef = useRef<EaselItem[]>([]);
  const saveTimerRef = useRef<number | null>(null);
  const docRef = useRef<RichEaselDocument | null>(null);
  const viewportRef = useRef<EaselViewport>(viewport);

  docRef.current = doc;
  viewportRef.current = viewport;

  const interactionRef = useRef<
    | {
        kind: 'pan';
        startClientX: number;
        startClientY: number;
        origPanX: number;
        origPanY: number;
      }
    | {
        kind: 'move';
        startClientX: number;
        startClientY: number;
        snapshot: EaselItem[];
        origPositions: Map<string, { x: number; y: number }>;
        union: { x: number; y: number; width: number; height: number };
        moved: boolean;
      }
    | {
        kind: 'resize';
        elementId: string;
        dir: ResizeDir;
        startClientX: number;
        startClientY: number;
        orig: EaselItem;
        snapshot: EaselItem[];
        moved: boolean;
      }
    | {
        kind: 'rotate';
        elementId: string;
        centerX: number;
        centerY: number;
        snapshot: EaselItem[];
        moved: boolean;
      }
    | {
        kind: 'marquee';
        startX: number;
        startY: number;
      }
    | null
  >(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2500);
  }, []);

  const scheduleSave = useCallback((nextDoc: RichEaselDocument) => {
    setSaveState('saving');
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      void saveEasel(nextDoc)
        .then(() => setSaveState('saved'))
        .catch(() => setSaveState('saved'));
    }, 450);
  }, []);

  // Load initial document using fixed [0] route parsing.
  useEffect(() => {
    const idFromUrl = resolveDocumentIdFromLocation();
    void loadEasel(idFromUrl).then((res) => {
      const loaded = res.document;
      setDoc(loaded);
      document.title = loaded.title || 'Untitled Easel';
      if (loaded.id && idFromUrl !== loaded.id) {
        replacePageRoute(loaded.id);
      }
      if (loaded.canvas_background) setBackground(loaded.canvas_background);
      if (loaded.viewport) setViewport(loaded.viewport);
      const pal = PALETTES[loaded.palette ?? 'vibrant'];
      setActiveColor(pal[10] ?? '#3139FB');
    });
  }, []);

  const screenToCanvas = useCallback((clientX: number, clientY: number): { x: number; y: number } => {
    const rect = stageRef.current?.getBoundingClientRect();
    const vp = viewportRef.current;
    if (!rect) return { x: 0, y: 0 };
    return {
      x: (clientX - rect.left - vp.x) / vp.zoom,
      y: (clientY - rect.top - vp.y) / vp.zoom,
    };
  }, []);

  const commitElements = useCallback(
    (nextElements: EaselItem[], pushUndo = true, overrideUndoBase?: EaselItem[]) => {
      const cur = docRef.current;
      if (!cur) return;
      if (pushUndo) {
        const base = overrideUndoBase ?? cur.elements.map((e) => ({ ...e }));
        setUndoStack((prev) => [...prev.slice(-49), base]);
        setRedoStack([]);
      }
      const maxBottom = nextElements.reduce((acc, el) => Math.max(acc, el.y + el.height + 240), 1400);
      const maxRight = nextElements.reduce((acc, el) => Math.max(acc, el.x + el.width + 200), 1000);
      const nextDoc: RichEaselDocument = {
        ...cur,
        canvas_width: Math.max(1000, Math.ceil(maxRight)),
        canvas_height: Math.max(1400, Math.ceil(maxBottom)),
        canvas_background: background,
        viewport: viewportRef.current,
        elements: nextElements,
      };
      setDoc(nextDoc);
      scheduleSave(nextDoc);
    },
    [background, scheduleSave],
  );

  const handleUndo = useCallback(() => {
    const cur = docRef.current;
    if (!cur || undoStack.length === 0) return;
    const prev = undoStack[undoStack.length - 1]!;
    setUndoStack((s) => s.slice(0, -1));
    setRedoStack((r) => [...r, cur.elements.map((e) => ({ ...e }))]);
    const nextDoc = { ...cur, elements: prev };
    setDoc(nextDoc);
    setSelectedIds([]);
    setEditingId(null);
    scheduleSave(nextDoc);
  }, [undoStack, scheduleSave]);

  const handleRedo = useCallback(() => {
    const cur = docRef.current;
    if (!cur || redoStack.length === 0) return;
    const next = redoStack[redoStack.length - 1]!;
    setRedoStack((r) => r.slice(0, -1));
    setUndoStack((s) => [...s, cur.elements.map((e) => ({ ...e }))]);
    const nextDoc = { ...cur, elements: next };
    setDoc(nextDoc);
    setSelectedIds([]);
    setEditingId(null);
    scheduleSave(nextDoc);
  }, [redoStack, scheduleSave]);

  const fitToView = useCallback(() => {
    const cur = docRef.current;
    const rect = stageRef.current?.getBoundingClientRect();
    if (!cur || !rect) return;
    if (cur.elements.length === 0) {
      setViewport({ x: Math.max(24, (rect.width - 1000) / 2), y: 40, zoom: 1 });
      return;
    }
    const minX = Math.min(...cur.elements.map((e) => e.x));
    const minY = Math.min(...cur.elements.map((e) => e.y));
    const maxX = Math.max(...cur.elements.map((e) => e.x + e.width));
    const maxY = Math.max(...cur.elements.map((e) => e.y + e.height));
    const pad = 80;
    const contentW = Math.max(100, maxX - minX + pad * 2);
    const contentH = Math.max(100, maxY - minY + pad * 2);
    const zoom = Math.max(MIN_ZOOM, Math.min(1.5, Math.min(rect.width / contentW, rect.height / contentH)));
    const x = (rect.width - (maxX - minX) * zoom) / 2 - minX * zoom;
    const y = (rect.height - (maxY - minY) * zoom) / 2 - minY * zoom;
    setViewport({ x: Math.round(x), y: Math.round(y), zoom: Number(zoom.toFixed(3)) });
  }, []);

  const zoomAtPoint = useCallback((nextZoomRaw: number, clientX?: number, clientY?: number) => {
    const rect = stageRef.current?.getBoundingClientRect();
    const nextZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Number(nextZoomRaw.toFixed(3))));
    setViewport((vp) => {
      if (!rect) return { ...vp, zoom: nextZoom };
      const px = (clientX ?? rect.left + rect.width / 2) - rect.left;
      const py = (clientY ?? rect.top + rect.height / 2) - rect.top;
      const worldX = (px - vp.x) / vp.zoom;
      const worldY = (py - vp.y) / vp.zoom;
      return {
        x: px - worldX * nextZoom,
        y: py - worldY * nextZoom,
        zoom: nextZoom,
      };
    });
  }, []);

  // Upload & place a local/pasted image file on the canvas.
  const insertImageFile = useCallback(
    async (file: File, pos?: { x: number; y: number }) => {
      const cur = docRef.current;
      if (!cur) return;
      try {
        const { dataUrl, width, height } = await readFileAsDataUrl(file);
        const uploaded = await uploadDocumentAsset({
          docId: cur.id,
          mimeType: file.type || 'image/png',
          data: dataUrl,
          filename: file.name,
        });
        const maxDim = 420;
        const ratio = width / Math.max(1, height);
        let cardW = Math.min(width, maxDim);
        let cardH = cardW / ratio;
        if (cardH > maxDim) {
          cardH = maxDim;
          cardW = cardH * ratio;
        }
        const rect = stageRef.current?.getBoundingClientRect();
        const center = pos ?? (rect ? screenToCanvas(rect.left + rect.width / 2, rect.top + rect.height / 2) : { x: 240, y: 180 });
        const maxZ = cur.elements.reduce((m, e) => Math.max(m, e.z_index), 0);
        const newEl: EaselItem = {
          id: `el-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
          type: 'image',
          x: Math.round(center.x - cardW / 2),
          y: Math.round(center.y - cardH / 2),
          width: Math.max(80, Math.round(cardW)),
          height: Math.max(60, Math.round(cardH)),
          content: file.name || 'Image',
          fill_color: 'transparent',
          stroke_color: 'transparent',
          stroke_width: 0,
          font_size: 14,
          z_index: maxZ + 1,
          asset_id: uploaded.assetId,
          image_url: uploaded.url,
          data_url: uploaded.dataUrl,
        };
        setResolvedImgSrcs((prev) => ({ ...prev, [newEl.id]: uploaded.dataUrl }));
        commitElements([...docRef.current!.elements, newEl]);
        setSelectedIds([newEl.id]);
        setTool('select');
        showToast('Image added to Easel');
      } catch (err) {
        showToast(err instanceof Error ? err.message : 'Could not upload image');
      }
    },
    [commitElements, screenToCanvas, showToast],
  );

  // Refresh a Live Web Capture card snapshot.
  const refreshLiveCard = useCallback(
    async (el: EaselItem) => {
      const cur = docRef.current;
      if (!cur) return;
      const targetUrl = (el.live_url || el.content || '').trim();
      if (!targetUrl) return;
      setRefreshingIds((r) => ({ ...r, [el.id]: true }));
      try {
        const cap = await captureLiveUrl({
          docId: cur.id,
          url: targetUrl,
          width: Math.max(640, Math.round(el.width * 2)),
          height: Math.max(400, Math.round(el.height * 2)),
        });
        if (cap.dataUrl) {
          setResolvedImgSrcs((prev) => ({ ...prev, [el.id]: cap.dataUrl! }));
        }
        const latest = docRef.current;
        if (!latest) return;
        commitElements(
          latest.elements.map((item) =>
            item.id === el.id
              ? {
                  ...item,
                  live_url: cap.url,
                  content: cap.url,
                  live_title: cap.title || item.live_title,
                  asset_id: cap.assetId ?? item.asset_id,
                  image_url: cap.imageUrl ?? item.image_url,
                  data_url: cap.dataUrl ?? item.data_url,
                  last_refreshed_at: cap.lastRefreshedAt,
                }
              : item,
          ),
          false,
        );
        showToast('Live card snapshot refreshed');
      } catch (err) {
        showToast(err instanceof Error ? err.message : 'Capture failed');
      } finally {
        setRefreshingIds((r) => ({ ...r, [el.id]: false }));
      }
    },
    [commitElements, showToast],
  );

  const createLiveCaptureCard = useCallback(
    async (rawUrl: string, pos: { x: number; y: number }) => {
      const cur = docRef.current;
      if (!cur) return;
      const normalized = /^https?:\/\//i.test(rawUrl.trim()) ? rawUrl.trim() : `https://${rawUrl.trim()}`;
      try {
        new URL(normalized);
      } catch {
        showToast('Enter a valid http(s) URL');
        return;
      }
      const maxZ = cur.elements.reduce((m, e) => Math.max(m, e.z_index), 0);
      const newEl: EaselItem = {
        id: `el-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
        type: 'live_card',
        x: Math.round(pos.x),
        y: Math.round(pos.y),
        width: 380,
        height: 250,
        content: normalized,
        live_url: normalized,
        live_title: normalized,
        fill_color: 'transparent',
        stroke_color: activeColor,
        stroke_width: 1,
        font_size: 13,
        z_index: maxZ + 1,
      };
      commitElements([...cur.elements, newEl]);
      setSelectedIds([newEl.id]);
      setTool('select');
      setLiveModalOpen(false);
      await refreshLiveCard(newEl);
    },
    [activeColor, commitElements, refreshLiveCard, showToast],
  );

  const deleteSelected = useCallback(() => {
    const cur = docRef.current;
    if (!cur || selectedIds.length === 0) return;
    const drop = new Set(selectedIds);
    for (const el of cur.elements) {
      if (drop.has(el.id) && el.asset_id) {
        void deleteDocumentAsset(cur.id, el.asset_id);
      }
    }
    commitElements(cur.elements.filter((el) => !drop.has(el.id)));
    setSelectedIds([]);
    setEditingId(null);
  }, [selectedIds, commitElements]);

  const duplicateSelected = useCallback(() => {
    const cur = docRef.current;
    if (!cur || selectedIds.length === 0) return;
    const maxZ = cur.elements.reduce((m, e) => Math.max(m, e.z_index), 0);
    const selSet = new Set(selectedIds);
    const copies: EaselItem[] = cur.elements
      .filter((el) => selSet.has(el.id))
      .map((el, idx) => ({
        ...el,
        id: `el-${Date.now()}-${idx}-${Math.random().toString(36).slice(2, 5)}`,
        x: el.x + 24,
        y: el.y + 24,
        z_index: maxZ + idx + 1,
      }));
    if (copies.length === 0) return;
    commitElements([...cur.elements, ...copies]);
    setSelectedIds(copies.map((c) => c.id));
  }, [selectedIds, commitElements]);

  const reorderSelected = useCallback(
    (dir: 'front' | 'forward' | 'backward' | 'back') => {
      const cur = docRef.current;
      if (!cur || selectedIds.length === 0) return;
      const selSet = new Set(selectedIds);
      const maxZ = cur.elements.reduce((m, e) => Math.max(m, e.z_index), 0);
      const minZ = cur.elements.reduce((m, e) => Math.min(m, e.z_index), 0);
      const next = cur.elements.map((el) => {
        if (!selSet.has(el.id)) return el;
        if (dir === 'front') return { ...el, z_index: maxZ + 1 };
        if (dir === 'back') return { ...el, z_index: minZ - 1 };
        if (dir === 'forward') return { ...el, z_index: el.z_index + 1 };
        return { ...el, z_index: el.z_index - 1 };
      });
      commitElements(next);
    },
    [selectedIds, commitElements],
  );

  // Keyboard shortcuts + Space pan + Clipboard image paste.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const inInput = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);

      if (e.key === 'Escape') {
        if (presenting) {
          setPresenting(false);
          return;
        }
        if (editingId) {
          setEditingId(null);
          return;
        }
        setSelectedIds([]);
        setTool('select');
        setExportMenuOpen(false);
        return;
      }

      if (inInput) return;

      if (e.code === 'Space' && !e.repeat) {
        e.preventDefault();
        setSpaceDown(true);
        return;
      }

      const mod = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();

      if (mod && key === 'z') {
        e.preventDefault();
        if (e.shiftKey) handleRedo();
        else handleUndo();
      } else if (mod && key === 'd') {
        e.preventDefault();
        duplicateSelected();
      } else if (mod && key === 'a') {
        e.preventDefault();
        if (docRef.current) setSelectedIds(docRef.current.elements.map((el) => el.id));
      } else if (mod && key === 'c') {
        if (docRef.current && selectedIds.length > 0) {
          const sel = new Set(selectedIds);
          clipboardRef.current = docRef.current.elements.filter((el) => sel.has(el.id)).map((el) => ({ ...el }));
          showToast(`Copied ${clipboardRef.current.length} item${clipboardRef.current.length === 1 ? '' : 's'}`);
        }
      } else if (mod && key === 'v') {
        if (clipboardRef.current.length > 0 && docRef.current) {
          const maxZ = docRef.current.elements.reduce((m, el) => Math.max(m, el.z_index), 0);
          const pasted = clipboardRef.current.map((el, idx) => ({
            ...el,
            id: `el-${Date.now()}-${idx}-${Math.random().toString(36).slice(2, 5)}`,
            x: el.x + 28,
            y: el.y + 28,
            z_index: maxZ + idx + 1,
          }));
          commitElements([...docRef.current.elements, ...pasted]);
          setSelectedIds(pasted.map((p) => p.id));
        }
      } else if (mod && (e.key === '=' || e.key === '+')) {
        e.preventDefault();
        zoomAtPoint(viewportRef.current.zoom * 1.18);
      } else if (mod && e.key === '-') {
        e.preventDefault();
        zoomAtPoint(viewportRef.current.zoom / 1.18);
      } else if (mod && e.key === '0') {
        e.preventDefault();
        zoomAtPoint(1);
      } else if ((e.key === 'Backspace' || e.key === 'Delete') && selectedIds.length > 0) {
        e.preventDefault();
        deleteSelected();
      } else if (e.key === ']') {
        reorderSelected('forward');
      } else if (e.key === '[') {
        reorderSelected('backward');
      } else if (!mod && !e.altKey) {
        if (key === 'v') setTool('select');
        else if (key === 't') setTool('text');
        else if (key === 's') setTool('sticky');
        else if (key === 'r') setTool('rect');
        else if (key === 'o') setTool('ellipse');
        else if (key === 'l') setTool('line');
        else if (key === 'a') setTool('arrow');
        else if (key === 'p') setTool('freehand');
        else if (key === 'i') {
          pendingImagePosRef.current = null;
          fileInputRef.current?.click();
        } else if (key === 'w') {
          setLiveModalUrl('https://');
          setLiveModalOpen(true);
        } else if (key === 'f') setTool('frame');
      }
    };

    const onKeyUp = (e: KeyboardEvent) => {
      if (e.code === 'Space') setSpaceDown(false);
    };

    const onPaste = (e: ClipboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return;
      const items = e.clipboardData?.items;
      if (!items) return;
      for (const item of Array.from(items)) {
        if (item.type.startsWith('image/')) {
          const file = item.getAsFile();
          if (file) {
            e.preventDefault();
            void insertImageFile(file);
            return;
          }
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('paste', onPaste);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('paste', onPaste);
    };
  }, [
    presenting,
    editingId,
    selectedIds,
    handleUndo,
    handleRedo,
    duplicateSelected,
    deleteSelected,
    reorderSelected,
    commitElements,
    zoomAtPoint,
    insertImageFile,
    showToast,
  ]);

  // Global pointermove / pointerup for pan, move, 8-handle resize, rotate, marquee, draw.
  useEffect(() => {
    const onPointerMove = (e: PointerEvent) => {
      if (drawingFreehand) {
        const pt = screenToCanvas(e.clientX, e.clientY);
        setDrawingFreehand((cur) => (cur ? { ...cur, points: [...cur.points, [pt.x, pt.y]] } : null));
        return;
      }

      if (drawingShape) {
        const pt = screenToCanvas(e.clientX, e.clientY);
        setDrawingShape((cur) => (cur ? { ...cur, x2: pt.x, y2: pt.y } : null));
        return;
      }

      const inter = interactionRef.current;
      if (!inter) return;

      if (inter.kind === 'pan') {
        setViewport((vp) => ({
          ...vp,
          x: inter.origPanX + (e.clientX - inter.startClientX),
          y: inter.origPanY + (e.clientY - inter.startClientY),
        }));
        return;
      }

      if (inter.kind === 'marquee') {
        const pt = screenToCanvas(e.clientX, e.clientY);
        setMarquee({ x1: inter.startX, y1: inter.startY, x2: pt.x, y2: pt.y });
        return;
      }

      const cur = docRef.current;
      if (!cur) return;
      const vp = viewportRef.current;

      if (inter.kind === 'move') {
        const rawDx = (e.clientX - inter.startClientX) / vp.zoom;
        const rawDy = (e.clientY - inter.startClientY) / vp.zoom;
        if (Math.abs(rawDx) > 1 || Math.abs(rawDy) > 1) inter.moved = true;
        const movingSet = new Set(inter.origPositions.keys());
        const snap = computeSnapping(
          movingSet,
          {
            x: inter.union.x + rawDx,
            y: inter.union.y + rawDy,
            width: inter.union.width,
            height: inter.union.height,
          },
          cur.elements,
          vp.zoom,
        );
        setGuides(snap.guides);
        const dx = Math.round(rawDx + snap.dx);
        const dy = Math.round(rawDy + snap.dy);
        setDoc((d) => {
          if (!d) return d;
          return {
            ...d,
            elements: d.elements.map((el) => {
              const orig = inter.origPositions.get(el.id);
              if (!orig) return el;
              return { ...el, x: orig.x + dx, y: orig.y + dy };
            }),
          };
        });
        return;
      }

      if (inter.kind === 'resize') {
        const dx = (e.clientX - inter.startClientX) / vp.zoom;
        const dy = (e.clientY - inter.startClientY) / vp.zoom;
        if (Math.abs(dx) > 1 || Math.abs(dy) > 1) inter.moved = true;
        const o = inter.orig;
        let x = o.x;
        let y = o.y;
        let w = o.width;
        let h = o.height;
        const minW = 36;
        const minH = 24;

        if (inter.dir.includes('e')) w = Math.max(minW, o.width + dx);
        if (inter.dir.includes('s')) h = Math.max(minH, o.height + dy);
        if (inter.dir.includes('w')) {
          const nextW = Math.max(minW, o.width - dx);
          x = o.x + (o.width - nextW);
          w = nextW;
        }
        if (inter.dir.includes('n')) {
          const nextH = Math.max(minH, o.height - dy);
          y = o.y + (o.height - nextH);
          h = nextH;
        }
        if (e.shiftKey && o.width > 0 && o.height > 0 && inter.dir.length === 2) {
          const aspect = o.width / o.height;
          if (w / h > aspect) w = h * aspect;
          else h = w / aspect;
        }

        const scaleX = w / Math.max(1, o.width);
        const scaleY = h / Math.max(1, o.height);

        setDoc((d) => {
          if (!d) return d;
          return {
            ...d,
            elements: d.elements.map((el) => {
              if (el.id !== inter.elementId) return el;
              const patch: Partial<EaselItem> = {
                x: Math.round(x),
                y: Math.round(y),
                width: Math.round(w),
                height: Math.round(h),
              };
              if (o.type === 'arrow' || o.type === 'line') {
                patch.start_x = Math.round((o.start_x ?? 6) * scaleX);
                patch.start_y = Math.round((o.start_y ?? o.height / 2) * scaleY);
                patch.end_x = Math.round((o.end_x ?? o.width - 6) * scaleX);
                patch.end_y = Math.round((o.end_y ?? o.height / 2) * scaleY);
              }
              return { ...el, ...patch };
            }),
          };
        });
        return;
      }

      if (inter.kind === 'rotate') {
        const pt = screenToCanvas(e.clientX, e.clientY);
        let deg = (Math.atan2(pt.y - inter.centerY, pt.x - inter.centerX) * 180) / Math.PI + 90;
        if (e.shiftKey) deg = Math.round(deg / 15) * 15;
        else deg = Math.round(deg);
        inter.moved = true;
        setDoc((d) => {
          if (!d) return d;
          return {
            ...d,
            elements: d.elements.map((el) => (el.id === inter.elementId ? { ...el, rotation: deg } : el)),
          };
        });
      }
    };

    const onPointerUp = () => {
      const cur = docRef.current;

      if (drawingFreehand && cur) {
        const pts = drawingFreehand.points;
        if (pts.length >= 2) {
          const xs = pts.map((p) => p[0]);
          const ys = pts.map((p) => p[1]);
          const pad = Math.max(6, strokeWidth * 2);
          const minX = Math.min(...xs) - pad;
          const minY = Math.min(...ys) - pad;
          const w = Math.max(24, Math.max(...xs) - minX + pad);
          const h = Math.max(24, Math.max(...ys) - minY + pad);
          const pathD = smoothSvgPath(pts, minX, minY);
          const maxZ = cur.elements.reduce((m, el) => Math.max(m, el.z_index), 0);
          const el: EaselItem = {
            id: drawingFreehand.id,
            type: 'freehand',
            x: Math.round(minX),
            y: Math.round(minY),
            width: Math.round(w),
            height: Math.round(h),
            content: pathD,
            fill_color: 'transparent',
            stroke_color: activeColor,
            stroke_width: strokeWidth,
            font_size: 14,
            z_index: maxZ + 1,
          };
          commitElements([...cur.elements, el]);
          setSelectedIds([el.id]);
        }
        setDrawingFreehand(null);
        return;
      }

      if (drawingShape && cur) {
        const { type, x1, y1, x2, y2 } = drawingShape;
        const dist = Math.hypot(x2 - x1, y2 - y1);
        const maxZ = cur.elements.reduce((m, el) => Math.max(m, el.z_index), 0);
        const minZ = cur.elements.reduce((m, el) => Math.min(m, el.z_index), 0);
        let el: EaselItem;

        if (type === 'arrow' || type === 'line') {
          const ex = dist < 12 ? x1 + 180 : x2;
          const ey = dist < 12 ? y1 : y2;
          const pad = 16;
          const minX = Math.min(x1, ex) - pad;
          const minY = Math.min(y1, ey) - pad;
          const w = Math.max(36, Math.abs(ex - x1) + pad * 2);
          const h = Math.max(32, Math.abs(ey - y1) + pad * 2);
          el = {
            id: `el-${Date.now()}`,
            type,
            x: Math.round(minX),
            y: Math.round(minY),
            width: Math.round(w),
            height: Math.round(h),
            content: '',
            fill_color: 'transparent',
            stroke_color: activeColor,
            stroke_width: strokeWidth,
            font_size: 14,
            z_index: maxZ + 1,
            start_x: Math.round(x1 - minX),
            start_y: Math.round(y1 - minY),
            end_x: Math.round(ex - minX),
            end_y: Math.round(ey - minY),
          };
        } else {
          const w = dist < 12 ? (type === 'frame' ? 420 : 220) : Math.max(48, Math.abs(x2 - x1));
          const h = dist < 12 ? (type === 'frame' ? 280 : 140) : Math.max(40, Math.abs(y2 - y1));
          const x = dist < 12 ? x1 : Math.min(x1, x2);
          const y = dist < 12 ? y1 : Math.min(y1, y2);
          el = {
            id: `el-${Date.now()}`,
            type,
            x: Math.round(x),
            y: Math.round(y),
            width: Math.round(w),
            height: Math.round(h),
            content: type === 'frame' ? 'Section Frame' : '',
            fill_color: type === 'frame' ? 'rgba(49, 57, 255, 0.04)' : activeColor,
            stroke_color: activeColor,
            stroke_width: type === 'frame' ? 2 : strokeWidth,
            font_size: type === 'frame' ? 13 : 16,
            z_index: type === 'frame' ? minZ - 1 : maxZ + 1,
          };
        }
        commitElements([...cur.elements, el]);
        setSelectedIds([el.id]);
        setDrawingShape(null);
        setTool('select');
        return;
      }

      const inter = interactionRef.current;
      if (!inter) return;
      interactionRef.current = null;
      setGuides([]);

      if (inter.kind === 'pan') {
        setIsPanning(false);
        return;
      }

      if (inter.kind === 'marquee') {
        if (marquee && cur) {
          const left = Math.min(marquee.x1, marquee.x2);
          const right = Math.max(marquee.x1, marquee.x2);
          const top = Math.min(marquee.y1, marquee.y2);
          const bottom = Math.max(marquee.y1, marquee.y2);
          if (right - left > 4 || bottom - top > 4) {
            const hits = cur.elements
              .filter((el) => el.x < right && el.x + el.width > left && el.y < bottom && el.y + el.height > top)
              .map((el) => el.id);
            setSelectedIds(hits);
          }
        }
        setMarquee(null);
        return;
      }

      if ((inter.kind === 'move' || inter.kind === 'resize' || inter.kind === 'rotate') && inter.moved && cur) {
        commitElements(cur.elements, true, inter.snapshot);
      }
    };

    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    return () => {
      window.removeEventListener('pointermove', onPointerMove);
      window.removeEventListener('pointerup', onPointerUp);
    };
  }, [drawingFreehand, drawingShape, marquee, activeColor, strokeWidth, screenToCanvas, commitElements]);

  const handleStageWheel = (e: WheelEvent) => {
    e.preventDefault();
    if (e.ctrlKey || e.metaKey) {
      const factor = Math.exp(-e.deltaY * 0.008);
      zoomAtPoint(viewportRef.current.zoom * factor, e.clientX, e.clientY);
    } else {
      setViewport((vp) => ({
        ...vp,
        x: vp.x - e.deltaX,
        y: vp.y - e.deltaY,
      }));
    }
  };

  const handleStagePointerDown = (e: PointerEvent) => {
    setExportMenuOpen(false);
    if (!doc) return;

    // Middle mouse or Space+drag or Presentation mode drag => Pan
    if (e.button === 1 || spaceDown || presenting) {
      e.preventDefault();
      setIsPanning(true);
      interactionRef.current = {
        kind: 'pan',
        startClientX: e.clientX,
        startClientY: e.clientY,
        origPanX: viewport.x,
        origPanY: viewport.y,
      };
      return;
    }

    if ((e.target as HTMLElement).closest('.easel-element')) return;
    setEditingId(null);

    const pt = screenToCanvas(e.clientX, e.clientY);

    if (tool === 'select') {
      setSelectedIds([]);
      interactionRef.current = { kind: 'marquee', startX: pt.x, startY: pt.y };
      setMarquee({ x1: pt.x, y1: pt.y, x2: pt.x, y2: pt.y });
      return;
    }

    if (tool === 'freehand') {
      setDrawingFreehand({ id: `el-${Date.now()}`, points: [[pt.x, pt.y]] });
      return;
    }

    if (tool === 'rect' || tool === 'ellipse' || tool === 'line' || tool === 'arrow' || tool === 'frame') {
      setDrawingShape({ type: tool, x1: pt.x, y1: pt.y, x2: pt.x, y2: pt.y });
      return;
    }

    if (tool === 'image') {
      pendingImagePosRef.current = pt;
      fileInputRef.current?.click();
      return;
    }

    if (tool === 'live_card') {
      setLiveModalPos(pt);
      setLiveModalUrl('https://');
      setLiveModalOpen(true);
      return;
    }

    const maxZ = doc.elements.reduce((m, el) => Math.max(m, el.z_index), 0);

    if (tool === 'text') {
      const el: EaselItem = {
        id: `el-${Date.now()}`,
        type: 'text',
        x: Math.round(pt.x),
        y: Math.round(pt.y),
        width: 260,
        height: 64,
        content: 'New text',
        fill_color: 'transparent',
        stroke_color: 'transparent',
        stroke_width: 0,
        font_size: 22,
        font_family: 'clean',
        font_weight: 'bold',
        font_style: 'normal',
        text_align: 'left',
        text_color: '',
        z_index: maxZ + 1,
      };
      commitElements([...doc.elements, el]);
      setSelectedIds([el.id]);
      setEditingId(el.id);
      setTool('select');
      return;
    }

    if (tool === 'sticky') {
      const sticky = STICKY_COLORS[0]!;
      const el: EaselItem = {
        id: `el-${Date.now()}`,
        type: 'sticky',
        x: Math.round(pt.x),
        y: Math.round(pt.y),
        width: 220,
        height: 180,
        content: 'Sticky note…',
        fill_color: sticky.bg,
        stroke_color: sticky.border,
        stroke_width: 1,
        font_size: 15,
        z_index: maxZ + 1,
      };
      commitElements([...doc.elements, el]);
      setSelectedIds([el.id]);
      setEditingId(el.id);
      setTool('select');
    }
  };

  const selectedItems = useMemo(() => {
    if (!doc) return [];
    const sel = new Set(selectedIds);
    return doc.elements.filter((el) => sel.has(el.id));
  }, [doc, selectedIds]);

  const primarySelected = selectedItems.length === 1 ? selectedItems[0]! : null;

  const patchSelected = useCallback(
    (patch: Partial<EaselItem>, pushUndo = true) => {
      const cur = docRef.current;
      if (!cur || selectedIds.length === 0) return;
      const sel = new Set(selectedIds);
      commitElements(
        cur.elements.map((el) => (sel.has(el.id) ? { ...el, ...patch } : el)),
        pushUndo,
      );
    },
    [selectedIds, commitElements],
  );

  const handleImageError = useCallback((el: EaselItem) => {
    const cur = docRef.current;
    if (!cur || !el.asset_id) return;
    if (el.data_url && resolvedImgSrcs[el.id] !== el.data_url) {
      setResolvedImgSrcs((prev) => ({ ...prev, [el.id]: el.data_url! }));
      return;
    }
    void readDocumentAsset(cur.id, el.asset_id).then((res) => {
      if (res?.dataUrl) {
        setResolvedImgSrcs((prev) => ({ ...prev, [el.id]: res.dataUrl }));
      }
    });
  }, [resolvedImgSrcs]);

  const handleExportHtml = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const res = await exportEaselHtml(doc);
    const blob = new Blob([res.html], { type: 'text/html' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    a.click();
    URL.revokeObjectURL(url);
    showToast(`Exported ${res.filename}`);
  };

  const handleExportPng = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    const isDark = window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false;
    const dataUrl = await renderEaselToPngDataUrl(doc, resolvedImgSrcs, isDark);
    if (!dataUrl) {
      showToast('Could not render Easel PNG');
      return;
    }
    const res = await exportEaselImage({ docId: doc.id, title: doc.title, data: dataUrl });
    const a = document.createElement('a');
    a.href = res.dataUrl || dataUrl;
    a.download = res.filename;
    a.click();
    showToast(`Exported ${res.filename}`);
  };

  const handleDuplicateEasel = async () => {
    if (!doc) return;
    setExportMenuOpen(false);
    try {
      const res = await duplicateEasel(doc.id);
      showToast(`Created "${res.title}"`);
    } catch {
      showToast('Could not duplicate Easel');
    }
  };

  if (!doc) return <div style={{ padding: '32px' }}>Loading Easel…</div>;

  const swatches = PALETTES[doc.palette ?? 'vibrant'];

  const bgStyle: JSX.CSSProperties =
    presenting || background === 'plain'
      ? {}
      : background === 'dots'
        ? {
            backgroundImage: 'radial-gradient(var(--border-strong) 1.2px, transparent 1.2px)',
            backgroundSize: `${Math.max(10, 24 * viewport.zoom)}px ${Math.max(10, 24 * viewport.zoom)}px`,
            backgroundPosition: `${viewport.x}px ${viewport.y}px`,
          }
        : {
            backgroundImage:
              'linear-gradient(to right, var(--border-subtle) 1px, transparent 1px), linear-gradient(to bottom, var(--border-subtle) 1px, transparent 1px)',
            backgroundSize: `${Math.max(10, 28 * viewport.zoom)}px ${Math.max(10, 28 * viewport.zoom)}px`,
            backgroundPosition: `${viewport.x}px ${viewport.y}px`,
          };

  return (
    <div class={`easel-shell${presenting ? ' is-presenting' : ''}`}>
      <input
        ref={fileInputRef}
        type="file"
        accept="image/png,image/jpeg,image/gif,image/webp,image/avif"
        style={{ display: 'none' }}
        onChange={(e) => {
          const file = (e.currentTarget as HTMLInputElement).files?.[0];
          if (file) void insertImageFile(file, pendingImagePosRef.current ?? undefined);
          (e.currentTarget as HTMLInputElement).value = '';
          pendingImagePosRef.current = null;
        }}
      />

      {!presenting && (
        <header class="easel-topbar">
          <div class="easel-topbar-group">
            <OpenDoorwayMark size={24} />
            <input
              class="easel-title-input"
              aria-label="Easel title"
              placeholder="Untitled Easel"
              value={doc.title}
              onInput={(e) => {
                const title = (e.currentTarget as HTMLInputElement).value;
                document.title = title || 'Untitled Easel';
                const next = { ...doc, title };
                setDoc(next);
                scheduleSave(next);
              }}
              onBlur={() => {
                if (doc) void renameEasel(doc.id, doc.title);
              }}
            />
            <span class={`easel-save-pill${saveState === 'saving' ? ' is-saving' : ''}`}>
              {saveState === 'saved' ? 'Saved' : 'Saving…'}
            </span>
          </div>

          <div class="easel-topbar-group">
            <button type="button" class="easel-icon-btn" title="Undo (Cmd/Ctrl+Z)" disabled={undoStack.length === 0} onClick={handleUndo}>
              <UndoIcon size={14} />
            </button>
            <button type="button" class="easel-icon-btn" title="Redo (Cmd/Ctrl+Shift+Z)" disabled={redoStack.length === 0} onClick={handleRedo}>
              <RedoIcon size={14} />
            </button>

            <SegmentedControl<CanvasBackground>
              ariaLabel="Canvas background"
              value={background}
              options={[
                { value: 'dots', label: 'Dots' },
                { value: 'grid', label: 'Grid' },
                { value: 'plain', label: 'Plain' },
              ]}
              onChange={(bg) => {
                setBackground(bg);
                const next = { ...doc, canvas_background: bg };
                setDoc(next);
                scheduleSave(next);
              }}
            />

            <div class="easel-zoom-group" aria-label="Zoom controls">
              <button type="button" class="easel-zoom-btn" title="Zoom out" onClick={() => zoomAtPoint(viewport.zoom / 1.2)}>
                −
              </button>
              <button type="button" class="easel-zoom-btn" title="Reset zoom" style={{ minWidth: '46px' }} onClick={() => zoomAtPoint(1)}>
                {Math.round(viewport.zoom * 100)}%
              </button>
              <button type="button" class="easel-zoom-btn" title="Zoom in" onClick={() => zoomAtPoint(viewport.zoom * 1.2)}>
                +
              </button>
              <button type="button" class="easel-zoom-btn" title="Fit to view" onClick={fitToView}>
                Fit
              </button>
            </div>

            <button
              type="button"
              class="easel-icon-btn"
              title="Presentation mode"
              onClick={() => {
                setPresenting(true);
                setSelectedIds([]);
                setEditingId(null);
              }}
            >
              ▶ Play
            </button>

            <div class="easel-menu-wrap">
              <button type="button" class="open-btn open-btn-primary" onClick={() => setExportMenuOpen((o) => !o)}>
                Share / Export ▾
              </button>
              {exportMenuOpen && (
                <div class="easel-dropdown" role="menu">
                  <button type="button" class="easel-dropdown-item" onClick={() => void handleExportPng()}>
                    <span>Export as PNG</span>
                    <span style={{ opacity: 0.55, fontSize: '11px' }}>2×</span>
                  </button>
                  <button type="button" class="easel-dropdown-item" onClick={() => void handleExportHtml()}>
                    <span>Export Standalone HTML</span>
                    <span style={{ opacity: 0.55, fontSize: '11px' }}>.html</span>
                  </button>
                  <button type="button" class="easel-dropdown-item" onClick={() => void handleDuplicateEasel()}>
                    <span>Duplicate Easel</span>
                  </button>
                </div>
              )}
            </div>
          </div>
        </header>
      )}

      {presenting && (
        <div class="easel-present-bar">
          <button type="button" class="easel-zoom-btn" onClick={fitToView}>
            Fit
          </button>
          <span style={{ fontSize: '11px', color: 'var(--text-secondary)' }}>{Math.round(viewport.zoom * 100)}%</span>
          <button type="button" class="open-btn open-btn-primary" style={{ height: '26px', padding: '0 10px' }} onClick={() => setPresenting(false)}>
            Exit Play (Esc)
          </button>
        </div>
      )}

      <div class="easel-workspace">
        <div
          ref={stageRef}
          class={`easel-stage${spaceDown ? ' is-panning' : ''}${isPanning ? ' is-panning-active' : ''}${tool !== 'select' && !spaceDown && !presenting ? ' is-crosshair' : ''}${dropActive ? ' is-drop-target' : ''}`}
          style={bgStyle}
          onWheel={handleStageWheel}
          onPointerDown={handleStagePointerDown}
          onDragOver={(e) => {
            e.preventDefault();
            setDropActive(true);
          }}
          onDragLeave={() => setDropActive(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDropActive(false);
            const pt = screenToCanvas(e.clientX, e.clientY);
            const files = e.dataTransfer?.files;
            if (files && files.length > 0) {
              for (const file of Array.from(files)) {
                if (file.type.startsWith('image/')) {
                  void insertImageFile(file, pt);
                }
              }
            }
          }}
        >
          <div
            class="easel-world"
            style={{ transform: `translate(${viewport.x}px, ${viewport.y}px) scale(${viewport.zoom})` }}
          >
            {/* Elements */}
            {doc.elements
              .slice()
              .sort((a, b) => a.z_index - b.z_index)
              .map((el) => {
                const isSelected = !presenting && selectedIds.includes(el.id);
                const isSingleSelected = isSelected && selectedIds.length === 1;
                const isEditing = !presenting && editingId === el.id;
                const imgSrc = resolvedImgSrcs[el.id] || el.image_url || el.data_url || '';

                return (
                  <div
                    key={el.id}
                    class={`easel-element${isSelected ? ' is-selected' : ''}${isEditing ? ' is-editing' : ''}`}
                    style={{
                      left: `${el.x}px`,
                      top: `${el.y}px`,
                      width: `${el.width}px`,
                      height: `${el.height}px`,
                      zIndex: el.z_index,
                      opacity: el.opacity ?? 1,
                      transform: el.rotation ? `rotate(${el.rotation}deg)` : undefined,
                    }}
                    onDblClick={(e) => {
                      if (presenting) return;
                      e.stopPropagation();
                      if (el.type === 'text' || el.type === 'sticky' || el.type === 'rect' || el.type === 'ellipse' || el.type === 'frame') {
                        setSelectedIds([el.id]);
                        setEditingId(el.id);
                      }
                    }}
                    onPointerDown={(e) => {
                      if (presenting || spaceDown || e.button === 1) return;
                      if (isEditing) {
                        e.stopPropagation();
                        return;
                      }
                      e.stopPropagation();
                      let nextSel: string[];
                      if (e.shiftKey) {
                        nextSel = selectedIds.includes(el.id)
                          ? selectedIds.filter((id) => id !== el.id)
                          : [...selectedIds, el.id];
                      } else if (selectedIds.includes(el.id)) {
                        nextSel = selectedIds;
                      } else {
                        nextSel = [el.id];
                      }
                      setSelectedIds(nextSel);
                      setEditingId(null);

                      const movingEls = doc.elements.filter((x) => nextSel.includes(x.id));
                      if (movingEls.length === 0) return;
                      const origPositions = new Map<string, { x: number; y: number }>();
                      for (const m of movingEls) origPositions.set(m.id, { x: m.x, y: m.y });
                      const minX = Math.min(...movingEls.map((m) => m.x));
                      const minY = Math.min(...movingEls.map((m) => m.y));
                      const maxX = Math.max(...movingEls.map((m) => m.x + m.width));
                      const maxY = Math.max(...movingEls.map((m) => m.y + m.height));

                      interactionRef.current = {
                        kind: 'move',
                        startClientX: e.clientX,
                        startClientY: e.clientY,
                        snapshot: doc.elements.map((x) => ({ ...x })),
                        origPositions,
                        union: { x: minX, y: minY, width: maxX - minX, height: maxY - minY },
                        moved: false,
                      };
                    }}
                  >
                    {/* TEXT */}
                    {el.type === 'text' && (
                      <div
                        style={{
                          width: '100%',
                          height: '100%',
                          padding: '6px',
                          fontSize: `${el.font_size}px`,
                          fontFamily: FONT_FAMILY_CSS[el.font_family ?? 'clean'],
                          fontWeight: el.font_weight === 'bold' ? 700 : 500,
                          fontStyle: el.font_style ?? 'normal',
                          textAlign: el.text_align ?? 'left',
                          color: el.text_color || 'var(--text-primary)',
                          whiteSpace: 'pre-wrap',
                          lineHeight: 1.35,
                        }}
                      >
                        {isEditing ? (
                          <textarea
                            class="easel-inline-textarea"
                            autoFocus
                            value={el.content}
                            style={{ textAlign: el.text_align ?? 'left' }}
                            onInput={(ev) => patchSelected({ content: (ev.currentTarget as HTMLTextAreaElement).value }, false)}
                            onBlur={() => setEditingId(null)}
                          />
                        ) : (
                          el.content || 'Double-click to edit'
                        )}
                      </div>
                    )}

                    {/* STICKY NOTE */}
                    {el.type === 'sticky' && (
                      <div
                        class="easel-sticky"
                        style={{
                          background: el.fill_color || '#FFF3B0',
                          border: `1px solid ${el.stroke_color || '#E8D575'}`,
                          fontSize: `${el.font_size}px`,
                          fontFamily: FONT_FAMILY_CSS[el.font_family ?? 'clean'],
                        }}
                      >
                        {isEditing ? (
                          <textarea
                            class="easel-inline-textarea"
                            autoFocus
                            value={el.content}
                            onInput={(ev) => patchSelected({ content: (ev.currentTarget as HTMLTextAreaElement).value }, false)}
                            onBlur={() => setEditingId(null)}
                          />
                        ) : (
                          <div style={{ whiteSpace: 'pre-wrap', lineHeight: 1.4 }}>{el.content}</div>
                        )}
                      </div>
                    )}

                    {/* RECT / ELLIPSE / FRAME */}
                    {(el.type === 'rect' || el.type === 'ellipse' || el.type === 'frame') && (
                      <div
                        style={{
                          width: '100%',
                          height: '100%',
                          borderRadius: el.type === 'ellipse' ? '50%' : el.type === 'frame' ? '14px' : '12px',
                          background: el.fill_color || 'transparent',
                          border: `${el.stroke_width}px ${el.type === 'frame' ? 'dashed' : 'solid'} ${el.stroke_color || '#3139FB'}`,
                          color: el.type === 'frame' ? 'var(--text-secondary)' : '#ffffff',
                          padding: el.type === 'frame' ? '10px 14px' : '12px',
                          fontSize: `${el.font_size}px`,
                          fontWeight: 600,
                          whiteSpace: 'pre-wrap',
                          display: 'flex',
                          alignItems: el.type === 'frame' ? 'flex-start' : 'center',
                          justifyContent: el.type === 'frame' ? 'flex-start' : 'center',
                          textAlign: el.type === 'frame' ? 'left' : 'center',
                        }}
                      >
                        {isEditing ? (
                          <textarea
                            class="easel-inline-textarea"
                            autoFocus
                            value={el.content}
                            style={{ textAlign: el.type === 'frame' ? 'left' : 'center' }}
                            onInput={(ev) => patchSelected({ content: (ev.currentTarget as HTMLTextAreaElement).value }, false)}
                            onBlur={() => setEditingId(null)}
                          />
                        ) : (
                          el.content
                        )}
                      </div>
                    )}

                    {/* LINE & ARROW */}
                    {(el.type === 'line' || el.type === 'arrow') && (() => {
                      const x1 = el.start_x ?? 6;
                      const y1 = el.start_y ?? el.height / 2;
                      const x2 = el.end_x ?? el.width - 6;
                      const y2 = el.end_y ?? el.height / 2;
                      const ang = Math.atan2(y2 - y1, x2 - x1);
                      const head = Math.max(10, (el.stroke_width || 3) * 3.5);
                      const hx1 = x2 - head * Math.cos(ang - 0.45);
                      const hy1 = y2 - head * Math.sin(ang - 0.45);
                      const hx2 = x2 - head * Math.cos(ang + 0.45);
                      const hy2 = y2 - head * Math.sin(ang + 0.45);
                      return (
                        <svg width="100%" height="100%" viewBox={`0 0 ${el.width} ${el.height}`} style={{ overflow: 'visible' }}>
                          <line
                            x1={x1}
                            y1={y1}
                            x2={x2}
                            y2={y2}
                            stroke={el.stroke_color || '#3139FB'}
                            stroke-width={el.stroke_width || 3}
                            stroke-linecap="round"
                          />
                          {el.type === 'arrow' && (
                            <polyline
                              points={`${hx1},${hy1} ${x2},${y2} ${hx2},${hy2}`}
                              fill="none"
                              stroke={el.stroke_color || '#3139FB'}
                              stroke-width={el.stroke_width || 3}
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            />
                          )}
                        </svg>
                      );
                    })()}

                    {/* FREEHAND */}
                    {el.type === 'freehand' && (
                      <svg width="100%" height="100%" viewBox={`0 0 ${el.width} ${el.height}`} style={{ overflow: 'visible' }}>
                        <path
                          d={el.content}
                          fill="none"
                          stroke={el.stroke_color || '#3139FB'}
                          stroke-width={el.stroke_width || 3}
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    )}

                    {/* IMAGE */}
                    {el.type === 'image' && (
                      <div
                        style={{
                          width: '100%',
                          height: '100%',
                          borderRadius: '10px',
                          overflow: 'hidden',
                          background: 'var(--bg-card)',
                          border: '1px solid var(--border-subtle)',
                          boxShadow: '0 4px 16px rgba(0,0,0,0.1)',
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                        }}
                      >
                        {imgSrc ? (
                          <img
                            src={imgSrc}
                            alt={el.content || 'Image'}
                            draggable={false}
                            style={{ width: '100%', height: '100%', objectFit: 'cover', display: 'block', pointerEvents: 'none' }}
                            onError={() => handleImageError(el)}
                          />
                        ) : (
                          <span style={{ fontSize: '12px', color: 'var(--text-tertiary)' }}>Image</span>
                        )}
                      </div>
                    )}

                    {/* LIVE WEB CAPTURE CARD */}
                    {el.type === 'live_card' && (
                      <div class="easel-live-card">
                        <div class="easel-live-card-header">
                          <span class="easel-live-card-url" title={el.live_url || el.content}>
                            {el.live_title || el.live_url || el.content}
                          </span>
                          <div class="easel-live-card-actions" onPointerDown={(ev) => ev.stopPropagation()}>
                            <button
                              type="button"
                              class="easel-live-mini-btn"
                              title="Refresh snapshot"
                              disabled={Boolean(refreshingIds[el.id])}
                              onClick={() => void refreshLiveCard(el)}
                            >
                              {refreshingIds[el.id] ? '…' : '↻'}
                            </button>
                            <button
                              type="button"
                              class="easel-live-mini-btn"
                              title="Open in Peek"
                              onClick={() => void openDocumentUrl(el.live_url || el.content, 'peek')}
                            >
                              Peek
                            </button>
                            <button
                              type="button"
                              class="easel-live-mini-btn"
                              title="Open in new tab"
                              onClick={() => void openDocumentUrl(el.live_url || el.content, 'tab')}
                            >
                              ↗
                            </button>
                          </div>
                        </div>
                        <div class="easel-live-card-body">
                          {imgSrc ? (
                            <img src={imgSrc} alt={el.live_title || 'Live capture'} onError={() => handleImageError(el)} />
                          ) : (
                            <div style={{ padding: '16px', textAlign: 'center', fontSize: '12px', color: 'var(--text-secondary)' }}>
                              <div style={{ fontWeight: 600, marginBottom: '4px', color: 'var(--text-primary)' }}>
                                {el.live_title || el.live_url || el.content}
                              </div>
                              <div>Click ↻ to capture a fresh web snapshot</div>
                            </div>
                          )}
                        </div>
                        <div class="easel-live-card-footer">
                          <span>{formatTimestamp(el.last_refreshed_at)}</span>
                          <span style={{ color: 'var(--open-success)', fontWeight: 700 }}>LIVE</span>
                        </div>
                      </div>
                    )}

                    {/* 8-HANDLE RESIZE + ROTATION HANDLE */}
                    {isSingleSelected && !isEditing && (
                      <>
                        <div class="easel-rotate-stem" />
                        <div
                          class="easel-rotate-handle"
                          title="Rotate (hold Shift for 15° snap)"
                          onPointerDown={(ev) => {
                            ev.stopPropagation();
                            interactionRef.current = {
                              kind: 'rotate',
                              elementId: el.id,
                              centerX: el.x + el.width / 2,
                              centerY: el.y + el.height / 2,
                              snapshot: doc.elements.map((x) => ({ ...x })),
                              moved: false,
                            };
                          }}
                        />
                        {(['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'] as const).map((dir) => (
                          <div
                            key={dir}
                            class={`easel-handle easel-handle-${dir}`}
                            onPointerDown={(ev) => {
                              ev.stopPropagation();
                              interactionRef.current = {
                                kind: 'resize',
                                elementId: el.id,
                                dir,
                                startClientX: ev.clientX,
                                startClientY: ev.clientY,
                                orig: { ...el },
                                snapshot: doc.elements.map((x) => ({ ...x })),
                                moved: false,
                              };
                            }}
                          />
                        ))}
                      </>
                    )}
                  </div>
                );
              })}

            {/* Marquee box */}
            {marquee && (
              <div
                class="easel-marquee"
                style={{
                  left: `${Math.min(marquee.x1, marquee.x2)}px`,
                  top: `${Math.min(marquee.y1, marquee.y2)}px`,
                  width: `${Math.abs(marquee.x2 - marquee.x1)}px`,
                  height: `${Math.abs(marquee.y2 - marquee.y1)}px`,
                }}
              />
            )}

            {/* SVG Overlay: Snapping guides, live freehand stroke, live shape drag preview */}
            {(guides.length > 0 || drawingFreehand || drawingShape) && (
              <svg class="easel-svg-overlay" viewBox="-4000 -4000 8000 8000">
                {guides.map((g, idx) =>
                  g.vertical ? (
                    <line key={idx} x1={g.pos} y1={g.start} x2={g.pos} y2={g.end} stroke="#6CBAD9" stroke-width={1 / viewport.zoom} stroke-dasharray="4 3" />
                  ) : (
                    <line key={idx} x1={g.start} y1={g.pos} x2={g.end} y2={g.pos} stroke="#6CBAD9" stroke-width={1 / viewport.zoom} stroke-dasharray="4 3" />
                  ),
                )}
                {drawingFreehand && drawingFreehand.points.length > 1 && (
                  <path
                    d={smoothSvgPath(drawingFreehand.points, 0, 0)}
                    fill="none"
                    stroke={activeColor}
                    stroke-width={strokeWidth}
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                )}
                {drawingShape && (drawingShape.type === 'line' || drawingShape.type === 'arrow') && (
                  <line
                    x1={drawingShape.x1}
                    y1={drawingShape.y1}
                    x2={drawingShape.x2}
                    y2={drawingShape.y2}
                    stroke={activeColor}
                    stroke-width={strokeWidth}
                    stroke-linecap="round"
                  />
                )}
                {drawingShape && (drawingShape.type === 'rect' || drawingShape.type === 'frame') && (
                  <rect
                    x={Math.min(drawingShape.x1, drawingShape.x2)}
                    y={Math.min(drawingShape.y1, drawingShape.y2)}
                    width={Math.abs(drawingShape.x2 - drawingShape.x1)}
                    height={Math.abs(drawingShape.y2 - drawingShape.y1)}
                    rx={12}
                    fill={drawingShape.type === 'frame' ? 'rgba(49,57,255,0.05)' : activeColor}
                    fill-opacity={drawingShape.type === 'frame' ? 1 : 0.25}
                    stroke={activeColor}
                    stroke-width={strokeWidth}
                    stroke-dasharray={drawingShape.type === 'frame' ? '6 4' : undefined}
                  />
                )}
                {drawingShape && drawingShape.type === 'ellipse' && (
                  <ellipse
                    cx={(drawingShape.x1 + drawingShape.x2) / 2}
                    cy={(drawingShape.y1 + drawingShape.y2) / 2}
                    rx={Math.abs(drawingShape.x2 - drawingShape.x1) / 2}
                    ry={Math.abs(drawingShape.y2 - drawingShape.y1) / 2}
                    fill={activeColor}
                    fill-opacity={0.25}
                    stroke={activeColor}
                    stroke-width={strokeWidth}
                  />
                )}
              </svg>
            )}
          </div>
        </div>

        {/* Right Inspector Panel */}
        {!presenting && (
          <aside class="easel-inspector">
            <div>
              <div class="easel-section-title">Palette</div>
              <SegmentedControl<'vibrant' | 'chill'>
                ariaLabel="Easel palette"
                value={doc.palette ?? 'vibrant'}
                options={[
                  { value: 'vibrant', label: 'Vibrant' },
                  { value: 'chill', label: 'Chill' },
                ]}
                onChange={(palette) => {
                  const next = { ...doc, palette };
                  setDoc(next);
                  scheduleSave(next);
                }}
              />
              <div class="palette-swatches" style={{ marginTop: '10px' }}>
                {swatches.map((hex) => (
                  <button
                    key={hex}
                    type="button"
                    class={`palette-swatch${activeColor.toLowerCase() === hex.toLowerCase() ? ' is-active' : ''}`}
                    style={{ background: hex }}
                    aria-label={`Color ${hex}`}
                    onClick={() => {
                      setActiveColor(hex);
                      if (primarySelected) {
                        if (primarySelected.type === 'text') {
                          patchSelected({ text_color: hex });
                        } else if (primarySelected.type === 'arrow' || primarySelected.type === 'line' || primarySelected.type === 'freehand') {
                          patchSelected({ stroke_color: hex });
                        } else if (primarySelected.type === 'frame') {
                          patchSelected({ stroke_color: hex });
                        } else {
                          patchSelected({ fill_color: hex, stroke_color: hex });
                        }
                      }
                    }}
                  />
                ))}
              </div>
            </div>

            {primarySelected ? (
              <div style={{ display: 'flex', flexDirection: 'column', gap: '12px', borderTop: '1px solid var(--border-subtle)', paddingTop: '12px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <strong style={{ textTransform: 'capitalize' }}>{primarySelected.type.replace('_', ' ')}</strong>
                  <div style={{ display: 'flex', gap: '4px' }}>
                    <button type="button" class="easel-chip-btn" title="Duplicate (Cmd/Ctrl+D)" onClick={duplicateSelected}>
                      Dup
                    </button>
                    <button type="button" class="open-btn open-btn-danger" style={{ height: '26px', padding: '0 8px' }} onClick={deleteSelected}>
                      <TrashIcon size={12} />
                    </button>
                  </div>
                </div>

                {/* Sticky pastel colors */}
                {primarySelected.type === 'sticky' && (
                  <div>
                    <div class="easel-section-title">Sticky Color</div>
                    <div style={{ display: 'flex', gap: '6px' }}>
                      {STICKY_COLORS.map((s) => (
                        <button
                          key={s.name}
                          type="button"
                          title={s.name}
                          class={`palette-swatch${primarySelected.fill_color === s.bg ? ' is-active' : ''}`}
                          style={{ background: s.bg, borderColor: s.border }}
                          onClick={() => patchSelected({ fill_color: s.bg, stroke_color: s.border })}
                        />
                      ))}
                    </div>
                  </div>
                )}

                {/* Text formatting */}
                {(primarySelected.type === 'text' || primarySelected.type === 'sticky') && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                    <div class="easel-section-title">Typography</div>
                    <div class="easel-btn-row">
                      {(['clean', 'mono', 'fancy', 'hip'] as EaselFontFamily[]).map((f) => (
                        <button
                          key={f}
                          type="button"
                          class={`easel-chip-btn${(primarySelected.font_family ?? 'clean') === f ? ' is-active' : ''}`}
                          onClick={() => patchSelected({ font_family: f })}
                        >
                          {f[0]!.toUpperCase() + f.slice(1)}
                        </button>
                      ))}
                    </div>
                    {primarySelected.type === 'text' && (
                      <div class="easel-btn-row">
                        <button
                          type="button"
                          class={`easel-chip-btn${primarySelected.font_weight === 'bold' ? ' is-active' : ''}`}
                          onClick={() =>
                            patchSelected({ font_weight: primarySelected.font_weight === 'bold' ? 'normal' : 'bold' })
                          }
                        >
                          <strong>B</strong>
                        </button>
                        <button
                          type="button"
                          class={`easel-chip-btn${primarySelected.font_style === 'italic' ? ' is-active' : ''}`}
                          onClick={() =>
                            patchSelected({ font_style: primarySelected.font_style === 'italic' ? 'normal' : 'italic' })
                          }
                        >
                          <em>I</em>
                        </button>
                        {(['left', 'center', 'right'] as EaselTextAlign[]).map((align) => (
                          <button
                            key={align}
                            type="button"
                            class={`easel-chip-btn${(primarySelected.text_align ?? 'left') === align ? ' is-active' : ''}`}
                            onClick={() => patchSelected({ text_align: align })}
                          >
                            {align[0]!.toUpperCase()}
                          </button>
                        ))}
                      </div>
                    )}
                    <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                      <span>Size ({primarySelected.font_size}px)</span>
                      <input
                        type="range"
                        min="12"
                        max="64"
                        value={primarySelected.font_size}
                        onInput={(e) => patchSelected({ font_size: Number((e.currentTarget as HTMLInputElement).value) }, false)}
                      />
                    </label>
                  </div>
                )}

                {/* Stroke width */}
                {(primarySelected.type === 'rect' ||
                  primarySelected.type === 'ellipse' ||
                  primarySelected.type === 'line' ||
                  primarySelected.type === 'arrow' ||
                  primarySelected.type === 'freehand' ||
                  primarySelected.type === 'frame') && (
                  <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                    <span>Stroke width ({primarySelected.stroke_width}px)</span>
                    <input
                      type="range"
                      min="1"
                      max="12"
                      value={primarySelected.stroke_width}
                      onInput={(e) => {
                        const v = Number((e.currentTarget as HTMLInputElement).value);
                        setStrokeWidth(v);
                        patchSelected({ stroke_width: v }, false);
                      }}
                    />
                  </label>
                )}

                {/* Live Capture URL controls */}
                {primarySelected.type === 'live_card' && (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                    <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                      <span>Live URL</span>
                      <input
                        class="open-input"
                        value={primarySelected.live_url || primarySelected.content}
                        onInput={(e) => {
                          const v = (e.currentTarget as HTMLInputElement).value;
                          patchSelected({ live_url: v, content: v }, false);
                        }}
                      />
                    </label>
                    <div class="easel-btn-row">
                      <button type="button" class="open-btn open-btn-primary" style={{ flex: 1 }} onClick={() => void refreshLiveCard(primarySelected)}>
                        ↻ Refresh
                      </button>
                      <button
                        type="button"
                        class="open-btn"
                        onClick={() => void openDocumentUrl(primarySelected.live_url || primarySelected.content, 'tab')}
                      >
                        Open
                      </button>
                    </div>
                  </div>
                )}

                {/* Layer Order & Rotation */}
                <div>
                  <div class="easel-section-title">Layer Order</div>
                  <div class="easel-btn-row">
                    <button type="button" class="easel-chip-btn" onClick={() => reorderSelected('front')}>Front</button>
                    <button type="button" class="easel-chip-btn" onClick={() => reorderSelected('forward')}>+1</button>
                    <button type="button" class="easel-chip-btn" onClick={() => reorderSelected('backward')}>−1</button>
                    <button type="button" class="easel-chip-btn" onClick={() => reorderSelected('back')}>Back</button>
                  </div>
                </div>

                <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                  <span>Rotation ({primarySelected.rotation ?? 0}°)</span>
                  <input
                    type="range"
                    min="-180"
                    max="180"
                    value={primarySelected.rotation ?? 0}
                    onInput={(e) => patchSelected({ rotation: Number((e.currentTarget as HTMLInputElement).value) }, false)}
                  />
                </label>

                <div style={{ fontSize: '11px', color: 'var(--text-tertiary)', fontFamily: 'var(--font-mono)' }}>
                  x:{primarySelected.x} y:{primarySelected.y} · {primarySelected.width}×{primarySelected.height}
                </div>
              </div>
            ) : selectedItems.length > 1 ? (
              <div style={{ display: 'flex', flexDirection: 'column', gap: '10px', borderTop: '1px solid var(--border-subtle)', paddingTop: '12px' }}>
                <strong>{selectedItems.length} items selected</strong>
                <div class="easel-btn-row">
                  <button type="button" class="easel-chip-btn" onClick={duplicateSelected}>Duplicate</button>
                  <button type="button" class="easel-chip-btn" onClick={() => reorderSelected('front')}>Bring Front</button>
                  <button type="button" class="open-btn open-btn-danger" style={{ height: '26px', padding: '0 8px' }} onClick={deleteSelected}>
                    Delete All
                  </button>
                </div>
              </div>
            ) : (
              <div style={{ fontSize: '12px', color: 'var(--text-secondary)', borderTop: '1px solid var(--border-subtle)', paddingTop: '12px', lineHeight: 1.55 }}>
                Pick a tool from the dock or press its shortcut (<kbd>V</kbd>, <kbd>T</kbd>, <kbd>S</kbd>, <kbd>R</kbd>, <kbd>O</kbd>, <kbd>L</kbd>, <kbd>A</kbd>, <kbd>P</kbd>, <kbd>I</kbd>, <kbd>W</kbd>, <kbd>F</kbd>). Hold <kbd>Space</kbd> to pan, scroll to move, or <kbd>⌘/Ctrl+Scroll</kbd> to zoom. Paste or drop images anywhere.
              </div>
            )}
          </aside>
        )}
      </div>

      {/* Floating Bottom Tool Dock */}
      {!presenting && (
        <div class="easel-dock" role="toolbar" aria-label="Easel tools">
          {TOOL_DEFS.map((t, idx) => (
            <>
              {(idx === 1 || idx === 8) && <span class="easel-dock-sep" />}
              <button
                key={t.id}
                type="button"
                title={`${t.label} (${t.key})`}
                aria-label={t.label}
                aria-pressed={tool === t.id}
                class={`easel-dock-btn${tool === t.id ? ' is-active' : ''}`}
                onClick={() => {
                  if (t.id === 'image') {
                    pendingImagePosRef.current = null;
                    fileInputRef.current?.click();
                  } else if (t.id === 'live_card') {
                    const rect = stageRef.current?.getBoundingClientRect();
                    if (rect) {
                      const c = screenToCanvas(rect.left + rect.width / 2, rect.top + rect.height / 2);
                      setLiveModalPos({ x: c.x - 190, y: c.y - 125 });
                    }
                    setLiveModalUrl('https://');
                    setLiveModalOpen(true);
                  } else {
                    setTool(t.id);
                  }
                }}
              >
                {t.icon()}
                <span class="easel-dock-key">{t.key}</span>
              </button>
            </>
          ))}
        </div>
      )}

      {/* Live Web Capture URL Modal */}
      <Modal
        open={liveModalOpen}
        title="Add Live Web Capture Card"
        onClose={() => setLiveModalOpen(false)}
        footer={
          <>
            <button type="button" class="open-btn" onClick={() => setLiveModalOpen(false)}>
              Cancel
            </button>
            <button
              type="button"
              class="open-btn open-btn-primary"
              onClick={() => void createLiveCaptureCard(liveModalUrl, liveModalPos)}
            >
              Capture & Add
            </button>
          </>
        }
      >
        <p style={{ margin: 0, fontSize: '12.5px', color: 'var(--text-secondary)' }}>
          Enter a website URL to embed a live snapshot card that you can refresh anytime.
        </p>
        <input
          class="open-input"
          autoFocus
          value={liveModalUrl}
          placeholder="https://example.com"
          onInput={(e) => setLiveModalUrl((e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void createLiveCaptureCard(liveModalUrl, liveModalPos);
          }}
        />
      </Modal>

      <Toast message={toast} />
    </div>
  );
}
