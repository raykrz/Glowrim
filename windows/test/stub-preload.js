// Stands in for the real preload so the settings page can be tested without the main process.
const { contextBridge } = require('electron');
const { PRESETS, PALETTES, DEFAULTS, sanitize } = require('../src/state');

let settings = sanitize({ ...DEFAULTS, ...(JSON.parse(process.env.GLOWRIM_TEST_SETTINGS || '{}')) });
const listeners = {};
const emit = (c, v) => (listeners[c] || []).forEach((f) => f(v));

contextBridge.exposeInMainWorld('glowrim', {
  platform: 'win32',
  getState: async () => ({ settings, presets: PRESETS, palettes: PALETTES, status: 'Listening to system audio', defaults: DEFAULTS }),
  setSettings: async (patch) => { settings = sanitize({ ...settings, ...patch }); emit('settings', settings); return settings; },
  applyPreset: async (id) => {
    const p = PRESETS.find((x) => x.id === id);
    settings = sanitize({ ...settings, preset: id, mode: p.mode, style: p.style, thickness: p.thickness, glow: p.glow,
      cometCount: p.comets, wavy: p.wavy, primary: p.preview[0], secondary: p.preview[1] });
    emit('settings', settings); return settings;
  },
  reset: async () => { settings = sanitize({}); emit('settings', settings); return settings; },
  preparePick: async () => true,
  on: (c, cb) => { (listeners[c] = listeners[c] || []).push(cb); },
  send: () => {},
});
