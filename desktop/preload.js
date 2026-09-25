const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('shareDesktop', { connect: value => ipcRenderer.invoke('connect', value) });
