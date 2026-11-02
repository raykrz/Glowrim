'use strict';
// The rim itself: a click-through, transparent page that covers one display.
// This is a port of the macOS app's GlowView + OverlayController to canvas.

const params = new URLSearchParams(location.search);
const TEST = params.has('test');   // deterministic stepping, driven from test/render-test.js
const DEMO = params.has('demo');   // fake beat and screen colors, for trying it without capture
if (params.has('bg')) document.body.classList.add('testbg');

const coreCanvas = document.getElementById('core');
const bloomCanvas = document.getElementById('bloom');
const core = coreCanvas.getContext('2d');
const bloom = bloomCanvas.getContext('2d');

let S = {
  enabled: true, mode: 'music', style: 'screen', primary: '#FF4FA3', secondary: '#4F7BFF',
  thickness: 8, glow: 0.6, cometCount: 2, wavy: true,
};

// ---------- helpers
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const hexRgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const css = (c, a = 1) => `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${a})`;
const WHITE = [255, 255, 255];

// ---------- the edge as a polyline with inward normals (port of EdgeContour.swift)
let contour = null;
const STEP = 14;

function buildContour(w, h, radius) {
  const r = Math.max(0, Math.min(radius, Math.min(w, h) / 4));
  const pts = [];
  const line = (x0, y0, x1, y1) => {
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / STEP));
    for (let i = 0; i < n; i++) pts.push([x0 + (x1 - x0) * (i / n), y0 + (y1 - y0) * (i / n)]);
  };
  const arc = (cx, cy, a0, a1) => {
    const n = Math.max(2, Math.ceil((Math.abs(a1 - a0) * r) / STEP));
    for (let i = 0; i < n; i++) {
      const a = a0 + ((a1 - a0) * i) / n;
      pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
  };
  // Clockwise on screen (y down), so the inside is to the right of travel.
  line(r, 0, w - r, 0); if (r > 0) arc(w - r, r, -Math.PI / 2, 0);
  line(w, r, w, h - r); if (r > 0) arc(w - r, h - r, 0, Math.PI / 2);
  line(w - r, h, r, h); if (r > 0) arc(r, h - r, Math.PI / 2, Math.PI);
  line(0, h - r, 0, r); if (r > 0) arc(r, r, Math.PI, 1.5 * Math.PI);

  const n = pts.length;
  const normals = pts.map((_, i) => {
    const a = pts[(i + n - 1) % n], b = pts[(i + 1) % n];
    const tx = b[0] - a[0], ty = b[1] - a[1];
    const len = Math.max(Math.hypot(tx, ty), 1e-4);
    return [-ty / len, tx / len];
  });

  const s = [0];
  for (let i = 1; i < n; i++) s.push(s[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]));
  const total = s[n - 1] + Math.hypot(pts[0][0] - pts[n - 1][0], pts[0][1] - pts[n - 1][1]);
  let src = 0, best = Infinity;
  pts.forEach((p, i) => {
    const d = Math.hypot(p[0] - w / 2, p[1] - h);
    if (d < best) { best = d; src = i; }
  });
  const dist = s.map((v) => { const d = Math.abs(v - s[src]); return Math.min(d, total - d); });
  return { pts, normals, dist };
}

// ---------- engine state (port of OverlayController)
const st = {
  phase: 0, level: 0, lastLevel: 0, punch: 0, speed: 0, angle: 0, master: 0,
  idle: 0, silentTime: 0, dirtyTime: 1.5,
  curP: hexRgb('#FF4FA3'), curS: hexRgb('#4F7BFF'),
  thickness: 8, glow: 0.6, waveGain: 0,
  shownRing: null, hist: new Array(240).fill(0.1), frame: 0,
};
let inLevel = 0;      // beat level from the capture window (0...1)
let inRing = null;    // raw edge colors for this display (movie mode)
let paused = false;
let W = 0, H = 0, DPR = 1, bloomK = 4, bloomPad = 0;
let fadingOut = false;

function resize() {
  W = window.innerWidth; H = window.innerHeight; DPR = window.devicePixelRatio || 1;
  coreCanvas.width = Math.round(W * DPR); coreCanvas.height = Math.round(H * DPR);
  coreCanvas.style.width = `${W}px`; coreCanvas.style.height = `${H}px`;
  layoutBloom();
  contour = buildContour(W, H, 0);
  st.dirtyTime = 1.5;
}

function bloomGeometry() {
  const border = S.style === 'border';
  const glow = st.glow, thick = st.thickness;
  return {
    border,
    reach: border ? thick * 1.8 + 4 + 14 * glow : thick + 20 + 160 * glow,
    radius: border ? 4 + thick * 0.6 + 10 * glow : 20 + 70 * glow,
  };
}

function layoutBloom() {
  bloomK = S.style === 'border' ? 2 : 4;
  // Padding keeps the blur from fading at the canvas edge, where the light is brightest.
  const g = bloomGeometry();
  bloomPad = Math.ceil((g.radius / bloomK) * 3) + 2;
  bloomCanvas.width = Math.ceil(W / bloomK) + 2 * bloomPad;
  bloomCanvas.height = Math.ceil(H / bloomK) + 2 * bloomPad;
  bloomCanvas.style.width = `${bloomCanvas.width * bloomK}px`;
  bloomCanvas.style.height = `${bloomCanvas.height * bloomK}px`;
  bloomCanvas.style.left = `${-bloomPad * bloomK}px`;
  bloomCanvas.style.top = `${-bloomPad * bloomK}px`;
}

// ---------- pacing
function wantedColors() { return [hexRgb(S.primary), hexRgb(S.secondary)]; }

function colorDistance(a, b) { return Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2])) / 255; }

function isStatic() {
  if (S.mode !== 'steady' || S.wavy || fadingOut || st.dirtyTime > 0) return false;
  const [p, s] = wantedColors();
  return st.master > 0.999 && Math.abs(st.level - 0.75) < 0.002 && st.speed < 0.002 && st.punch < 0.005
    && colorDistance(st.curP, p) < 0.003 && colorDistance(st.curS, s) < 0.003
    && Math.abs(st.thickness - S.thickness) < 0.03 && Math.abs(st.glow - S.glow) < 0.003;
}

function desiredFps() {
  switch (S.mode) {
    case 'spinning': return 60;
    case 'music': return st.silentTime > 0.6 ? 30 : 60;
    case 'breathe': return 30;
    case 'movie': return 30;
    default: return S.wavy ? 30 : (isStatic() ? 6 : 60);
  }
}

// ---------- animation state
function update(dt) {
  const frames = dt * 60;
  const k = (p) => 1 - Math.pow(1 - p, frames); // per-frame smoothing (tuned at 60 fps) for this frame length
  st.phase += dt;
  st.dirtyTime = Math.max(0, st.dirtyTime - dt);

  // After a moment of silence the rim drifts into a slow breath instead of freezing flat.
  st.silentTime = inLevel < 0.03 ? st.silentTime + dt : 0;
  st.idle += ((st.silentTime > 1.5 ? 1 : 0) - st.idle) * k(0.03);
  const drift = st.idle * 0.16 * (0.5 + 0.5 * Math.sin((st.phase * 2 * Math.PI) / 4));

  let target;
  switch (S.mode) {
    case 'music': target = Math.max(inLevel, 0.12 + drift); break;
    case 'spinning': target = Math.max(inLevel, 0.26 + drift); break;
    case 'breathe': target = 0.3 + 0.5 * (0.5 + 0.5 * Math.sin((st.phase * 2 * Math.PI) / 5)); break;
    case 'movie': target = 0.8; break;
    default: target = 0.75;
  }
  st.level += (target - st.level) * k(target > st.level ? 0.55 : 0.12);

  // A sudden jump in level is a beat: kick the thickness and let it fall back smoothly.
  if ((S.mode === 'music' || S.mode === 'spinning') && st.level - st.lastLevel > 0.06) {
    st.punch = Math.max(st.punch, Math.min(1, (st.level - st.lastLevel) * 6));
  }
  st.lastLevel = st.level;
  st.punch *= Math.pow(0.86, frames);

  st.master += ((S.enabled && !fadingOut ? 1 : 0) - st.master) * k(0.07);

  const [wp, ws] = wantedColors();
  st.curP = mix(st.curP, wp, k(0.05));
  st.curS = mix(st.curS, ws, k(0.05));

  let targetSpeed;
  switch (S.mode) {
    case 'music': targetSpeed = 0.15 + 1.2 * st.level; break;
    case 'breathe': targetSpeed = 0.12; break;
    case 'spinning': targetSpeed = 0.9 + 3.2 * st.level; break; // comets race on the beat
    default: targetSpeed = 0;
  }
  st.speed += (targetSpeed - st.speed) * k(0.04); // spin up and wind down instead of snapping
  st.angle += st.speed * dt;

  st.thickness += (S.thickness - st.thickness) * k(0.18);
  st.glow += (S.glow - st.glow) * k(0.18);
  st.waveGain += ((S.wavy ? 1 : 0) - st.waveGain) * k(0.1);
  if (st.waveGain < 0.01) st.waveGain = 0;

  // Movie: ease each edge color toward the newest capture.
  if (S.mode === 'movie' && inRing) {
    if (!st.shownRing || st.shownRing.length !== inRing.length) st.shownRing = inRing.map((c) => c.slice());
    else {
      const f = k(0.22);
      for (let i = 0; i < inRing.length; i++) for (let c = 0; c < 3; c++) {
        st.shownRing[i][c] += (inRing[i][c] - st.shownRing[i][c]) * f;
      }
    }
    const avg = [0, 0, 0];
    for (const c of st.shownRing) { avg[0] += c[0]; avg[1] += c[1]; avg[2] += c[2]; }
    st.curP = avg.map((v) => v / st.shownRing.length);
    st.curS = st.curP;
  }
}

// ---------- drawing
function gradientStops(p, s, comet, ring) {
  if (ring) {
    const n = ring.length;
    return [...ring, ring[0]].map((c, i) => [i / n, css(c)]);
  }
  if (comet) {
    const head = mix(p, WHITE, 0.5);
    const n = Math.max(1, S.cometCount);
    const stops = [];
    for (let i = 0; i < n; i++) {
      // A sharp bright head with a long tail that fades out behind it.
      for (const [loc, col, a] of [[0, p, 0], [0.5, s, 0.35], [0.82, p, 0.8], [0.97, p, 1], [0.995, head, 1]]) {
        stops.push([(i + loc) / n, css(col, a)]);
      }
    }
    stops.push([1, css(p, 0)]);
    return stops;
  }
  return [[0, css(p)], [0.5, css(s)], [1, css(p)]];
}

function makeGradient(ctx, cx, cy, start, stops) {
  const g = ctx.createConicGradient(start, cx, cy);
  for (const [t, c] of stops) g.addColorStop(clamp(t, 0, 1), c);
  return g;
}

function tracePath(ctx, offsets, scale, ox = 0, oy = 0) {
  const { pts, normals } = contour;
  ctx.beginPath();
  for (let i = 0; i < pts.length; i++) {
    const o = offsets ? offsets[i] : 0;
    const x = (pts[i][0] + normals[i][0] * o) * scale + ox;
    const y = (pts[i][1] + normals[i][1] * o) * scale + oy;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.closePath();
}

/** Dim the rim near the four corners: a comet whips round them far faster than along the edges. */
function cornerFade(ctx, w, h, scale, floor = 0.4) {
  const r = Math.min(w, h) * 0.34 * scale;
  ctx.save();
  ctx.globalCompositeOperation = 'destination-out';
  for (const [x, y] of [[0, 0], [w * scale, 0], [0, h * scale], [w * scale, h * scale]]) {
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, `rgba(0,0,0,${1 - floor})`);
    g.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = g;
    ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
  }
  ctx.restore();
}

function draw(dt) {
  if (!contour) return;
  const comet = S.mode === 'spinning';
  const movie = S.mode === 'movie' && !!st.shownRing;
  const g = bloomGeometry();
  st.frame++;

  // A short white flash on each beat makes the hits feel like they land.
  const flash = Math.min(0.4, 0.4 * st.punch);
  const p = flash > 0.01 ? mix(st.curP, WHITE, flash) : st.curP;
  const s = flash > 0.01 ? mix(st.curS, WHITE, flash * 0.6) : st.curS;
  const stops = gradientStops(p, s, comet, movie ? st.shownRing : null);
  // Movie colors are tied to screen positions, so the gradient must not rotate.
  const start = -Math.PI / 2 + (movie ? 0 : st.angle);

  const band = st.thickness * (0.7 + 0.6 * st.level) * (1 + 0.55 * st.punch);
  let wave = null, peak = 0;
  if (st.waveGain > 0) {
    // History is kept at 60 samples a second whatever the real frame rate.
    const steps = Math.max(1, Math.round(dt * 60));
    st.hist.splice(0, steps);
    for (let i = 0; i < steps; i++) st.hist.push(Math.min(1, st.level + 0.5 * st.punch));
    const amp = (3 + 1.1 * st.thickness) * st.waveGain;
    const t = performance.now() / 1000;
    wave = contour.dist.map((d) => {
      const h = st.hist[st.hist.length - 1 - Math.min(st.hist.length - 1, Math.floor(d / 13))];
      const ripple = 0.5 + 0.5 * Math.sin(2 * Math.PI * (d / 260 - t * 0.7));
      return amp * (0.7 * h + 0.3 * st.level * ripple);
    });
    peak = Math.max(...wave);
  }

  // --- sharp band (constant stroke width; the centreline moves so the inner edge sits at band + wave)
  core.setTransform(1, 0, 0, 1, 0, 0);
  core.clearRect(0, 0, coreCanvas.width, coreCanvas.height);
  core.lineJoin = 'round';
  core.lineWidth = 2 * (band + peak) * DPR;
  core.strokeStyle = makeGradient(core, (W * DPR) / 2, (H * DPR) / 2, start, stops);
  if (!g.border) {
    core.shadowColor = css(p, clamp((0.3 + 0.7 * st.glow) * st.master, 0, 1));
    core.shadowBlur = (4 + 26 * st.glow) * (1 + 0.5 * st.punch) * DPR;
  } else {
    core.shadowColor = 'transparent';
    core.shadowBlur = 0;
  }
  tracePath(core, wave ? wave.map((v) => v - peak) : null, DPR);
  core.stroke();
  core.shadowBlur = 0;
  if (comet) cornerFade(core, W, H, DPR);
  coreCanvas.style.opacity = clamp((0.35 + 0.65 * st.level + 0.2 * st.punch) * st.master, 0, 1);

  // --- soft bloom: drawn small and blurred, then scaled up by the compositor (much cheaper)
  const every = comet || movie ? 2 : (S.wavy ? 3 : 6);
  if (st.frame % every === 0 || !bloomCanvas.dataset.drawn) {
    bloomCanvas.dataset.drawn = '1';
    const kb = bloomK;
    bloom.setTransform(1, 0, 0, 1, 0, 0);
    bloom.filter = 'none';
    bloom.clearRect(0, 0, bloomCanvas.width, bloomCanvas.height);
    bloom.filter = `blur(${g.radius / kb}px)`;
    bloom.lineJoin = 'round';
    bloom.lineWidth = (2 * g.reach) / kb;
    bloom.strokeStyle = makeGradient(bloom, bloomPad + W / kb / 2, bloomPad + H / kb / 2, start, stops);
    tracePath(bloom, wave ? wave.map((v) => v * 0.6) : null, 1 / kb, bloomPad, bloomPad);
    bloom.stroke();
    bloom.filter = 'none';
    if (comet) {
      bloom.save();
      bloom.translate(bloomPad, bloomPad);
      cornerFade(bloom, W, H, 1 / kb);
      bloom.restore();
    }
  }
  const gain = g.border ? 0.45 + 0.4 * st.glow : st.glow;
  bloomCanvas.style.opacity = clamp(gain * (0.1 + 0.6 * st.level + 0.3 * st.punch) * st.master * (g.border ? 1.4 : 1), 0, 1);
}

// ---------- demo inputs (so the app can be tried without audio or screen capture)
function demoLevel(t) {
  const beat = (t * 2) % 1; // 120 bpm
  return Math.min(1, 0.32 + 0.12 * Math.sin(t * 0.7) + Math.exp(-beat * 5) * 0.55);
}

function demoRing(t) {
  const hsv = (h, s, v) => {
    const i = Math.floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), tt = v * (1 - (1 - f) * s);
    return [[v, tt, p], [q, v, p], [p, v, tt], [p, q, v], [tt, p, v], [v, p, q]][i % 6].map((x) => x * 255);
  };
  return Array.from({ length: 72 }, (_, j) => hsv(((t * 0.05 + (j / 72) * 0.7) % 1 + 1) % 1, 0.8, 0.5 + 0.5 * Math.abs(Math.sin(j / 9 + t))));
}

// ---------- main loop
let last = performance.now();
function loop(now) {
  requestAnimationFrame(loop);
  if (paused) return;
  const elapsed = now - last;
  if (elapsed < 1000 / desiredFps() - 2) return;
  const dt = clamp(elapsed / 1000, 1 / 120, 0.1);
  last = now;
  if (DEMO) { inLevel = demoLevel(now / 1000); if (S.mode === 'movie') inRing = demoRing(now / 1000); }
  update(dt);
  if (!isStatic()) draw(dt);
}

function applySettings(next) {
  const styleChanged = next.style !== S.style;
  S = { ...S, ...next };
  st.dirtyTime = 1.5;
  if (styleChanged && W) { layoutBloom(); bloomCanvas.dataset.drawn = ''; }
}

resize();
window.addEventListener('resize', resize);

if (TEST) {
  // test/render-test.js steps the engine by hand, then screenshots the page.
  window.__glowrim = {
    configure(next) { applySettings(next); st.thickness = S.thickness; st.glow = S.glow; layoutBloom(); },
    input({ level, ring }) { if (level !== undefined) inLevel = level; if (ring !== undefined) inRing = ring; },
    run(seconds, fps = 60) {
      for (let i = 0; i < seconds * fps; i++) { update(1 / fps); }
      st.master = 1; bloomCanvas.dataset.drawn = '';
      draw(1 / fps);
    },
  };
} else {
  window.glowrim.getState().then((state) => applySettings(state.settings));
  window.glowrim.on('settings', applySettings);
  window.glowrim.on('level', (v) => { inLevel = v; });
  window.glowrim.on('ring', (r) => { inRing = r; });
  window.glowrim.on('paused', (v) => { paused = v; });
  requestAnimationFrame(loop);
}
