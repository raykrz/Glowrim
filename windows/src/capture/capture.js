'use strict';
// Hidden window. Listens to system audio (WASAPI loopback, never the microphone) to find the beat,
// and samples a tiny copy of the screen for Movie mode. Nothing is saved or sent anywhere.

const SEGMENTS = 72;
let sensitivity = 0.5;
let wanted = { audio: false, displays: [] };
let audioSession = null;       // { stream, ctx, timer }
const screenSessions = new Map(); // displayId -> { stream, video, canvas, timer }

const status = (t) => window.glowrim.send('capture:status', t);

// ---------- beat analysis (port of BeatAnalyzer.swift)
function startAudio() {
  return (async () => {
    await window.glowrim.preparePick({ displayId: null, audio: true });
    // The video half is needed to ask for loopback audio; drop it straight away.
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    stream.getVideoTracks().forEach((t) => t.stop());
    if (!stream.getAudioTracks().length) throw new Error('no audio track');

    const ctx = new AudioContext();
    const src = ctx.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
    const full = ctx.createAnalyser(); full.fftSize = 2048;
    const bassA = ctx.createAnalyser(); bassA.fftSize = 2048;
    // two low-pass poles around 160 Hz isolate the kick drum / bass
    const lp1 = ctx.createBiquadFilter(), lp2 = ctx.createBiquadFilter();
    for (const f of [lp1, lp2]) { f.type = 'lowpass'; f.frequency.value = 160; f.Q.value = 0.7071; }
    src.connect(full);
    src.connect(lp1); lp1.connect(lp2); lp2.connect(bassA);

    const fb = new Float32Array(full.fftSize), bb = new Float32Array(bassA.fftSize);
    let avg = 0, peak = 0.0001, env = 0, pulse = 0, lastBeat = 0;
    const rms = (buf, n) => { let s = 0; for (let i = buf.length - n; i < buf.length; i++) s += buf[i] * buf[i]; return Math.sqrt(s / n); };

    const timer = setInterval(() => {
      full.getFloatTimeDomainData(fb); bassA.getFloatTimeDomainData(bb);
      const n = Math.max(256, Math.floor(ctx.sampleRate * 0.02));
      const e = rms(bb, n) * 0.75 + rms(fb, n) * 0.25;
      avg = avg * 0.96 + e * 0.04;
      peak = Math.max(e, peak * 0.9993);
      const silent = peak < 0.003;
      const norm = silent ? 0 : Math.min(1, e / peak);
      const now = performance.now() / 1000;
      const threshold = 1.15 + (1 - sensitivity) * 0.6;
      pulse *= 0.9;
      if (!silent && e > avg * threshold && e > peak * 0.25 && now - lastBeat > 0.16) { pulse = 1; lastBeat = now; }
      env += (norm - env) * (norm > env ? 0.5 : 0.07); // fast attack, slow release
      window.glowrim.send('capture:level', Math.min(1, env * 0.6 + pulse * 0.55));
    }, 16);

    audioSession = { stream, ctx, timer };
    status('Listening to system audio');
  })();
}

function stopAudio() {
  if (!audioSession) return;
  clearInterval(audioSession.timer);
  audioSession.stream.getTracks().forEach((t) => t.stop());
  audioSession.ctx.close();
  audioSession = null;
  window.glowrim.send('capture:level', 0);
}

// ---------- screen colors (port of ScreenSampler.swift)
function rgbToHsv(r, g, b) {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let h = 0;
  if (d > 0) {
    if (mx === r) h = ((g - b) / d) % 6; else if (mx === g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
    h /= 6; if (h < 0) h += 1;
  }
  return [h, mx === 0 ? 0 : d / mx, mx];
}
function hsvToRgb(h, s, v) {
  const i = Math.floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  return [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][((i % 6) + 6) % 6];
}
/** More vivid, never fully black, so a dark scene still leaves a faint glow. */
function punch(c) {
  const [h, s, v] = rgbToHsv(c[0], c[1], c[2]);
  return hsvToRgb(h, Math.min(1, s * 1.35), Math.min(1, Math.max(0.12, v * 1.3))).map((x) => x * 255);
}

/** One color per segment around the edge, clockwise from the top: same order as the rim's gradient. */
function edgeColors(img, w, h) {
  const d = img.data;
  const halfW = Math.max(1, Math.floor(w * 0.05)), halfH = Math.max(1, Math.floor(h * 0.05));
  const average = (cx, cy) => {
    let r = 0, g = 0, b = 0, n = 0;
    for (let y = Math.max(0, cy - halfH); y <= Math.min(h - 1, cy + halfH); y++) {
      for (let x = Math.max(0, cx - halfW); x <= Math.min(w - 1, cx + halfW); x++) {
        const i = (y * w + x) * 4; r += d[i]; g += d[i + 1]; b += d[i + 2]; n++;
      }
    }
    return [r / n, g / n, b / n];
  };
  const ring = [];
  for (let j = 0; j < SEGMENTS; j++) {
    const phi = (2 * Math.PI * j) / SEGMENTS;
    const dx = Math.sin(phi), dy = -Math.cos(phi); // screen coords: y grows downward
    const t = Math.min(dx ? w / 2 / Math.abs(dx) : Infinity, dy ? h / 2 / Math.abs(dy) : Infinity);
    const bx = w / 2 + dx * t, by = h / 2 + dy * t;
    // start at the very edge; if it is black (letterbox bars), look further in
    let c = [0, 0, 0];
    for (const f of [0.12, 0.3, 0.5, 0.7]) {
      const px = Math.min(w - 1, Math.max(0, Math.round(bx + (w / 2 - bx) * f)));
      const py = Math.min(h - 1, Math.max(0, Math.round(by + (h / 2 - by) * f)));
      c = average(px, py);
      if (Math.max(c[0], c[1], c[2]) / 255 > 0.08) break;
    }
    ring.push(c);
  }
  // soften neighbours so a busy frame doesn't shimmer
  return ring.map((_, j) => {
    const a = ring[(j + SEGMENTS - 1) % SEGMENTS], m = ring[j], b = ring[(j + 1) % SEGMENTS];
    return punch([0, 1, 2].map((k) => a[k] * 0.25 + m[k] * 0.5 + b[k] * 0.25));
  });
}

async function startScreen(displayId) {
  await window.glowrim.preparePick({ displayId, audio: false });
  const stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { max: 15 } }, audio: false });
  const video = document.createElement('video');
  video.muted = true; video.srcObject = stream;
  await video.play();
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const timer = setInterval(() => {
    if (!video.videoWidth) return;
    const w = 96, h = Math.max(16, Math.round((w * video.videoHeight) / video.videoWidth));
    canvas.width = w; canvas.height = h;
    ctx.drawImage(video, 0, 0, w, h);
    window.glowrim.send('capture:ring', { displayId, ring: edgeColors(ctx.getImageData(0, 0, w, h), w, h) });
  }, 1000 / 15);
  screenSessions.set(displayId, { stream, video, timer });
}

function stopScreen(displayId) {
  const s = screenSessions.get(displayId);
  if (!s) return;
  clearInterval(s.timer);
  s.stream.getTracks().forEach((t) => t.stop());
  s.video.srcObject = null;
  screenSessions.delete(displayId);
}

// ---------- control
let busy = Promise.resolve();
function reconcile() {
  // run one reconcile at a time, so quick setting changes can't race each other
  busy = busy.then(async () => {
    try {
      if (!wanted.audio) stopAudio();
      else if (!audioSession) await startAudio();

      for (const id of [...screenSessions.keys()]) if (!wanted.displays.includes(id)) stopScreen(id);
      for (const id of wanted.displays) if (!screenSessions.has(id)) await startScreen(id);
      if (wanted.displays.length) status('Following the screen');
    } catch (e) {
      console.error(e);
      status(wanted.displays.length
        ? 'Screen capture unavailable. Check that Glowrim can capture the screen.'
        : 'Audio unavailable. Check your sound output and try again.');
    }
  });
}

window.glowrim.on('capture:config', (cfg) => {
  sensitivity = cfg.sensitivity ?? sensitivity;
  wanted = { audio: !!cfg.audio, displays: cfg.displays || [] };
  reconcile();
});
window.glowrim.on('sensitivity', (v) => { sensitivity = v; });
