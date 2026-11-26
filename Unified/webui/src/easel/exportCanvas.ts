// Client-side 2x Retina PNG rasterizer for Easel export.

import { FONT_FAMILY_CSS, type EaselItem, type RichEaselDocument } from './types';

function loadImg(src: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = src;
  });
}

function drawRoundedRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  const rad = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + rad, y);
  ctx.lineTo(x + w - rad, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + rad);
  ctx.lineTo(x + w, y + h - rad);
  ctx.quadraticCurveTo(x + w, y + h, x + w - rad, y + h);
  ctx.lineTo(x + rad, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - rad);
  ctx.lineTo(x, y + rad);
  ctx.quadraticCurveTo(x, y, x + rad, y);
  ctx.closePath();
}

function drawWrappedText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  maxWidth: number,
  lineHeight: number,
  align: CanvasTextAlign,
): void {
  ctx.textAlign = align;
  const anchorX = align === 'center' ? x + maxWidth / 2 : align === 'right' ? x + maxWidth : x;
  let curY = y;
  for (const rawLine of text.split('\n')) {
    const words = rawLine.split(' ');
    let line = '';
    for (const word of words) {
      const candidate = line ? `${line} ${word}` : word;
      if (ctx.measureText(candidate).width > maxWidth && line) {
        ctx.fillText(line, anchorX, curY);
        line = word;
        curY += lineHeight;
      } else {
        line = candidate;
      }
    }
    ctx.fillText(line, anchorX, curY);
    curY += lineHeight;
  }
}

export async function renderEaselToPngDataUrl(
  doc: RichEaselDocument,
  resolvedSrcs: Record<string, string>,
  isDark: boolean,
): Promise<string> {
  const pad = 48;
  let minX = 0;
  let minY = 0;
  let maxX = doc.canvas_width || 1000;
  let maxY = 800;

  if (doc.elements.length > 0) {
    minX = Math.min(...doc.elements.map((e) => e.x)) - pad;
    minY = Math.min(...doc.elements.map((e) => e.y)) - pad;
    maxX = Math.max(...doc.elements.map((e) => e.x + e.width)) + pad;
    maxY = Math.max(...doc.elements.map((e) => e.y + e.height)) + pad;
  }

  const width = Math.max(400, Math.min(4096, Math.ceil(maxX - minX)));
  const height = Math.max(300, Math.min(4096, Math.ceil(maxY - minY)));
  const scale = width * height > 2400 * 2400 ? 1 : 2;

  const canvas = document.createElement('canvas');
  canvas.width = width * scale;
  canvas.height = height * scale;
  const ctx = canvas.getContext('2d');
  if (!ctx) return '';

  ctx.scale(scale, scale);
  ctx.fillStyle = isDark ? '#19121C' : '#FDFCFD';
  ctx.fillRect(0, 0, width, height);

  ctx.save();
  ctx.translate(-minX, -minY);

  const sorted: EaselItem[] = doc.elements.slice().sort((a, b) => a.z_index - b.z_index);

  for (const el of sorted) {
    ctx.save();
    ctx.globalAlpha = el.opacity ?? 1;
    const cx = el.x + el.width / 2;
    const cy = el.y + el.height / 2;
    if (el.rotation) {
      ctx.translate(cx, cy);
      ctx.rotate((el.rotation * Math.PI) / 180);
      ctx.translate(-cx, -cy);
    }

    if (el.type === 'sticky') {
      ctx.shadowColor = 'rgba(0,0,0,0.14)';
      ctx.shadowBlur = 16;
      ctx.shadowOffsetY = 6;
      drawRoundedRect(ctx, el.x, el.y, el.width, el.height, 10);
      ctx.fillStyle = el.fill_color || '#FFF3B0';
      ctx.fill();
      ctx.shadowColor = 'transparent';
      if (el.stroke_color && el.stroke_color !== 'transparent') {
        ctx.strokeStyle = el.stroke_color;
        ctx.lineWidth = 1;
        ctx.stroke();
      }
      ctx.fillStyle = '#1D1B16';
      ctx.font = `500 ${el.font_size || 15}px ${FONT_FAMILY_CSS.clean}`;
      ctx.textBaseline = 'top';
      drawWrappedText(ctx, el.content || '', el.x + 14, el.y + 14, el.width - 28, (el.font_size || 15) * 1.4, 'left');
    } else if (el.type === 'rect' || el.type === 'frame') {
      drawRoundedRect(ctx, el.x, el.y, el.width, el.height, el.type === 'frame' ? 14 : 12);
      if (el.fill_color && el.fill_color !== 'transparent') {
        ctx.fillStyle = el.fill_color;
        ctx.fill();
      }
      if (el.stroke_color && el.stroke_color !== 'transparent') {
        ctx.strokeStyle = el.stroke_color;
        ctx.lineWidth = el.stroke_width || 2;
        if (el.type === 'frame') ctx.setLineDash([7, 5]);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      if (el.content) {
        ctx.fillStyle = el.type === 'frame' ? (isDark ? '#E5E7F0' : '#3C3E52') : '#FFFFFF';
        ctx.font = `600 ${el.font_size || 14}px ${FONT_FAMILY_CSS.clean}`;
        ctx.textBaseline = 'top';
        drawWrappedText(
          ctx,
          el.content,
          el.x + 12,
          el.type === 'frame' ? el.y + 10 : el.y + el.height / 2 - (el.font_size || 14) * 0.6,
          el.width - 24,
          (el.font_size || 14) * 1.35,
          el.type === 'frame' ? 'left' : 'center',
        );
      }
    } else if (el.type === 'ellipse') {
      ctx.beginPath();
      ctx.ellipse(cx, cy, Math.max(1, el.width / 2), Math.max(1, el.height / 2), 0, 0, Math.PI * 2);
      if (el.fill_color && el.fill_color !== 'transparent') {
        ctx.fillStyle = el.fill_color;
        ctx.fill();
      }
      if (el.stroke_color && el.stroke_color !== 'transparent') {
        ctx.strokeStyle = el.stroke_color;
        ctx.lineWidth = el.stroke_width || 2;
        ctx.stroke();
      }
      if (el.content) {
        ctx.fillStyle = '#FFFFFF';
        ctx.font = `600 ${el.font_size || 15}px ${FONT_FAMILY_CSS.clean}`;
        ctx.textBaseline = 'middle';
        drawWrappedText(ctx, el.content, el.x + 14, cy, el.width - 28, (el.font_size || 15) * 1.3, 'center');
      }
    } else if (el.type === 'text') {
      const fam = FONT_FAMILY_CSS[el.font_family ?? 'clean'];
      const weight = el.font_weight === 'bold' ? '700' : '500';
      const style = el.font_style === 'italic' ? 'italic ' : '';
      ctx.font = `${style}${weight} ${el.font_size || 20}px ${fam}`;
      ctx.fillStyle = el.text_color || (isDark ? '#F2F3F8' : '#14151F');
      ctx.textBaseline = 'top';
      drawWrappedText(
        ctx,
        el.content || '',
        el.x + 6,
        el.y + 6,
        Math.max(20, el.width - 12),
        (el.font_size || 20) * 1.35,
        el.text_align ?? 'left',
      );
    } else if (el.type === 'line' || el.type === 'arrow') {
      const x1 = el.x + (el.start_x ?? 6);
      const y1 = el.y + (el.start_y ?? el.height / 2);
      const x2 = el.x + (el.end_x ?? el.width - 6);
      const y2 = el.y + (el.end_y ?? el.height / 2);
      ctx.strokeStyle = el.stroke_color || '#3139FB';
      ctx.lineWidth = el.stroke_width || 3;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
      if (el.type === 'arrow') {
        const ang = Math.atan2(y2 - y1, x2 - x1);
        const head = Math.max(10, (el.stroke_width || 3) * 3.5);
        ctx.beginPath();
        ctx.moveTo(x2 - head * Math.cos(ang - 0.45), y2 - head * Math.sin(ang - 0.45));
        ctx.lineTo(x2, y2);
        ctx.lineTo(x2 - head * Math.cos(ang + 0.45), y2 - head * Math.sin(ang + 0.45));
        ctx.stroke();
      }
    } else if (el.type === 'freehand' && el.content) {
      ctx.save();
      ctx.translate(el.x, el.y);
      ctx.strokeStyle = el.stroke_color || '#3139FB';
      ctx.lineWidth = el.stroke_width || 3;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      const path = new Path2D(el.content);
      ctx.stroke(path);
      ctx.restore();
    } else if (el.type === 'image') {
      const src = resolvedSrcs[el.id] || el.data_url || el.image_url || '';
      drawRoundedRect(ctx, el.x, el.y, el.width, el.height, 10);
      ctx.save();
      ctx.clip();
      const img = src ? await loadImg(src) : null;
      if (img) {
        ctx.drawImage(img, el.x, el.y, el.width, el.height);
      } else {
        ctx.fillStyle = isDark ? '#252536' : '#ECECF3';
        ctx.fillRect(el.x, el.y, el.width, el.height);
      }
      ctx.restore();
    } else if (el.type === 'live_card') {
      drawRoundedRect(ctx, el.x, el.y, el.width, el.height, 12);
      ctx.fillStyle = isDark ? '#201B28' : '#FFFFFF';
      ctx.fill();
      ctx.strokeStyle = isDark ? 'rgba(255,255,255,0.14)' : 'rgba(20,22,36,0.12)';
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.save();
      ctx.clip();
      ctx.fillStyle = isDark ? '#18141F' : '#F3F3F8';
      ctx.fillRect(el.x, el.y, el.width, 32);
      ctx.fillStyle = isDark ? '#E8E9F4' : '#242636';
      ctx.font = `600 11px ${FONT_FAMILY_CSS.mono}`;
      ctx.textBaseline = 'middle';
      ctx.textAlign = 'left';
      ctx.fillText((el.live_title || el.live_url || el.content || '').slice(0, 46), el.x + 10, el.y + 16);
      const src = resolvedSrcs[el.id] || el.data_url || el.image_url || '';
      const img = src ? await loadImg(src) : null;
      if (img) {
        ctx.drawImage(img, el.x, el.y + 32, el.width, el.height - 32);
      }
      ctx.restore();
    }

    ctx.restore();
  }

  ctx.restore();
  return canvas.toDataURL('image/png');
}
