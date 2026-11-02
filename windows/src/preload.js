// Small, explicit bridge between the pages and the main process.
const { contextBridge, ipcRenderer } = require('electron');

const RECEIVE = new Set(['settings', 'level', 'ring', 'paused', 'status', 'capture:config', 'sensitivity']);
const SEND = new Set(['capture:level', 'capture:ring', 'capture:status']);

contextBridge.exposeInMainWorld('glowrim', {
  platform: process.platform,
  getState: () => ipcRenderer.invoke('state:get'),
  setSettings: (patch) => ipcRenderer.invoke('settings:set', patch),
  applyPreset: (id) => ipcRenderer.invoke('preset:apply', id),
  reset: () => ipcRenderer.invoke('settings:reset'),
  preparePick: (arg) => ipcRenderer.invoke('capture:prepare', arg),
  on: (channel, cb) => {
    if (RECEIVE.has(channel)) ipcRenderer.on(channel, (_e, ...args) => cb(...args));
  },
  send: (channel, payload) => {
    if (SEND.has(channel)) ipcRenderer.send(channel, payload);
  },
});
