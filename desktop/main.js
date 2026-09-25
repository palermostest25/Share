const { app, autoUpdater, BrowserWindow, dialog, ipcMain, Menu, shell } = require('electron');
const squirrelStartup = require('electron-squirrel-startup');
const { updateElectronApp, UpdateSourceType } = require('update-electron-app');
const fs = require('node:fs');
const path = require('node:path');
const { parseServerURL } = require('./url');

let win;
let serverOrigin = '';
let manualUpdateCheck = false;

async function checkUpdates() {
	if (process.platform === 'win32' && app.isPackaged) {
		manualUpdateCheck = true;
		try { autoUpdater.checkForUpdates(); } catch (error) { manualUpdateCheck = false; dialog.showErrorBox('Update check failed', error.message); }
		return;
	}
	try {
		const response = await fetch('https://api.github.com/repos/palermostest25/Share/releases/latest', { headers: { 'User-Agent': 'ShareDesktop' } });
		if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
		const release = await response.json();
		const latest = release.tag_name.replace(/^v/, '');
		const current = app.getVersion();
		if (latest.localeCompare(current, undefined, { numeric: true }) <= 0) {
			await dialog.showMessageBox(win, { type: 'info', message: `Share ${current} is current.` });
			return;
		}
		const answer = await dialog.showMessageBox(win, { type: 'info', buttons: ['Open release', 'Later'], defaultId: 0,
			message: `Share ${latest} is available`, detail: `You have ${current}. Download the ${process.platform === 'linux' ? 'DEB or RPM package' : 'installer'} from GitHub Releases.` });
		if (answer.response === 0) shell.openExternal(release.html_url);
	} catch (error) { dialog.showErrorBox('Update check failed', error.message); }
}
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');

function readOrigin() {
  try { return parseServerURL(JSON.parse(fs.readFileSync(settingsFile(), 'utf8')).serverURL); }
  catch { return ''; }
}

function saveOrigin(origin) {
  fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
  fs.writeFileSync(settingsFile(), JSON.stringify({ serverURL: origin }), { mode: 0o600 });
}

function safeExternal(raw) {
  try {
    const url = new URL(raw);
		if ((url.origin === serverOrigin && (url.protocol === 'https:' || url.protocol === 'http:')) ||
			(url.origin === 'https://github.com' && url.pathname.startsWith('/palermostest25/Share/releases'))) shell.openExternal(raw);
  } catch { /* Ignore invalid URLs. */ }
}

function showConnect() {
  serverOrigin = '';
  win.loadFile('connect.html');
}

async function connect(raw) {
  const origin = parseServerURL(raw);
  if (origin.startsWith('http:')) {
    const answer = await dialog.showMessageBox(win, {
      type: 'warning', buttons: ['Cancel', 'Continue on trusted LAN'], defaultId: 0, cancelId: 0,
      message: 'Local HTTP is not encrypted',
      detail: 'Your sign-in and files could be intercepted on this network. Use HTTPS when possible.'
    });
    if (answer.response !== 1) return false;
  }
  // Set the origin before navigation. Every subsequent navigation is constrained to it.
  serverOrigin = origin;
  saveOrigin(origin);
  try { await win.loadURL(origin); }
  catch (error) { showConnect(); dialog.showErrorBox('Could not connect', error.message); return false; }
  return true;
}

function createWindow() {
  win = new BrowserWindow({
    width: 1180, height: 760, minWidth: 740, minHeight: 500,
    title: 'Share', backgroundColor: '#0d1016',
		webPreferences: { preload: path.join(__dirname, 'preload.js'), nodeIntegration: false, contextIsolation: true, sandbox: true, webSecurity: true }
  });
  win.webContents.setWindowOpenHandler(({ url }) => { safeExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (event, target) => {
    if (target.startsWith('file:') && !serverOrigin) return;
    try { if (new URL(target).origin === serverOrigin) return; } catch { /* denied */ }
    event.preventDefault();
  });
  win.webContents.session.setPermissionRequestHandler((contents, permission, callback) => {
    callback(permission === 'clipboard-write' && contents === win.webContents && contents.getURL().startsWith(serverOrigin));
  });
  const menu = Menu.buildFromTemplate([
    { label: 'File', submenu: [{ label: 'Change server…', click: showConnect }, { role: 'quit' }] },
    { label: 'Edit', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
    { label: 'View', submenu: [{ role: 'reload' }, { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' }, { role: 'togglefullscreen' }] },
		{ label: 'Help', submenu: [{ label: 'Check for updates…', click: checkUpdates }, { label: 'GitHub Releases', click: () => shell.openExternal('https://github.com/palermostest25/Share/releases') }] }
  ]);
  Menu.setApplicationMenu(menu);
  const saved = readOrigin();
  if (saved && saved.startsWith('https:')) { serverOrigin = saved; win.loadURL(saved).catch(showConnect); }
	else if (saved) connect(saved).then(ok => { if (!ok) showConnect(); }).catch(showConnect);
	else showConnect();
}

if (squirrelStartup) app.quit();
else app.whenReady().then(() => {
	if (process.platform === 'win32') {
		app.setAppUserModelId('dev.denby.share.desktop');
		if (app.isPackaged) {
			updateElectronApp({ updateSource: { type: UpdateSourceType.ElectronPublicUpdateService, repo: 'palermostest25/Share' }, updateInterval: '1 hour' });
			autoUpdater.on('update-not-available', () => { if (manualUpdateCheck) dialog.showMessageBox(win, { type: 'info', message: 'Share is up to date.' }); manualUpdateCheck = false; });
			autoUpdater.on('update-downloaded', () => { manualUpdateCheck = false; });
			autoUpdater.on('error', error => { if (manualUpdateCheck) dialog.showErrorBox('Update check failed', error.message); manualUpdateCheck = false; });
		}
	}
  ipcMain.handle('connect', async (event, value) => {
    if (event.sender !== win?.webContents || !event.sender.getURL().startsWith('file:')) return { error: 'Invalid request.' };
		try { return { ok: await connect(value) }; } catch (error) { return { error: error.message }; }
  });
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
