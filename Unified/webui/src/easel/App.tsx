import type { JSX } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { type EaselDocument, type EaselElement, type EaselElementType, rpc } from '../shared/bridge';
import { Badge, SegmentedControl, Toast } from '../shared/components';
import { DownloadIcon, OpenDoorwayMark, RedoIcon, TrashIcon, UndoIcon } from '../shared/icons';

type ToolKind = 'pointer' | EaselElementType;

const TOOLS: readonly { id: ToolKind; label: string }[] = [
  { id: 'pointer', label: 'Pointer' },
  { id: 'text', label: 'Text' },
  { id: 'rect', label: 'Rect' },
  { id: 'ellipse', label: 'Ellipse' },
  { id: 'arrow', label: 'Arrow' },
  { id: 'freehand', label: 'Pen' },
  { id: 'image', label: 'Image' },
  { id: 'live_card', label: 'Live Card' },
];

const PALETTES: Record<'vibrant' | 'chill', readonly string[]> = {
  vibrant: ['#3139FF', '#FF5C35', '#00B87C', '#FFB800', '#A855F7', '#EC4899'],
  chill: ['#4F6D7A', '#6B8F71', '#A599B5', '#D9A773', '#7A9CC6', '#8C6D62'],
};

const MIN_ZOOM = 0.33;
const MAX_ZOOM = 4.0;

export function EaselApp(): JSX.Element {
  const [doc, setDoc] = useState<EaselDocument | null>(null);
  const [tool, setTool] = useState<ToolKind>('pointer');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [activeColor, setActiveColor] = useState<string>(PALETTES.vibrant[0]!);
  const [zoom, setZoom] = useState<number>(1.0);
  const [undoStack, setUndoStack] = useState<EaselElement[][]>([]);
  const [redoStack, setRedoStack] = useState<EaselElement[][]>([]);
  const [saveState, setSaveState] = useState<'saved' | 'saving'>('saved');
  const [toast, setToast] = useState<string | null>(null);
  const [drawingFreehand, setDrawingFreehand] = useState<{ id: string; points: [number, number][] } | null>(null);

  const canvasRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<{
    kind: 'move' | 'resize';
    elementId: string;
    startClientX: number;
    startClientY: number;
    origX: number;
    origY: number;
    origW: number;
    origH: number;
  } | null>(null);
  const saveTimerRef = useRef<number | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast((c) => (c === msg ? null : c)), 2600);
  };

  useEffect(() => {
    const idFromPath = window.location.pathname.replace(/^\/+/, '').split('/')[1] || window.location.hash.replace(/^#/, '');
    void rpc('easel.load', { id: idFromPath || undefined }).then((res) => {
      setDoc(res.document);
      const pal = PALETTES[res.document.palette];
      if (pal[0]) setActiveColor(pal[0]);
    });
  }, []);

  const scheduleSave = (nextDoc: EaselDocument) => {
    setSaveState('saving');
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      void rpc('easel.save', { document: nextDoc }).then(() => setSaveState('saved'));
    }, 500);
  };

  const commitElements = (nextElements: EaselElement[], pushUndo = true) => {
    if (!doc) return;
    if (pushUndo) {
      setUndoStack((prev) => [...prev.slice(-39), doc.elements.map((e) => ({ ...e }))]);
      setRedoStack([]);
    }
    const maxBottom = nextElements.reduce((acc, el) => Math.max(acc, el.y + el.height + 240), 1400);
    const nextDoc: EaselDocument = {
      ...doc,
      canvas_height: Math.max(1400, Math.ceil(maxBottom)),
      elements: nextElements,
    };
    setDoc(nextDoc);
    scheduleSave(nextDoc);
  };

  const handleUndo = () => {
    if (!doc || undoStack.length === 0) return;
    const prevElements = undoStack[undoStack.length - 1]!;
    setUndoStack((s) => s.slice(0, -1));
    setRedoStack((r) => [...r, doc.elements.map((e) => ({ ...e }))]);
    const nextDoc = { ...doc, elements: prevElements };
    setDoc(nextDoc);
    scheduleSave(nextDoc);
  };

  const handleRedo = () => {
    if (!doc || redoStack.length === 0) return;
    const nextElements = redoStack[redoStack.length - 1]!;
    setRedoStack((r) => r.slice(0, -1));
    setUndoStack((s) => [...s, doc.elements.map((e) => ({ ...e }))]);
    const nextDoc = { ...doc, elements: nextElements };
    setDoc(nextDoc);
    scheduleSave(nextDoc);
  };

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return;
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        if (e.shiftKey) handleRedo();
        else handleUndo();
      } else if (mod && (e.key === '=' || e.key === '+')) {
        e.preventDefault();
        setZoom((z) => Math.min(MAX_ZOOM, Number((z + 0.15).toFixed(2))));
      } else if (mod && e.key === '-') {
        e.preventDefault();
        setZoom((z) => Math.max(MIN_ZOOM, Number((z - 0.15).toFixed(2))));
      } else if (mod && e.key === '0') {
        e.preventDefault();
        setZoom(1.0);
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedId && doc) {
        e.preventDefault();
        commitElements(doc.elements.filter((el) => el.id !== selectedId));
        setSelectedId(null);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [doc, selectedId, undoStack, redoStack]);

  // Global pointer drag/resize/freehand handlers
  useEffect(() => {
    const onPointerMove = (e: PointerEvent) => {
      if (drawingFreehand && canvasRef.current) {
        const rect = canvasRef.current.getBoundingClientRect();
        const x = Math.max(0, Math.min(1000, (e.clientX - rect.left) / zoom));
        const y = Math.max(0, (e.clientY - rect.top) / zoom);
        setDrawingFreehand((cur) => (cur ? { ...cur, points: [...cur.points, [x, y]] } : null));
        return;
      }
      const drag = dragRef.current;
      if (!drag || !doc) return;
      const dx = (e.clientX - drag.startClientX) / zoom;
      const dy = (e.clientY - drag.startClientY) / zoom;
      setDoc((cur) => {
        if (!cur) return cur;
        return {
          ...cur,
          elements: cur.elements.map((el) => {
            if (el.id !== drag.elementId) return el;
            if (drag.kind === 'move') {
              return {
                ...el,
                x: Math.max(0, Math.min(cur.canvas_width - el.width, Math.round(drag.origX + dx))),
                y: Math.max(0, Math.round(drag.origY + dy)),
              };
            }
            return {
              ...el,
              width: Math.max(48, Math.round(drag.origW + dx)),
              height: Math.max(32, Math.round(drag.origH + dy)),
            };
          }),
        };
      });
    };

    const onPointerUp = () => {
      if (drawingFreehand && doc) {
        const pts = drawingFreehand.points;
        if (pts.length >= 2) {
          const xs = pts.map((p) => p[0]);
          const ys = pts.map((p) => p[1]);
          const minX = Math.min(...xs);
          const minY = Math.min(...ys);
          const w = Math.max(24, Math.max(...xs) - minX);
          const h = Math.max(24, Math.max(...ys) - minY);
          const pathD = pts
            .map(([px, py], i) => `${i === 0 ? 'M' : 'L'}${(px - minX).toFixed(1)},${(py - minY).toFixed(1)}`)
            .join(' ');
          const el: EaselElement = {
            id: drawingFreehand.id,
            type: 'freehand',
            x: Math.round(minX),
            y: Math.round(minY),
            width: Math.round(w),
            height: Math.round(h),
            content: pathD,
            fill_color: 'transparent',
            stroke_color: activeColor,
            stroke_width: 3,
            font_size: 14,
            z_index: doc.elements.length + 1,
          };
          commitElements([...doc.elements, el]);
          setSelectedId(el.id);
        }
        setDrawingFreehand(null);
        return;
      }
      if (dragRef.current && doc) {
        dragRef.current = null;
        scheduleSave(doc);
      }
    };

    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    return () => {
      window.removeEventListener('pointermove', onPointerMove);
      window.removeEventListener('pointerup', onPointerUp);
    };
  }, [doc, zoom, drawingFreehand, activeColor]);

  const handleCanvasPointerDown = (e: PointerEvent) => {
    if (!doc || !canvasRef.current) return;
    if ((e.target as HTMLElement).closest('.easel-element')) return;
    const rect = canvasRef.current.getBoundingClientRect();
    const x = Math.max(0, Math.min(doc.canvas_width - 40, Math.round((e.clientX - rect.left) / zoom)));
    const y = Math.max(0, Math.round((e.clientY - rect.top) / zoom));

    if (tool === 'pointer') {
      setSelectedId(null);
      return;
    }

    if (tool === 'freehand') {
      setDrawingFreehand({ id: `el-${Date.now()}`, points: [[x, y]] });
      return;
    }

    if (tool === 'live_card') {
      const liveCount = doc.elements.filter((el) => el.type === 'live_card').length;
      if (liveCount >= 3) {
        showToast('Easels support up to 3 Live Web Cards per canvas.');
        return;
      }
    }

    const base: EaselElement = {
      id: `el-${Date.now()}`,
      type: tool,
      x,
      y,
      width: tool === 'arrow' ? 140 : tool === 'live_card' ? 340 : 220,
      height: tool === 'arrow' ? 32 : tool === 'text' ? 56 : tool === 'live_card' ? 200 : 120,
      content:
        tool === 'text'
          ? 'Double-click or edit in inspector'
          : tool === 'live_card'
            ? 'https://example.com'
            : tool === 'image'
              ? 'Capture / Image Card'
              : tool === 'rect' || tool === 'ellipse'
                ? 'Note'
                : '',
      fill_color: tool === 'text' || tool === 'arrow' ? 'transparent' : activeColor,
      stroke_color: activeColor,
      stroke_width: tool === 'arrow' ? 3 : 2,
      font_size: tool === 'text' ? 22 : 15,
      z_index: doc.elements.length + 1,
    };

    commitElements([...doc.elements, base]);
    setSelectedId(base.id);
    setTool('pointer');
  };

  const selectedEl = doc?.elements.find((e) => e.id === selectedId) ?? null;

  const updateSelected = (patch: Partial<EaselElement>) => {
    if (!doc || !selectedId) return;
    commitElements(
      doc.elements.map((el) => (el.id === selectedId ? { ...el, ...patch } : el)),
      false,
    );
  };

  const handleExportHtml = async () => {
    if (!doc) return;
    const res = await rpc('easel.exportHtml', { document: doc });
    const blob = new Blob([res.html], { type: 'text/html' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = res.filename;
    a.click();
    URL.revokeObjectURL(url);
    showToast(`Exported ${res.filename}`);
  };

  if (!doc) return <div style={{ padding: '32px' }}>Loading Easel…</div>;

  const swatches = PALETTES[doc.palette];

  return (
    <div class="easel-shell">
      <header class="easel-topbar">
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
          <OpenDoorwayMark size={24} />
          <input
            class="easel-title-input"
            aria-label="Easel title"
            value={doc.title}
            onInput={(e) => {
              const next = { ...doc, title: (e.currentTarget as HTMLInputElement).value };
              setDoc(next);
              scheduleSave(next);
            }}
          />
          <Badge tone={saveState === 'saved' ? 'success' : 'accent'}>
            {saveState === 'saved' ? 'Saved' : 'Saving…'}
          </Badge>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <button type="button" class="open-btn" disabled={undoStack.length === 0} aria-label="Undo" onClick={handleUndo}>
            <UndoIcon />
          </button>
          <button type="button" class="open-btn" disabled={redoStack.length === 0} aria-label="Redo" onClick={handleRedo}>
            <RedoIcon />
          </button>
          <div style={{ display: 'flex', alignItems: 'center', gap: '4px', marginLeft: '6px' }}>
            <button
              type="button"
              class="open-btn"
              onClick={() => setZoom((z) => Math.max(MIN_ZOOM, Number((z - 0.15).toFixed(2))))}
            >
              −
            </button>
            <button type="button" class="open-btn" style={{ minWidth: '58px' }} onClick={() => setZoom(1)}>
              {Math.round(zoom * 100)}%
            </button>
            <button
              type="button"
              class="open-btn"
              onClick={() => setZoom((z) => Math.min(MAX_ZOOM, Number((z + 0.15).toFixed(2))))}
            >
              +
            </button>
          </div>
          <button type="button" class="open-btn open-btn-primary" onClick={() => void handleExportHtml()}>
            <DownloadIcon size={13} /> Export HTML
          </button>
        </div>
      </header>

      <div class="easel-workspace">
        <div class="easel-viewport">
          <div class="easel-canvas-outer" style={{ transform: `scale(${zoom})` }}>
            <div
              ref={canvasRef}
              class="easel-canvas"
              style={{
                width: `${doc.canvas_width}px`,
                height: `${doc.canvas_height}px`,
                cursor: tool === 'pointer' ? 'default' : 'crosshair',
              }}
              onPointerDown={handleCanvasPointerDown}
            >
              {/* Live SVG Freehand Stroke Preview */}
              {drawingFreehand && drawingFreehand.points.length > 1 && (
                <svg class="easel-svg-layer">
                  <polyline
                    fill="none"
                    stroke={activeColor}
                    stroke-width="3"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    points={drawingFreehand.points.map(([px, py]) => `${px},${py}`).join(' ')}
                  />
                </svg>
              )}

              {doc.elements
                .slice()
                .sort((a, b) => a.z_index - b.z_index)
                .map((el) => {
                  const isSelected = el.id === selectedId;
                  return (
                    <div
                      key={el.id}
                      class={`easel-element${isSelected ? ' is-selected' : ''}`}
                      style={{
                        left: `${el.x}px`,
                        top: `${el.y}px`,
                        width: `${el.width}px`,
                        height: `${el.height}px`,
                        zIndex: el.z_index,
                      }}
                      onPointerDown={(e) => {
                        e.stopPropagation();
                        setSelectedId(el.id);
                        setUndoStack((prev) => [...prev.slice(-39), doc.elements.map((x) => ({ ...x }))]);
                        dragRef.current = {
                          kind: 'move',
                          elementId: el.id,
                          startClientX: e.clientX,
                          startClientY: e.clientY,
                          origX: el.x,
                          origY: el.y,
                          origW: el.width,
                          origH: el.height,
                        };
                      }}
                    >
                      {el.type === 'rect' && (
                        <div
                          style={{
                            width: '100%',
                            height: '100%',
                            borderRadius: '12px',
                            background: el.fill_color,
                            border: `${el.stroke_width}px solid ${el.stroke_color}`,
                            color: '#ffffff',
                            padding: '12px',
                            fontSize: `${el.font_size}px`,
                            fontWeight: 600,
                            whiteSpace: 'pre-wrap',
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            textAlign: 'center',
                          }}
                        >
                          {el.content}
                        </div>
                      )}

                      {el.type === 'ellipse' && (
                        <div
                          style={{
                            width: '100%',
                            height: '100%',
                            borderRadius: '50%',
                            background: el.fill_color,
                            border: `${el.stroke_width}px solid ${el.stroke_color}`,
                            color: '#ffffff',
                            padding: '14px',
                            fontSize: `${el.font_size}px`,
                            fontWeight: 600,
                            whiteSpace: 'pre-wrap',
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            textAlign: 'center',
                          }}
                        >
                          {el.content}
                        </div>
                      )}

                      {el.type === 'text' && (
                        <div
                          style={{
                            width: '100%',
                            height: '100%',
                            fontSize: `${el.font_size}px`,
                            fontWeight: 700,
                            color: 'var(--text-primary)',
                            padding: '4px 6px',
                            whiteSpace: 'pre-wrap',
                          }}
                        >
                          {el.content}
                        </div>
                      )}

                      {el.type === 'arrow' && (
                        <svg width="100%" height="100%" viewBox={`0 0 ${el.width} ${el.height}`} preserveAspectRatio="none">
                          <line
                            x1="4"
                            y1={el.height / 2}
                            x2={Math.max(12, el.width - 12)}
                            y2={el.height / 2}
                            stroke={el.stroke_color}
                            stroke-width={el.stroke_width}
                            stroke-linecap="round"
                          />
                          <polyline
                            points={`${el.width - 14},${Math.max(2, el.height / 2 - 7)} ${el.width - 4},${el.height / 2} ${el.width - 14},${Math.min(el.height - 2, el.height / 2 + 7)}`}
                            fill="none"
                            stroke={el.stroke_color}
                            stroke-width={el.stroke_width}
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          />
                        </svg>
                      )}

                      {el.type === 'freehand' && (
                        <svg width="100%" height="100%" viewBox={`0 0 ${el.width} ${el.height}`}>
                          <path
                            d={el.content}
                            fill="none"
                            stroke={el.stroke_color}
                            stroke-width={el.stroke_width}
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          />
                        </svg>
                      )}

                      {el.type === 'image' && (
                        <div
                          style={{
                            width: '100%',
                            height: '100%',
                            borderRadius: '12px',
                            background: `linear-gradient(135deg, ${el.fill_color}, #1d1d27)`,
                            border: `1px solid ${el.stroke_color}`,
                            color: '#ffffff',
                            padding: '12px',
                            display: 'flex',
                            flexDirection: 'column',
                            justifyContent: 'flex-end',
                            fontWeight: 600,
                          }}
                        >
                          🖼️ {el.content}
                        </div>
                      )}

                      {el.type === 'live_card' && (
                        <div
                          style={{
                            width: '100%',
                            height: '100%',
                            borderRadius: '12px',
                            background: 'var(--bg-canvas)',
                            border: `1px solid ${el.stroke_color}`,
                            overflow: 'hidden',
                            display: 'flex',
                            flexDirection: 'column',
                          }}
                        >
                          <div
                            style={{
                              padding: '7px 10px',
                              background: 'var(--bg-sidebar)',
                              borderBottom: '1px solid var(--border-subtle)',
                              display: 'flex',
                              justifyContent: 'space-between',
                              alignItems: 'center',
                              fontSize: '11px',
                            }}
                          >
                            <span style={{ fontFamily: 'var(--font-mono)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                              {el.content}
                            </span>
                            <Badge tone="success">LIVE</Badge>
                          </div>
                          <div style={{ flex: 1, padding: '14px', fontSize: '12px', color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', justifyContent: 'center', textAlign: 'center' }}>
                            Live Web Card snapshot · refreshes automatically when Easel is visible
                          </div>
                        </div>
                      )}

                      {isSelected && (
                        <div
                          class="easel-resize-handle"
                          onPointerDown={(e) => {
                            e.stopPropagation();
                            dragRef.current = {
                              kind: 'resize',
                              elementId: el.id,
                              startClientX: e.clientX,
                              startClientY: e.clientY,
                              origX: el.x,
                              origY: el.y,
                              origW: el.width,
                              origH: el.height,
                            };
                          }}
                        />
                      )}
                    </div>
                  );
                })}
            </div>
          </div>
        </div>

        <aside class="easel-inspector">
          <div>
            <div style={{ fontSize: '11px', fontWeight: 600, textTransform: 'uppercase', color: 'var(--text-tertiary)', marginBottom: '8px' }}>
              Color Palette
            </div>
            <SegmentedControl<'vibrant' | 'chill'>
              ariaLabel="Easel palette"
              value={doc.palette}
              options={[
                { value: 'vibrant', label: 'Vibrant' },
                { value: 'chill', label: 'Chill' },
              ]}
              onChange={(palette) => {
                const next = { ...doc, palette };
                setDoc(next);
                setActiveColor(PALETTES[palette][0]!);
                scheduleSave(next);
              }}
            />
            <div class="palette-swatches" style={{ marginTop: '10px' }}>
              {swatches.map((hex) => (
                <button
                  key={hex}
                  type="button"
                  class={`palette-swatch${activeColor === hex ? ' is-active' : ''}`}
                  style={{ background: hex }}
                  aria-label={`Color ${hex}`}
                  onClick={() => {
                    setActiveColor(hex);
                    if (selectedEl) {
                      updateSelected({
                        fill_color: selectedEl.type === 'text' || selectedEl.type === 'arrow' || selectedEl.type === 'freehand' ? 'transparent' : hex,
                        stroke_color: hex,
                      });
                    }
                  }}
                />
              ))}
            </div>
          </div>

          {selectedEl ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '10px', borderTop: '1px solid var(--border-subtle)', paddingTop: '12px' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <strong style={{ textTransform: 'capitalize' }}>{selectedEl.type.replace('_', ' ')}</strong>
                <button
                  type="button"
                  class="open-btn open-btn-danger"
                  onClick={() => {
                    commitElements(doc.elements.filter((x) => x.id !== selectedEl.id));
                    setSelectedId(null);
                  }}
                >
                  <TrashIcon size={12} />
                </button>
              </div>
              {selectedEl.type !== 'arrow' && selectedEl.type !== 'freehand' && (
                <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                  <span>{selectedEl.type === 'live_card' ? 'URL' : 'Content'}</span>
                  <textarea
                    class="open-textarea"
                    rows={3}
                    value={selectedEl.content}
                    onInput={(e) => updateSelected({ content: (e.currentTarget as HTMLTextAreaElement).value })}
                  />
                </label>
              )}
              <label style={{ display: 'flex', flexDirection: 'column', gap: '4px', fontSize: '11.5px', color: 'var(--text-secondary)' }}>
                <span>Font size ({selectedEl.font_size}px)</span>
                <input
                  type="range"
                  min="11"
                  max="48"
                  value={selectedEl.font_size}
                  onInput={(e) => updateSelected({ font_size: Number((e.currentTarget as HTMLInputElement).value) })}
                />
              </label>
              <div style={{ fontSize: '11px', color: 'var(--text-tertiary)', fontFamily: 'var(--font-mono)' }}>
                x:{selectedEl.x} y:{selectedEl.y} · {selectedEl.width}×{selectedEl.height}pt
              </div>
            </div>
          ) : (
            <div style={{ fontSize: '12px', color: 'var(--text-secondary)', borderTop: '1px solid var(--border-subtle)', paddingTop: '12px' }}>
              Pick a tool from the bottom bar and click the 1000pt canvas to place objects, or click an existing object to move and resize it.
            </div>
          )}
        </aside>
      </div>

      <div class="easel-bottom-toolbar" role="toolbar" aria-label="Easel tools">
        {TOOLS.map((t) => (
          <button
            key={t.id}
            type="button"
            class={`easel-tool-btn${tool === t.id ? ' is-active' : ''}`}
            onClick={() => setTool(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>

      <Toast message={toast} />
    </div>
  );
}
