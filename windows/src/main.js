// Glowrim for Windows: a tray app that rims the screen with light.
//
//  - one transparent, click-through overlay window per display (src/overlay)
//  - one hidden capture window that listens to system audio and samples the screen (src/capture)
//  - a settings window (src/settings) and a tray menu
const {
  app, BrowserWindow, Tray, Menu, nativeImage, screen, ipcMain, session, desktopCapturer, powerMonitor,
} = require('electron');
const path = require('path');
const { Store, PRESETS, PALETTES, DEFAULTS } = require('./state');

const DEMO = process.argv.includes('--demo');
const SELFTEST = process.argv.includes('--selftest'); // boot, report what was created, quit (used for checks)
const ASSETS = path.join(__dirname, '..', 'assets');

if (!app.requestSingleInstanceLock()) { app.quit(); }
app.setAppUserModelId('dev.glowrim.app');

let store;
let tray = null;
let settingsWin = null;
let captureWin = null;
let asleep = false;
let statusText = '';
const overlays = new Map(); // display id -> BrowserWindow

const settings = () => store.get();

// ---------- broadcasting
function broadcastSettings() {
  for (const w of overlays.values()) w.webContents.send('settings', settings());
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send('settings', settings());
  if (captureWin && !captureWin.isDestroyed()) captureWin.webContents.send('sensitivity', settings().sensitivity);
}

function setStatus(text) {
  statusText = text;
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send('status', statusText);
  rebuildTray();
}

// ---------- overlays
function targetDisplays() {
  const all = screen.getAllDisplays();
  if (settings().allDisplays) return all;
  return [screen.getPrimaryDisplay()];
}

function createOverlay(display) {
  const b = display.bounds;
  const win = new BrowserWindow({
    x: b.x, y: b.y, width: b.width, height: b.height,
    transparent: true, frame: false, resizable: false, movable: false, focusable: false,
    skipTaskbar: true, hasShadow: false, alwaysOnTop: true, show: false, fullscreenable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true,
      backgroundThrottling: false,
    },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setIgnoreMouseEvents(true);
  // Keep the glow out of screen captures, or Movie mode would feed back into itself.
  win.setContentProtection(true);
  win.loadFile(path.join(__dirname, 'overlay', 'overlay.html'), { query: DEMO ? { demo: '1' } : {} });
  win.once('ready-to-show', () => { if (settings().enabled) win.showInactive(); });
  win.on('closed', () => overlays.delete(display.id));
  overlays.set(display.id, win);
}

function syncOverlays() {
  const wanted = new Map(targetDisplays().map((d) => [d.id, d]));
  for (const [id, win] of overlays) {
    const d = wanted.get(id);
    if (!d) { win.destroy(); overlays.delete(id); continue; }
    const b = d.bounds;
    win.setBounds({ x: b.x, y: b.y, width: b.width, height: b.height });
  }
  for (const [id, d] of wanted) if (!overlays.has(id)) createOverlay(d);
  applyEnabled();
}

let hideTimer = null;
function applyEnabled() {
  clearTimeout(hideTimer);
  if (settings().enabled && !asleep) {
    for (const w of overlays.values()) if (!w.isVisible()) w.showInactive();
  } else {
    // let the overlay fade out first
    hideTimer = setTimeout(() => { for (const w of overlays.values()) w.hide(); }, 700);
  }
}

// ---------- capture (system audio and screen colors)
let pendingPick = { displayId: null, audio: false };

function setupDisplayMediaHandler() {
  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    try {
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
      const want = pendingPick.displayId != null ? String(pendingPick.displayId) : String(screen.getPrimaryDisplay().id);
      const video = sources.find((s) => s.display_id === want) || sources[0];
      const result = { video };
      if (pendingPick.audio) result.audio = 'loopback'; // system audio, no microphone involved
      callback(result);
    } catch (e) {
      console.error('display media request failed', e);
      callback({});
    }
  }, { useSystemPicker: false });
}

function createCaptureWindow() {
  captureWin = new BrowserWindow({
    show: false, width: 320, height: 200,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true,
      backgroundThrottling: false, autoplayPolicy: 'no-user-gesture-required',
    },
  });
  captureWin.loadFile(path.join(__dirname, 'capture', 'capture.html'));
  captureWin.webContents.once('did-finish-load', updateCapture);
}

/** Capture only what the current look needs: audio for the music modes, the screen for Movie. */
function updateCapture() {
  if (!captureWin || captureWin.isDestroyed() || DEMO) return;
  const s = settings();
  const on = s.enabled && !asleep;
  const audio = on && (s.mode === 'music' || s.mode === 'spinning');
  const displays = on && s.mode === 'movie' ? [...overlays.keys()] : [];
  captureWin.webContents.send('capture:config', { audio, displays, sensitivity: s.sensitivity });
  if (!audio && !displays.length) setStatus(on ? '' : 'Off');
}

ipcMain.handle('capture:prepare', (_e, pick) => { pendingPick = { displayId: pick.displayId ?? null, audio: !!pick.audio }; return true; });
ipcMain.on('capture:level', (_e, v) => { for (const w of overlays.values()) w.webContents.send('level', v); });
ipcMain.on('capture:ring', (_e, { displayId, ring }) => { overlays.get(displayId)?.webContents.send('ring', ring); });
ipcMain.on('capture:status', (_e, text) => setStatus(text));

// ---------- settings window
function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) { settingsWin.show(); settingsWin.focus(); return; }
  settingsWin = new BrowserWindow({
    width: 700, height: 820, minWidth: 560, minHeight: 560, show: false, title: 'Glowrim Settings',
    backgroundColor: '#0A0604', autoHideMenuBar: true, icon: path.join(ASSETS, 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  settingsWin.setMenuBarVisibility(false);
  settingsWin.loadFile(path.join(__dirname, 'settings', 'settings.html'));
  settingsWin.once('ready-to-show', () => settingsWin.show());
  settingsWin.on('closed', () => { settingsWin = null; });
}

ipcMain.handle('state:get', () => ({
  settings: settings(), presets: PRESETS, palettes: PALETTES, status: statusText, defaults: DEFAULTS,
}));

function onSettingsChanged(prevMode) {
  app.setLoginItemSettings({ openAtLogin: settings().launchAtLogin });
  syncOverlays();
  broadcastSettings();
  updateCapture();
  if (settings().mode !== prevMode && !['music', 'spinning', 'movie'].includes(settings().mode)) setStatus('');
  rebuildTray();
}

ipcMain.handle('settings:set', (_e, patch) => {
  const prev = settings().mode;
  // Touching any look setting by hand means you're no longer on a preset.
  const lookKeys = ['mode', 'style', 'primary', 'secondary', 'thickness', 'glow', 'sensitivity', 'cometCount', 'wavy'];
  if (!('preset' in patch) && lookKeys.some((k) => k in patch)) patch = { ...patch, preset: 'custom' };
  store.set(patch);
  onSettingsChanged(prev);
  return settings();
});
ipcMain.handle('preset:apply', (_e, id) => {
  const prev = settings().mode;
  store.applyPreset(id);
  onSettingsChanged(prev);
  return settings();
});
ipcMain.handle('settings:reset', () => {
  const prev = settings().mode;
  store.reset();
  onSettingsChanged(prev);
  return settings();
});

// ---------- tray
function swatch(a, b) {
  // a tiny two-color chip for menu items
  const size = 14;
  const buf = Buffer.alloc(size * size * 4);
  const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const [r1, g1, b1] = rgb(a), [r2, g2, b2] = rgb(b);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const dx = x - (size - 1) / 2, dy = y - (size - 1) / 2;
    const inside = Math.hypot(dx, dy) <= size / 2 - 0.5;
    const t = (x + y) / (2 * (size - 1));
    const i = (y * size + x) * 4;
    buf[i] = r1 + (r2 - r1) * t; buf[i + 1] = g1 + (g2 - g1) * t; buf[i + 2] = b1 + (b2 - b1) * t; buf[i + 3] = inside ? 255 : 0;
  }
  return nativeImage.createFromBitmap(buf, { width: size, height: size });
}

function rebuildTray() {
  if (!tray) return;
  const s = settings();
  const presetItems = (category) => PRESETS.filter((p) => p.category === category).map((p) => ({
    label: p.name, type: 'radio', checked: s.preset === p.id, icon: swatch(p.preview[0], p.preview[1]),
    click: () => { store.applyPreset(p.id); onSettingsChanged(s.mode); },
  }));
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Glowrim', enabled: false },
    ...(statusText ? [{ label: statusText, enabled: false }] : []),
    { type: 'separator' },
    { label: 'Enabled', type: 'checkbox', checked: s.enabled, click: (i) => { store.set({ enabled: i.checked }); onSettingsChanged(s.mode); } },
    { type: 'separator' },
    { label: 'Movie presets', enabled: false },
    ...presetItems('movie'),
    { label: 'Music presets', enabled: false },
    ...presetItems('music'),
    { label: 'Custom…', type: 'radio', checked: s.preset === 'custom', click: () => { store.set({ preset: 'custom' }); onSettingsChanged(s.mode); openSettings(); } },
    { type: 'separator' },
    { label: 'Settings…', click: openSettings },
    { label: 'Quit Glowrim', click: () => app.quit() },
  ]));
  tray.setToolTip('Glowrim');
}

function createTray() {
  const icon = nativeImage.createFromPath(path.join(ASSETS, 'tray.png')).resize({ width: 16, height: 16 });
  tray = new Tray(icon);
  tray.on('click', openSettings);
  rebuildTray();
}

// ---------- lifecycle
app.on('second-instance', openSettings);
app.on('window-all-closed', (e) => e.preventDefault()); // keep running in the tray

app.whenReady().then(() => {
  store = new Store(app.getPath('userData'));
  setupDisplayMediaHandler();
  createTray();
  syncOverlays();
  createCaptureWindow();
  if (store.isFirstRun) openSettings(); // tray icons hide in the overflow on Windows, so say hello

  for (const ev of ['display-added', 'display-removed', 'display-metrics-changed']) screen.on(ev, () => { syncOverlays(); updateCapture(); });

  powerMonitor.on('suspend', () => { asleep = true; for (const w of overlays.values()) w.webContents.send('paused', true); updateCapture(); });
  powerMonitor.on('resume', () => { asleep = false; for (const w of overlays.values()) w.webContents.send('paused', false); applyEnabled(); updateCapture(); });
  powerMonitor.on('lock-screen', () => { for (const w of overlays.values()) w.webContents.send('paused', true); });
  powerMonitor.on('unlock-screen', () => { for (const w of overlays.values()) w.webContents.send('paused', false); });
});

app.on('before-quit', () => store && store.flush());

if (SELFTEST) {
  app.whenReady().then(() => setTimeout(() => {
    const report = {
      overlays: overlays.size,
      overlayVisible: [...overlays.values()].map((w) => w.isVisible()),
      settingsWindow: !!settingsWin && !settingsWin.isDestroyed(),
      tray: !!tray,
      captureWindow: !!captureWin && !captureWin.isDestroyed(),
      mode: settings().mode,
    };
    console.log('SELFTEST ' + JSON.stringify(report));
    app.exit(0);
  }, 6000));
}
