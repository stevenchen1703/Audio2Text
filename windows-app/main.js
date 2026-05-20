const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const fs = require('fs');
const path = require('path');

const {
  defaultSettings,
  sanitizeSettings,
  loadSettingsFromDisk,
  saveSettingsToDisk,
  formatOutputText,
  transcribeBatch,
} = require('./lib/service');

let mainWindow = null;

function createWindow() {
  const iconPath = path.join(__dirname, 'assets', 'icon.ico');
  mainWindow = new BrowserWindow({
    width: 1080,
    height: 760,
    minWidth: 960,
    minHeight: 680,
    title: '豆包语音妙记',
    icon: iconPath,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  mainWindow.loadFile(path.join(__dirname, 'src/index.html'));
}

app.whenReady().then(() => {
  if (process.platform === 'win32') {
    app.setAppUserModelId('com.audio2txt.doubao.windows');
  }
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

function getSettingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

ipcMain.handle('app:get-initial-settings', async () => {
  const p = getSettingsPath();
  const loaded = loadSettingsFromDisk(p);
  return sanitizeSettings(loaded || defaultSettings());
});

ipcMain.handle('app:save-settings', async (_event, settings) => {
  const p = getSettingsPath();
  const sanitized = sanitizeSettings(settings);
  saveSettingsToDisk(p, sanitized);
  return sanitized;
});

ipcMain.handle('app:pick-audio-files', async () => {
  if (!mainWindow) return [];
  const ret = await dialog.showOpenDialog(mainWindow, {
    title: '添加课程录音（可多选）',
    properties: ['openFile', 'multiSelections'],
    filters: [{ name: 'Audio', extensions: ['mp3', 'm4a', 'wav', 'aiff'] }],
  });
  return ret.canceled ? [] : ret.filePaths;
});

async function pickSaveTargets(files) {
  if (!mainWindow) return null;
  if (files.length === 1) {
    const one = files[0];
    const parsed = path.parse(one);
    const result = await dialog.showSaveDialog(mainWindow, {
      title: '保存转写文本',
      defaultPath: path.join(parsed.dir, `${parsed.name}.txt`),
      filters: [{ name: '文本', extensions: ['txt'] }],
    });
    if (result.canceled || !result.filePath) return null;
    return { [one]: result.filePath };
  }

  const folder = await dialog.showOpenDialog(mainWindow, {
    title: '选择批量输出文件夹',
    properties: ['openDirectory', 'createDirectory'],
  });
  if (folder.canceled || folder.filePaths.length === 0) return null;

  const targetDir = folder.filePaths[0];
  const mapping = {};
  for (const f of files) {
    const p = path.parse(f);
    mapping[f] = path.join(targetDir, `${p.name}.txt`);
  }
  return mapping;
}

ipcMain.handle('app:start-batch', async (event, payload) => {
  const files = Array.isArray(payload?.files) ? payload.files : [];
  const settings = sanitizeSettings(payload?.settings || {});

  const send = (channel, data) => {
    if (!event.sender.isDestroyed()) {
      event.sender.send(channel, data);
    }
  };

  const logger = (line) => send('job:log', line);
  const progress = (value, text) => send('job:progress', { value, text });

  try {
    const results = await transcribeBatch(files, settings, logger, progress);

    if (settings.completionSoundEnabled) {
      shell.beep();
    }

    logger('转写已完成，开始选择保存位置');
    progress(1, '转写完成 100%');

    const outputTargets = await pickSaveTargets(files);
    if (!outputTargets) {
      logger('用户取消保存，结果仅保留在本次会话内');
      return { ok: true, canceled: true };
    }

    for (const input of files) {
      const outputPath = outputTargets[input];
      const result = results[input];
      if (!result || !outputPath) continue;

      const text = formatOutputText(result);
      fs.writeFileSync(outputPath, text, 'utf8');
      logger(`[${path.basename(input)}] 保存成功: ${outputPath}`);

      if (settings.saveRawJSON && result.rawJSONBuffer) {
        const rawPath = outputPath.replace(/\.txt$/i, '.raw.json');
        fs.writeFileSync(rawPath, result.rawJSONBuffer);
        logger(`[${path.basename(input)}] 调试JSON已保存: ${rawPath}`);
      }
    }

    logger('全部任务完成');
    return { ok: true, canceled: false };
  } catch (error) {
    return { ok: false, error: error?.message || String(error) };
  }
});
