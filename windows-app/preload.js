const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('desktopAPI', {
  getInitialSettings: () => ipcRenderer.invoke('app:get-initial-settings'),
  saveSettings: (settings) => ipcRenderer.invoke('app:save-settings', settings),
  pickAudioFiles: () => ipcRenderer.invoke('app:pick-audio-files'),
  startBatch: (files, settings) => ipcRenderer.invoke('app:start-batch', { files, settings }),
  onLog: (handler) => {
    const listener = (_event, data) => handler(data);
    ipcRenderer.on('job:log', listener);
    return () => ipcRenderer.removeListener('job:log', listener);
  },
  onProgress: (handler) => {
    const listener = (_event, data) => handler(data);
    ipcRenderer.on('job:progress', listener);
    return () => ipcRenderer.removeListener('job:progress', listener);
  },
});
