// Loads the settings page with a stub backend, clicks around, and saves screenshots.
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');
const OUT = process.env.OUT_DIR || path.join(__dirname, 'out');

app.disableHardwareAcceleration();
app.whenReady().then(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const win = new BrowserWindow({ width: 700, height: 1450, show: false, backgroundColor: '#0A0604',
    webPreferences: { preload: path.join(__dirname, 'stub-preload.js'), sandbox: false, contextIsolation: true } });
  const errors = [];
  win.webContents.on('console-message', (_e, level, message) => { if (level >= 2) errors.push(message); });
  await win.loadFile(path.join(__dirname, '../src/settings/settings.html'));
  const run = (js) => win.webContents.executeJavaScript(js);
  const shot = async (name) => {
    await new Promise((r) => setTimeout(r, 300));
    fs.writeFileSync(path.join(OUT, `${name}.png`), (await win.webContents.capturePage()).toPNG());
    console.log('wrote', name);
  };
  await new Promise((r) => setTimeout(r, 400));
  await shot('settings-presets');

  // click the "Party" preset, then Custom, then the Spinning chip and 3 comets
  await run(`document.querySelector('.card[data-id="music.party"]').click()`);
  await new Promise((r) => setTimeout(r, 200));
  console.log('after Party:', await run(`JSON.stringify({sel: document.querySelector('.card.sel')?.dataset.id, panelHidden: document.getElementById('custom-panel').hidden})`));
  await run(`document.getElementById('custom-card').click()`);
  await new Promise((r) => setTimeout(r, 200));
  await run(`document.querySelector('#comets button[data-value="3"]').click()`);
  await run(`(() => { const t = document.getElementById('thickness'); t.value = 14; t.dispatchEvent(new Event('input')); })()`);
  await new Promise((r) => setTimeout(r, 200));
  console.log('custom state:', await run(`JSON.stringify({panelHidden: document.getElementById('custom-panel').hidden, comets: document.querySelector('#comets .sel')?.dataset.value, thick: document.getElementById('thickness-out').textContent, cometsRowHidden: document.getElementById('row-comets').hidden})`));
  await shot('settings-custom');

  await run(`document.querySelector('#modes .chip[data-value="movie"]').click()`);
  await new Promise((r) => setTimeout(r, 200));
  console.log('movie state:', await run(`JSON.stringify({colorsHidden: document.getElementById('colors').hidden, sensHidden: document.getElementById('row-sens').hidden, hint: !document.getElementById('movie-hint').hidden})`));
  console.log(errors.length ? 'console errors: ' + errors.join(' | ') : 'no console errors');
  win.destroy(); app.quit();
});
