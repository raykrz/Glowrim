'use strict';
const api = window.glowrim;
const $ = (id) => document.getElementById(id);

const ICONS = {
  film: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4"/>',
  moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4 6.5 6.5 0 0 0 20 14.5z"/>',
  tv: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4M12 7l1 2 2 1-2 1-1 2-1-2-2-1 2-1z"/>',
  waveform: '<path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4"/>',
  party: '<path d="M4 20l4.5-11.5 7 7z"/><path d="M13 5l1 2.5M17 9l2.5-1M17 3v2.5M20 13.5h2"/>',
  bolt: '<path d="M13 2L5 14h6l-1 8 8-12h-6z" fill="currentColor"/>',
  sparkle: '<path d="M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2z" fill="currentColor"/>',
  leaf: '<path d="M5 19c0-8 5-14 15-14 0 10-6 15-14 15"/><path d="M5 19c3-4 6-6 9-8"/>',
  minus: '<path d="M6 12h12"/>',
  breathe: '<path d="M3 8h11a3 3 0 1 0-3-3M3 12h15a3 3 0 1 1-3 3M3 16h8"/>',
  steady: '<circle cx="12" cy="12" r="8" stroke-dasharray="3 3"/>',
  spinning: '<path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4"/>',
};
const icon = (n) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[n] || ''}</svg>`;
const tick = '<svg class="tick" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M7 12.5l3.2 3.2L17 9" stroke="#0A0604" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const MODES = [
  ['music', 'Music sync', 'waveform'], ['breathe', 'Breathe', 'breathe'], ['steady', 'Steady', 'steady'],
  ['spinning', 'Spinning', 'spinning'], ['movie', 'Movie', 'film'],
];
const STYLES = [['screen', 'Border + screen glow'], ['border', 'Border only']];

let state;
const s = () => state.settings;
const set = (patch) => { state.settings = { ...state.settings, ...patch }; sync(); api.setSettings(patch); };

function segment(el, options, onPick) {
  el.innerHTML = '';
  for (const [value, label] of options) {
    const b = document.createElement('button');
    b.textContent = label; b.dataset.value = value;
    b.onclick = () => onPick(value);
    el.appendChild(b);
  }
}

function build() {
  for (const p of state.presets) {
    const card = document.createElement('button');
    card.className = 'card'; card.dataset.id = p.id;
    card.innerHTML = `<div class="art" style="background:linear-gradient(135deg, ${p.preview[0]}, ${p.preview[1]})">${icon(p.icon)}</div>
      <b>${p.name}</b><small>${p.blurb}</small>${tick}`;
    card.onclick = async () => { state.settings = await api.applyPreset(p.id); sync(); };
    $(p.category === 'movie' ? 'movie-presets' : 'music-presets').appendChild(card);
  }

  $('custom-card').onclick = () => set({ preset: 'custom' });

  $('modes').innerHTML = '';
  for (const [value, label, ic] of MODES) {
    const b = document.createElement('button');
    b.className = 'chip'; b.dataset.value = value; b.innerHTML = `${icon(ic)}<span>${label}</span>`;
    b.onclick = () => set({ mode: value });
    $('modes').appendChild(b);
  }
  segment($('comets'), [1, 2, 3, 4].map((n) => [n, String(n)]), (v) => set({ cometCount: +v }));
  segment($('style'), STYLES, (v) => set({ style: v }));

  for (const [name, a, b] of state.palettes) {
    const btn = document.createElement('button');
    btn.title = name; btn.style.background = `linear-gradient(135deg, ${a}, ${b})`;
    btn.onclick = () => set({ primary: a, secondary: b });
    $('palettes').appendChild(btn);
  }

  const range = (id, fmt) => {
    $(id).addEventListener('input', (e) => { $(`${id}-out`).textContent = fmt(+e.target.value); set({ [id]: +e.target.value }); });
  };
  range('thickness', (v) => `${Math.round(v)} pt`);
  range('glow', (v) => `${Math.round(v * 100)}%`);
  range('sensitivity', (v) => `${Math.round(v * 100)}%`);

  $('primary').addEventListener('input', (e) => set({ primary: e.target.value.toUpperCase() }));
  $('secondary').addEventListener('input', (e) => set({ secondary: e.target.value.toUpperCase() }));
  for (const id of ['enabled', 'wavy', 'allDisplays', 'launchAtLogin']) {
    $(id).addEventListener('change', (e) => set({ [id]: e.target.checked }));
  }
  $('reset').onclick = async () => { state.settings = await api.reset(); sync(); };
}

function syncStatus() {
  const el = $('status'), t = state.status || '';
  el.hidden = !t;
  el.querySelector('span').textContent = t;
  el.classList.toggle('warn', !/^(Listening|Following)/.test(t));
}

function sync() {
  const v = s();
  const custom = v.preset === 'custom';
  document.querySelectorAll('.card[data-id]').forEach((c) => c.classList.toggle('sel', c.dataset.id === v.preset));
  $('custom-card').classList.toggle('sel', custom);
  $('custom-hint').textContent = custom ? 'Starts from your current look' : 'Tap to fine-tune everything';
  $('custom-panel').hidden = !custom;

  $('enabled').checked = v.enabled;
  document.querySelectorAll('#modes .chip').forEach((c) => c.classList.toggle('sel', c.dataset.value === v.mode));
  document.querySelectorAll('#comets button').forEach((c) => c.classList.toggle('sel', +c.dataset.value === v.cometCount));
  document.querySelectorAll('#style button').forEach((c) => c.classList.toggle('sel', c.dataset.value === v.style));
  $('row-comets').hidden = v.mode !== 'spinning';
  $('movie-hint').hidden = v.mode !== 'movie';
  $('row-sens').hidden = !(v.mode === 'music' || v.mode === 'spinning');
  $('colors').hidden = v.mode === 'movie';

  $('wavy').checked = v.wavy;
  $('allDisplays').checked = v.allDisplays;
  $('launchAtLogin').checked = v.launchAtLogin;
  const setRange = (id, val, fmt) => {
    if (document.activeElement !== $(id)) $(id).value = val; // don't fight a slider being dragged
    $(`${id}-out`).textContent = fmt(val);
  };
  setRange('thickness', v.thickness, (x) => `${Math.round(x)} pt`);
  setRange('glow', v.glow, (x) => `${Math.round(x * 100)}%`);
  setRange('sensitivity', v.sensitivity, (x) => `${Math.round(x * 100)}%`);
  if (document.activeElement !== $('primary')) $('primary').value = v.primary.toLowerCase();
  if (document.activeElement !== $('secondary')) $('secondary').value = v.secondary.toLowerCase();
  syncStatus();
}

(async () => {
  state = await api.getState();
  build();
  sync();
  api.on('settings', (next) => { state.settings = next; sync(); });
  api.on('status', (t) => { state.status = t; syncStatus(); });
})();
