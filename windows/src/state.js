// Presets, defaults and the persisted settings store (main process only).
const fs = require('fs');
const path = require('path');

const DEFAULTS = {
  enabled: true,
  preset: 'music.pulse',
  mode: 'music',          // music | breathe | steady | spinning | movie
  style: 'screen',        // screen | border
  primary: '#FF4FA3',
  secondary: '#4F7BFF',
  thickness: 8,
  glow: 0.6,
  sensitivity: 0.5,
  cometCount: 2,
  wavy: true,
  allDisplays: false,
  launchAtLogin: false,
};

const PRESETS = [
  { id: 'movie.cinema', name: 'Cinema', blurb: 'Wide, immersive glow', icon: 'film', category: 'movie',
    mode: 'movie', style: 'screen', thickness: 12, glow: 0.85, comets: 2, wavy: false, preview: ['#FF8A3D', '#3D6BFF'] },
  { id: 'movie.ambient', name: 'Ambient', blurb: 'Soft, tight halo', icon: 'moon', category: 'movie',
    mode: 'movie', style: 'border', thickness: 6, glow: 0.5, comets: 2, wavy: false, preview: ['#4F7BFF', '#9B5CFF'] },
  { id: 'movie.vivid', name: 'Vivid', blurb: 'Big, bold color', icon: 'tv', category: 'movie',
    mode: 'movie', style: 'screen', thickness: 16, glow: 1.0, comets: 2, wavy: true, preview: ['#FF2E9A', '#FFB400'] },

  { id: 'music.pulse', name: 'Pulse', blurb: 'Beat-synced glow, rippling edge', icon: 'waveform', category: 'music',
    mode: 'music', style: 'screen', thickness: 12, glow: 0.6, comets: 2, wavy: true, preview: ['#FF4FA3', '#4F7BFF'] },
  { id: 'music.party', name: 'Party', blurb: 'Three comets racing on the beat', icon: 'party', category: 'music',
    mode: 'spinning', style: 'screen', thickness: 10, glow: 0.8, comets: 3, wavy: true, preview: ['#FFB400', '#FF2E9A'] },
  { id: 'music.neon', name: 'Neon', blurb: 'Cyan and magenta comets', icon: 'bolt', category: 'music',
    mode: 'spinning', style: 'border', thickness: 6, glow: 0.9, comets: 2, wavy: false, preview: ['#00F5FF', '#FF2BD6'] },
  { id: 'music.comet', name: 'Comet', blurb: 'One long trail, chasing the beat', icon: 'sparkle', category: 'music',
    mode: 'spinning', style: 'screen', thickness: 8, glow: 0.7, comets: 1, wavy: false, preview: ['#7FB8FF', '#FF5E62'] },
  { id: 'music.chill', name: 'Chill', blurb: 'Slow, breathing light', icon: 'leaf', category: 'music',
    mode: 'breathe', style: 'screen', thickness: 6, glow: 0.75, comets: 2, wavy: true, preview: ['#00C6FF', '#9B5CFF'] },
  { id: 'music.minimal', name: 'Minimal', blurb: 'A calm, thin line', icon: 'minus', category: 'music',
    mode: 'steady', style: 'border', thickness: 3, glow: 0.3, comets: 1, wavy: false, preview: ['#E0F7FF', '#7FB8FF'] },
];

const PALETTES = [
  ['Sunset', '#FF5E62', '#FFB347'],
  ['Ocean', '#00C6FF', '#0072FF'],
  ['Aurora', '#00F5A0', '#9B5CFF'],
  ['Ember', '#FF2E2E', '#FF8A00'],
  ['Ice', '#E0F7FF', '#7FB8FF'],
  ['Candy', '#FF4FA3', '#4F7BFF'],
];

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** Keep stored values sane, whatever is in the file. */
function sanitize(s) {
  const out = { ...DEFAULTS, ...s };
  const hex = (v, d) => (typeof v === 'string' && /^#[0-9a-fA-F]{6}$/.test(v) ? v.toUpperCase() : d);
  out.primary = hex(out.primary, DEFAULTS.primary);
  out.secondary = hex(out.secondary, DEFAULTS.secondary);
  out.thickness = clamp(Number(out.thickness) || DEFAULTS.thickness, 2, 30);
  out.glow = clamp(Number.isFinite(+out.glow) ? +out.glow : DEFAULTS.glow, 0, 1);
  out.sensitivity = clamp(Number.isFinite(+out.sensitivity) ? +out.sensitivity : DEFAULTS.sensitivity, 0, 1);
  out.cometCount = clamp(Math.round(+out.cometCount || DEFAULTS.cometCount), 1, 4);
  if (!['music', 'breathe', 'steady', 'spinning', 'movie'].includes(out.mode)) out.mode = DEFAULTS.mode;
  if (!['screen', 'border'].includes(out.style)) out.style = DEFAULTS.style;
  for (const k of ['enabled', 'wavy', 'allDisplays', 'launchAtLogin']) out[k] = !!out[k];
  out.preset = typeof out.preset === 'string' ? out.preset : DEFAULTS.preset;
  return out;
}

class Store {
  constructor(dir) {
    this.file = path.join(dir, 'settings.json');
    this.isFirstRun = !fs.existsSync(this.file);
    let raw = {};
    try { raw = JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { /* first run or corrupt file */ }
    this.data = sanitize(raw);
    this.timer = null;
  }

  get() { return this.data; }

  set(patch) {
    this.data = sanitize({ ...this.data, ...patch });
    this.#saveSoon();
    return this.data;
  }

  applyPreset(id) {
    const p = PRESETS.find((x) => x.id === id);
    if (!p) return this.data;
    return this.set({
      preset: p.id, mode: p.mode, style: p.style, thickness: p.thickness, glow: p.glow,
      cometCount: p.comets, wavy: p.wavy, primary: p.preview[0], secondary: p.preview[1],
    });
  }

  reset() {
    this.data = sanitize({});
    this.#saveSoon();
    return this.data;
  }

  #saveSoon() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), 300);
  }

  flush() {
    clearTimeout(this.timer);
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
    } catch (e) { console.error('Could not save settings', e); }
  }
}

module.exports = { DEFAULTS, PRESETS, PALETTES, Store, sanitize };
