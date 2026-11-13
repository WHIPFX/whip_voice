// LCD for the radio: an old-school segment display drawn on a 2D canvas (used as the screen texture).
// Pure canvas 2D, no three.js. drawLCD(canvas, view) paints one frame from a plain view object (see RadioUI.#lcdView).

const SEG = {}; // 14-segment glyph table: a b c d e f g1 g2 h i j k l m
const g = (c, s) => { SEG[c] = s.split(' ').filter(Boolean); };
g('0', 'a b c d e f j k'); g('1', 'b c j'); g('2', 'a b g1 g2 e d'); g('3', 'a b c d g2'); g('4', 'f g1 g2 b c');
g('5', 'a f g1 g2 c d'); g('6', 'a f e d c g1 g2'); g('7', 'a b c'); g('8', 'a b c d e f g1 g2'); g('9', 'a b c d f g1 g2');
g('A', 'a b c e f g1 g2'); g('B', 'a b c d i l g2'); g('C', 'a d e f'); g('D', 'a b c d i l'); g('E', 'a d e f g1');
g('F', 'a e f g1'); g('G', 'a c d e f g2'); g('H', 'b c e f g1 g2'); g('I', 'a d i l'); g('J', 'b c d e');
g('K', 'e f g1 j m'); g('L', 'd e f'); g('M', 'b c e f h j'); g('N', 'b c e f h m'); g('O', 'a b c d e f');
g('P', 'a b e f g1 g2'); g('Q', 'a b c d e f m'); g('R', 'a b e f g1 g2 m'); g('S', 'a f g1 g2 c d'); g('T', 'a i l');
g('U', 'b c d e f'); g('V', 'e f k j'); g('W', 'b c e f k m'); g('X', 'h j k m'); g('Y', 'h j l'); g('Z', 'a d j k');
g('-', 'g1 g2'); g('_', 'd'); g(' ', ''); g('/', 'j k'); g('+', 'g1 g2 i l'); g('*', 'g1 g2 h i j k l m'); g("'", 'i');
const ALL = 'a b c d e f g1 g2 h i j k l m'.split(' ');

function segPolys(w, h, t) {
  // polygons for each segment in a cell w x h with stroke t (y down); slanted later by the caller
  const q = t * 0.5, gp = t * 0.35, mx = w / 2, my = h / 2;
  const hz = (x0, x1, y) => [[x0 + gp, y], [x0 + q + gp, y - q], [x1 - q - gp, y - q], [x1 - gp, y], [x1 - q - gp, y + q], [x0 + q + gp, y + q]];
  const vt = (x, y0, y1) => [[x, y0 + gp], [x + q, y0 + q + gp], [x + q, y1 - q - gp], [x, y1 - gp], [x - q, y1 - q - gp], [x - q, y0 + q + gp]];
  const dg = (x0, y0, x1, y1) => { const k = t * 0.42; return [[x0 + k, y0 + k * 1.6], [x0 + k * 2.2, y0 + k], [x1 - k, y1 - k * 1.6], [x1 - k * 2.2, y1 - k]]; };
  const dg2 = (x0, y0, x1, y1) => { const k = t * 0.42; return [[x0 - k, y0 + k * 1.6], [x0 - k * 2.2, y0 + k], [x1 + k, y1 - k * 1.6], [x1 + k * 2.2, y1 - k]]; };
  return {
    a: hz(q, w - q, q), d: hz(q, w - q, h - q), g1: hz(q, mx, my), g2: hz(mx, w - q, my),
    f: vt(q, q, my), b: vt(w - q, q, my), e: vt(q, my, h - q), c: vt(w - q, my, h - q),
    i: vt(mx, q, my), l: vt(mx, my, h - q),
    h: dg(q, q, mx, my), m: dg(mx, my, w - q, h - q), j: dg2(w - q, q, mx, my), k: dg2(mx, my, q, h - q),
  };
}

function fillPoly(ctx, pts, ox, oy, slant, h) {
  ctx.beginPath();
  pts.forEach(([x, y], n) => { const X = ox + x + (h - y) * slant, Y = oy + y; n ? ctx.lineTo(X, Y) : ctx.moveTo(X, Y); });
  ctx.closePath(); ctx.fill();
}

// Draw a string of 14-segment characters. Every cell shows its unlit "ghost" segments, then the lit ones.
export function segText(ctx, text, x, y, cw, ch, opt) {
  const { ink, ghost, gap = cw * 0.22, t = cw * 0.16, slant = 0.1, dots = true } = opt;
  const polys = segPolys(cw, ch, t);
  let cx = x;
  const chars = [...text.toUpperCase()];
  for (let n = 0; n < chars.length; n++) {
    const c = chars[n];
    if (c === '.' || c === ':') continue;
    if (ghost) { ctx.fillStyle = ghost; for (const s of ALL) fillPoly(ctx, polys[s], cx, y, slant, ch); }
    ctx.fillStyle = ink;
    for (const s of SEG[c] || SEG['-']) fillPoly(ctx, polys[s], cx, y, slant, ch);
    if (dots) {   // decimal point after the cell
      const lit = chars[n + 1] === '.';
      const r = t * 0.55;
      if (ghost || lit) { ctx.fillStyle = lit ? ink : ghost; ctx.beginPath(); ctx.arc(cx + cw + gap * 0.5, y + ch - r, r, 0, Math.PI * 2); ctx.fill(); }
    }
    cx += cw + gap;
  }
  return cx;
}

export const segWidth = (n, cw, gap = cw * 0.22) => n * cw + Math.max(0, n - 1) * gap;

const PAL = {
  on:    { bg0: '#bcd85a', bg1: '#93ad3c', ink: 'rgba(24,34,10,0.93)', ghost: 'rgba(24,34,10,0.075)', glow: 1 },
  boost: { bg0: '#d2ef72', bg1: '#a8c64a', ink: 'rgba(22,32,8,0.95)', ghost: 'rgba(22,32,8,0.07)', glow: 1.35 },
  off:   { bg0: '#4a5236', bg1: '#3a4129', ink: 'rgba(0,0,0,0)', ghost: 'rgba(14,18,8,0.13)', glow: 0 },
};

function smallLabel(ctx, txt, x, y, on, pal, size = 22, boxed = false) {
  ctx.font = `700 ${size}px "Arial Narrow", Arial, sans-serif`; ctx.textBaseline = 'middle';
  const w = ctx.measureText(txt).width;
  if (boxed) {                       // inverse pill: dark box with the label cut out; unlit = faint box
    ctx.fillStyle = on ? pal.ink : pal.ghost; ctx.fillRect(x - 5, y - size * 0.62, w + 10, size * 1.24);
    if (on) { ctx.fillStyle = pal.bg0; ctx.fillText(txt, x, y + 1); }
  } else { ctx.fillStyle = on ? pal.ink : pal.ghost; ctx.fillText(txt, x, y + 1); }
  return w;
}

function bars(ctx, x, y, n, lit, pal, bw, maxH, step = 1.0) {
  for (let i = 0; i < n; i++) {
    const h = maxH * (0.35 + 0.65 * (i + 1) / n) * step;
    ctx.fillStyle = i < lit ? pal.ink : pal.ghost; ctx.fillRect(x + i * (bw + 4), y - h, bw, h);
  }
}

function battery(ctx, x, y, level, pal) {
  ctx.strokeStyle = level >= 0 ? pal.ink : pal.ghost; ctx.lineWidth = 3;
  ctx.strokeRect(x, y - 13, 46, 26); ctx.fillStyle = ctx.strokeStyle; ctx.fillRect(x + 46, y - 6, 4, 12);
  for (let i = 0; i < 4; i++) { ctx.fillStyle = i < level ? pal.ink : pal.ghost; ctx.fillRect(x + 4 + i * 10.5, y - 9, 8, 18); }
}

// view: { mode: 'off'|'boot'|'splash'|'main', boost, big, sub, subKind, tx, rx, scan, signal, battery, vol, blink, spk }
export function drawLCD(canvas, v) {
  const ctx = canvas.getContext('2d'); const W = canvas.width, H = canvas.height;
  const pal = v.mode === 'off' ? PAL.off : (v.boost ? PAL.boost : PAL.on);
  const gr = ctx.createRadialGradient(W * 0.5, H * 0.45, H * 0.1, W * 0.5, H * 0.5, W * 0.62);
  gr.addColorStop(0, pal.bg0); gr.addColorStop(1, pal.bg1);
  ctx.fillStyle = gr; ctx.fillRect(0, 0, W, H);
  const all = v.mode === 'boot';
  const P = all ? { ...pal, ghost: pal.ink } : pal;           // boot test: every segment lit
  const on = (flag) => all || (v.mode === 'main' && flag);
  // status row
  const sy = 30;
  bars(ctx, 22, sy + 14, 4, all ? 4 : (v.mode === 'main' ? v.signal : 0), P, 9, 26);
  smallLabel(ctx, 'TX', 92, sy, on(v.tx && v.blink !== false), P, 22, true);
  smallLabel(ctx, 'RX', 142, sy, on(v.rx), P, 22, true);
  smallLabel(ctx, 'SCAN', 196, sy, on(v.scan), P, 20);
  smallLabel(ctx, 'SPK', 266, sy, on(v.spk), P, 20);                // loudspeaker on: nearby players hear it
  smallLabel(ctx, 'LIGHT', 324, sy, on(v.boost), P, 20);
  battery(ctx, W - 72, sy, all ? 4 : (v.mode === 'main' ? v.battery : -1), P);
  // main line: up to 6 big segment characters
  const mainTxt = all ? '888888' : (v.mode === 'splash' ? v.big : (v.mode === 'main' ? v.big : ''));
  const cw = 54, ch = 104, gap = 15, slots = 6;
  const tw = segWidth(slots, cw, gap); let x0 = (W - tw) / 2 - 4;
  const txt = (mainTxt || '').replace(/\./g, '').slice(0, slots);
  const pad = Math.max(0, Math.floor((slots - txt.length) / 2));
  const cells = (' '.repeat(pad) + txt).padEnd(slots, ' ').slice(0, slots);     // exactly `slots` cells, centred
  segText(ctx, cells, x0, 62, cw, ch, { ink: P.ink, ghost: P.ghost, gap, t: 10, dots: false });
  // sub line: frequency / volume bar / entry
  const yb = 200;
  if (all) {
    segText(ctx, '888.8888', 120, yb - 22, 22, 44, { ink: P.ink, ghost: P.ghost, gap: 6, t: 4.4 });
    bars(ctx, 26, yb + 20, 10, 10, P, 6, 32, 0.9);
  } else if (v.mode === 'main' && v.subKind === 'vol') {
    smallLabel(ctx, 'VOL', 22, yb, true, P, 24);
    for (let i = 0; i < 10; i++) { ctx.fillStyle = i < v.vol ? P.ink : P.ghost; ctx.fillRect(84 + i * 38, yb - 13, 30, 26); }
  } else if (v.mode === 'main' && v.sub) {
    const s = v.sub; const subW = segWidth([...s.replace(/\./g, '')].length, 22, 6);
    const end = segText(ctx, s, (W - subW) / 2 - 30, yb - 22, 22, 44, { ink: P.ink, ghost: P.ghost, gap: 6, t: 4.4 });
    if (v.subKind === 'freq') smallLabel(ctx, 'MHz', end + 6, yb + 4, true, P, 20);
  } else {
    segText(ctx, '        ', 120, yb - 22, 22, 44, { ink: P.ink, ghost: P.ghost, gap: 6, t: 4.4 });
  }
  // LCD pixel texture
  ctx.fillStyle = 'rgba(0,0,0,0.035)';
  for (let y = 0; y < H; y += 4) ctx.fillRect(0, y, W, 1);
  for (let x = 0; x < W; x += 4) ctx.fillRect(x, 0, 1, H);
  return pal.glow;
}
