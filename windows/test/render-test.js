// Renders the overlay page in several looks and saves PNGs (no screen permission needed).
// Run with:  npm run test:render
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const OUT = process.env.OUT_DIR || path.join(__dirname, 'out');
const W = 960, H = 540;

const demoRing = () => {
  const hsv = (h, s, v) => {
    const i = Math.floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
    return [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6].map((x) => x * 255);
  };
  // left half warm, right half cool, top bar green: shows that edges map to the right place
  return Array.from({ length: 72 }, (_, j) => {
    const a = (j / 72) * 2 * Math.PI; // clockwise from top
    const x = Math.sin(a), y = -Math.cos(a);
    if (y < -0.85) return hsv(0.33, 0.9, 0.9);
    return x < 0 ? hsv(0.02, 0.9, 0.95) : hsv(0.6, 0.9, 0.95);
  });
};

const SCENES = {
  pulse:   { s: { mode: 'music', style: 'screen', thickness: 12, glow: 0.6, wavy: true, primary: '#FF4FA3', secondary: '#4F7BFF' }, level: 0.8, seconds: 1.2 },
  party:   { s: { mode: 'spinning', style: 'screen', thickness: 10, glow: 0.8, wavy: true, cometCount: 3, primary: '#FFB400', secondary: '#FF2E9A' }, level: 0.8, seconds: 1.5 },
  neon:    { s: { mode: 'spinning', style: 'border', thickness: 6, glow: 0.9, wavy: false, cometCount: 2, primary: '#00F5FF', secondary: '#FF2BD6' }, level: 0.7, seconds: 1.5 },
  comet:   { s: { mode: 'spinning', style: 'screen', thickness: 8, glow: 0.7, wavy: false, cometCount: 1, primary: '#7FB8FF', secondary: '#FF5E62' }, level: 0.6, seconds: 1.0 },
  movie:   { s: { mode: 'movie', style: 'screen', thickness: 12, glow: 0.85, wavy: false }, level: 0, seconds: 1.5, ring: demoRing() },
  minimal: { s: { mode: 'steady', style: 'border', thickness: 3, glow: 0.3, wavy: false, primary: '#E0F7FF', secondary: '#7FB8FF' }, level: 0, seconds: 1.5 },
};

app.disableHardwareAcceleration();
app.whenReady().then(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const only = process.argv.slice(2).filter((a) => SCENES[a]);
  // One window for every scene: a fresh window needs a new helper process, which restricted shells block.
  const win = new BrowserWindow({ width: W, height: H, show: false, frame: false, transparent: false,
    webPreferences: { backgroundThrottling: false } });
  for (const [name, sc] of Object.entries(SCENES)) {
    if (only.length && !only.includes(name)) continue;
    await win.loadFile(path.join(__dirname, '../src/overlay/overlay.html'), { query: { test: '1', bg: '1' } });
    await win.webContents.executeJavaScript(`
      window.__glowrim.configure(${JSON.stringify(sc.s)});
      window.__glowrim.input({ level: ${sc.level}, ring: ${JSON.stringify(sc.ring || null)} });
      window.__glowrim.run(${sc.seconds});
      true`);
    await new Promise((r) => setTimeout(r, 250));
    const img = await win.webContents.capturePage();
    fs.writeFileSync(path.join(OUT, `${name}.png`), img.toPNG());
    console.log('wrote', name);
  }
  win.destroy();
  app.quit();
});
