const state = {
  selectedFiles: [],
  running: false,
  settings: null,
  unbindLog: null,
  unbindProgress: null,
};

const el = {
  addAudio: document.getElementById('addAudio'),
  clearReselect: document.getElementById('clearReselect'),
  startBtn: document.getElementById('startBtn'),
  fileList: document.getElementById('fileList'),
  statusText: document.getElementById('statusText'),
  logs: document.getElementById('logs'),
  overallProgress: document.getElementById('overallProgress'),
  progressText: document.getElementById('progressText'),
  openSettings: document.getElementById('openSettings'),
  settingsDialog: document.getElementById('settingsDialog'),
  settingsCancel: document.getElementById('settingsCancel'),
  settingsSave: document.getElementById('settingsSave'),

  volcAppKey: document.getElementById('volcAppKey'),
  volcAccessKey: document.getElementById('volcAccessKey'),
  volcResourceId: document.getElementById('volcResourceId'),
  tosRegion: document.getElementById('tosRegion'),
  tosEndpoint: document.getElementById('tosEndpoint'),
  tosBucket: document.getElementById('tosBucket'),
  tosAK: document.getElementById('tosAK'),
  tosSK: document.getElementById('tosSK'),
  tosStsToken: document.getElementById('tosStsToken'),
  tosObjectPrefix: document.getElementById('tosObjectPrefix'),

  completionSoundEnabled: document.getElementById('completionSoundEnabled'),
  tosSignExpiresSec: document.getElementById('tosSignExpiresSec'),
  pollIntervalSec: document.getElementById('pollIntervalSec'),
  maxWaitMin: document.getElementById('maxWaitMin'),
  maxConcurrentJobs: document.getElementById('maxConcurrentJobs'),
  deleteTempObject: document.getElementById('deleteTempObject'),
  saveRawJSON: document.getElementById('saveRawJSON'),

  translationEnabled: document.getElementById('translationEnabled'),
  translateENToZH: document.getElementById('translateENToZH'),
  translateZHToEN: document.getElementById('translateZHToEN'),
};

function appendLog(line) {
  const text = line || '';
  if (!el.logs.value) {
    el.logs.value = text;
  } else {
    el.logs.value += `\n${text}`;
  }
  el.logs.scrollTop = el.logs.scrollHeight;
}

function updateStatus() {
  if (state.selectedFiles.length === 0) {
    el.statusText.textContent = '请选择一个或多个 m4a/mp3 音频文件';
  } else {
    el.statusText.textContent = `已选择 ${state.selectedFiles.length} 个文件`;
  }
  el.startBtn.disabled = state.running || state.selectedFiles.length === 0;
}

function renderFiles() {
  el.fileList.innerHTML = '';
  if (state.selectedFiles.length === 0) {
    const div = document.createElement('div');
    div.className = 'fileRow';
    div.textContent = '未选择文件';
    el.fileList.appendChild(div);
    updateStatus();
    return;
  }

  for (const file of state.selectedFiles) {
    const row = document.createElement('div');
    row.className = 'fileRow';

    const left = document.createElement('div');
    left.className = 'filePath';
    left.title = file;
    left.textContent = file;

    const right = document.createElement('button');
    right.className = 'removeBtn';
    right.textContent = '移除';
    right.disabled = state.running;
    right.addEventListener('click', () => {
      state.selectedFiles = state.selectedFiles.filter((v) => v !== file);
      renderFiles();
    });

    row.appendChild(left);
    row.appendChild(right);
    el.fileList.appendChild(row);
  }

  updateStatus();
}

function mergeFiles(files) {
  const merged = new Set(state.selectedFiles);
  for (const f of files) merged.add(f);
  state.selectedFiles = [...merged].sort((a, b) => a.localeCompare(b));
  renderFiles();
}

function readSettingsFromForm() {
  const translationEnabled = !!el.translationEnabled.checked;
  let translationSourceLang = 'en_us';
  let translationTargetLang = 'zh_cn';
  if (translationEnabled && el.translateZHToEN.checked) {
    translationSourceLang = 'zh_cn';
    translationTargetLang = 'en_us';
  }

  return {
    volcAppKey: el.volcAppKey.value.trim(),
    volcAccessKey: el.volcAccessKey.value.trim(),
    volcResourceId: el.volcResourceId.value.trim(),

    tosRegion: el.tosRegion.value.trim(),
    tosEndpoint: el.tosEndpoint.value.trim(),
    tosBucket: el.tosBucket.value.trim(),
    tosAK: el.tosAK.value.trim(),
    tosSK: el.tosSK.value.trim(),
    tosStsToken: el.tosStsToken.value.trim(),
    tosObjectPrefix: el.tosObjectPrefix.value.trim(),

    completionSoundEnabled: !!el.completionSoundEnabled.checked,
    tosSignExpiresSec: Number.parseInt(el.tosSignExpiresSec.value || '14400', 10),
    pollIntervalSec: Number.parseInt(el.pollIntervalSec.value || '30', 10),
    maxWaitMin: Number.parseInt(el.maxWaitMin.value || '120', 10),
    maxConcurrentJobs: Number.parseInt(el.maxConcurrentJobs.value || '10', 10),
    deleteTempObject: !!el.deleteTempObject.checked,
    saveRawJSON: !!el.saveRawJSON.checked,

    translationEnabled,
    translationSourceLang,
    translationTargetLang,
  };
}

function applySettingsToForm(s) {
  el.volcAppKey.value = s.volcAppKey || '';
  el.volcAccessKey.value = s.volcAccessKey || '';
  el.volcResourceId.value = s.volcResourceId || 'volc.lark.minutes';

  el.tosRegion.value = s.tosRegion || 'cn-beijing';
  el.tosEndpoint.value = s.tosEndpoint || 'tos-cn-beijing.volces.com';
  el.tosBucket.value = s.tosBucket || '';
  el.tosAK.value = s.tosAK || '';
  el.tosSK.value = s.tosSK || '';
  el.tosStsToken.value = s.tosStsToken || '';
  el.tosObjectPrefix.value = s.tosObjectPrefix || 'audio2txt/';

  el.completionSoundEnabled.checked = !!s.completionSoundEnabled;
  el.tosSignExpiresSec.value = s.tosSignExpiresSec || 14400;
  el.pollIntervalSec.value = s.pollIntervalSec || 30;
  el.maxWaitMin.value = s.maxWaitMin || 120;
  el.maxConcurrentJobs.value = s.maxConcurrentJobs || 10;
  el.deleteTempObject.checked = !!s.deleteTempObject;
  el.saveRawJSON.checked = !!s.saveRawJSON;

  el.translationEnabled.checked = !!s.translationEnabled;
  const zhToEn = s.translationSourceLang === 'zh_cn' && s.translationTargetLang === 'en_us';
  el.translateZHToEN.checked = zhToEn;
  el.translateENToZH.checked = !zhToEn;
  updateTranslationSubState();
}

function updateTranslationSubState() {
  const enabled = !!el.translationEnabled.checked;
  el.translateENToZH.disabled = !enabled;
  el.translateZHToEN.disabled = !enabled;
  el.translateENToZH.parentElement.style.opacity = enabled ? '1' : '0.45';
  el.translateZHToEN.parentElement.style.opacity = enabled ? '1' : '0.45';

  if (!enabled) {
    el.translateENToZH.checked = true;
    el.translateZHToEN.checked = false;
  }
}

function setRunning(running) {
  state.running = running;
  el.startBtn.disabled = running || state.selectedFiles.length === 0;
  el.addAudio.disabled = running;
  el.clearReselect.disabled = running;
  el.openSettings.disabled = running;
  renderFiles();
}

async function startBatch() {
  if (state.running) return;
  if (state.selectedFiles.length === 0) {
    updateStatus();
    return;
  }

  setRunning(true);
  el.logs.value = '';
  el.overallProgress.value = 0;
  el.progressText.textContent = '准备中 0%';

  const result = await window.desktopAPI.startBatch(state.selectedFiles, state.settings);

  if (result?.ok) {
    if (result.canceled) {
      appendLog('已取消保存');
    }
  } else {
    appendLog(`错误: ${result?.error || '未知错误'}`);
  }

  setRunning(false);
}

async function init() {
  state.settings = await window.desktopAPI.getInitialSettings();
  applySettingsToForm(state.settings);
  renderFiles();

  state.unbindLog = window.desktopAPI.onLog((line) => appendLog(line));
  state.unbindProgress = window.desktopAPI.onProgress((p) => {
    if (!p) return;
    if (typeof p.value === 'number') el.overallProgress.value = Math.max(0, Math.min(1, p.value));
    if (p.text) el.progressText.textContent = p.text;
  });

  el.addAudio.addEventListener('click', async () => {
    const files = await window.desktopAPI.pickAudioFiles();
    if (files && files.length > 0) {
      mergeFiles(files);
      appendLog(`[${new Date().toLocaleTimeString()}] 新增 ${files.length} 个文件，当前总数: ${state.selectedFiles.length}`);
    }
  });

  el.clearReselect.addEventListener('click', async () => {
    state.selectedFiles = [];
    renderFiles();
    const files = await window.desktopAPI.pickAudioFiles();
    if (files && files.length > 0) {
      mergeFiles(files);
    }
  });

  el.startBtn.addEventListener('click', startBatch);

  el.openSettings.addEventListener('click', () => {
    applySettingsToForm(state.settings);
    el.settingsDialog.showModal();
  });

  el.settingsCancel.addEventListener('click', () => {
    el.settingsDialog.close();
  });

  el.settingsSave.addEventListener('click', async () => {
    const newSettings = readSettingsFromForm();
    const saved = await window.desktopAPI.saveSettings(newSettings);
    state.settings = saved;
    applySettingsToForm(saved);
    appendLog(`[${new Date().toLocaleTimeString()}] 设置已保存到本地`);
    el.settingsDialog.close();
  });

  el.translationEnabled.addEventListener('change', () => {
    if (el.translationEnabled.checked) {
      el.translateENToZH.checked = true;
      el.translateZHToEN.checked = false;
    }
    updateTranslationSubState();
  });

  el.translateENToZH.addEventListener('change', () => {
    if (el.translateENToZH.checked) {
      el.translateZHToEN.checked = false;
    } else if (!el.translateZHToEN.checked) {
      el.translateENToZH.checked = true;
    }
  });

  el.translateZHToEN.addEventListener('change', () => {
    if (el.translateZHToEN.checked) {
      el.translateENToZH.checked = false;
    } else if (!el.translateENToZH.checked) {
      el.translateZHToEN.checked = true;
    }
  });

  window.addEventListener('beforeunload', () => {
    if (state.unbindLog) state.unbindLog();
    if (state.unbindProgress) state.unbindProgress();
  });
}

init().catch((error) => {
  appendLog(`初始化失败: ${error.message || String(error)}`);
});
