const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function defaultSettings() {
  return {
    volcAppKey: '',
    volcAccessKey: '',
    volcResourceId: 'volc.lark.minutes',

    tosRegion: 'cn-beijing',
    tosEndpoint: 'tos-cn-beijing.volces.com',
    tosBucket: '',
    tosAK: '',
    tosSK: '',
    tosStsToken: '',

    tosObjectPrefix: 'audio2txt/',
    tosSignExpiresSec: 14400,
    pollIntervalSec: 30,
    maxWaitMin: 120,
    maxConcurrentJobs: 10,
    deleteTempObject: true,
    saveRawJSON: false,

    translationEnabled: false,
    translationSourceLang: 'en_us',
    translationTargetLang: 'zh_cn',

    completionSoundEnabled: true,
  };
}

function sanitizeSettings(settings) {
  const base = defaultSettings();
  const merged = { ...base, ...(settings || {}) };

  merged.tosSignExpiresSec = Math.max(60, toInt(merged.tosSignExpiresSec, 14400));
  merged.pollIntervalSec = Math.max(1, toInt(merged.pollIntervalSec, 30));
  merged.maxWaitMin = Math.max(1, toInt(merged.maxWaitMin, 120));
  merged.maxConcurrentJobs = Math.max(1, toInt(merged.maxConcurrentJobs, 10));

  merged.deleteTempObject = !!merged.deleteTempObject;
  merged.saveRawJSON = !!merged.saveRawJSON;
  merged.translationEnabled = !!merged.translationEnabled;
  merged.completionSoundEnabled = !!merged.completionSoundEnabled;

  if (!merged.translationEnabled) {
    merged.translationSourceLang = 'en_us';
    merged.translationTargetLang = 'zh_cn';
  } else {
    const src = String(merged.translationSourceLang || '').toLowerCase();
    const dst = String(merged.translationTargetLang || '').toLowerCase();
    if (!(src === 'en_us' && dst === 'zh_cn') && !(src === 'zh_cn' && dst === 'en_us')) {
      merged.translationSourceLang = 'en_us';
      merged.translationTargetLang = 'zh_cn';
    }
  }

  for (const k of [
    'volcAppKey', 'volcAccessKey', 'volcResourceId',
    'tosRegion', 'tosEndpoint', 'tosBucket', 'tosAK', 'tosSK', 'tosStsToken',
    'tosObjectPrefix', 'translationSourceLang', 'translationTargetLang',
  ]) {
    merged[k] = String(merged[k] ?? '').trim();
  }

  return merged;
}

function loadSettingsFromDisk(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    const raw = fs.readFileSync(filePath, 'utf8');
    const obj = JSON.parse(raw);
    return obj;
  } catch {
    return null;
  }
}

function saveSettingsToDisk(filePath, settings) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(settings, null, 2), 'utf8');
}

function requireConfig(settings) {
  const required = [
    ['volcAppKey', 'VOLC_APP_KEY'],
    ['volcAccessKey', 'VOLC_ACCESS_KEY'],
    ['tosRegion', 'TOS_REGION'],
    ['tosEndpoint', 'TOS_ENDPOINT'],
    ['tosBucket', 'TOS_BUCKET'],
    ['tosAK', 'TOS_AK'],
    ['tosSK', 'TOS_SK'],
  ];
  for (const [k, label] of required) {
    if (!settings[k]) {
      throw new Error(`缺少配置项: ${label}`);
    }
  }
}

function toInt(value, fallback) {
  const n = Number.parseInt(String(value), 10);
  return Number.isFinite(n) ? n : fallback;
}

function nowTimeText() {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, '0');
  const m = String(d.getMinutes()).padStart(2, '0');
  const s = String(d.getSeconds()).padStart(2, '0');
  return `${h}:${m}:${s}`;
}

function stamp(line) {
  return `[${nowTimeText()}] ${line}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sha256Hex(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

function hmac(key, msg, encoding) {
  const h = crypto.createHmac('sha256', key).update(msg);
  return encoding ? h.digest(encoding) : h.digest();
}

function tosDateStampUTC(date) {
  return date.toISOString().slice(0, 10).replace(/-/g, '');
}

function tosTimestampUTC(date) {
  const s = date.toISOString().replace(/[-:]/g, '');
  return s.slice(0, 15) + 'Z';
}

function percentEncode(text) {
  return encodeURIComponent(text)
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function encodePath(raw) {
  return raw.split('/').map((v) => percentEncode(v)).join('/');
}

function canonicalQueryString(items) {
  return items
    .map(([k, v]) => [percentEncode(k), percentEncode(v)])
    .sort((a, b) => (a[0] === b[0] ? a[1].localeCompare(b[1]) : a[0].localeCompare(b[0])))
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
}

function normalizedEndpointHost(endpoint) {
  return String(endpoint)
    .trim()
    .replace(/^https?:\/\//i, '')
    .replace(/\/+$/, '');
}

function signingSignature(secretKey, region, dateStamp, stringToSign) {
  const kDate = hmac(Buffer.from(secretKey, 'utf8'), dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, 'tos');
  const kSigning = hmac(kService, 'request');
  return hmac(kSigning, stringToSign, 'hex');
}

async function putObject(settings, objectKey, buffer) {
  const endpoint = normalizedEndpointHost(settings.tosEndpoint);
  const host = `${settings.tosBucket}.${endpoint}`;
  const encodedKey = encodePath(objectKey);
  const url = `https://${host}/${encodedKey}`;

  const payloadHash = sha256Hex(buffer);
  const now = new Date();
  const xTosDate = tosTimestampUTC(now);
  const dateStamp = tosDateStampUTC(now);

  const signedHeaders = 'host;x-tos-content-sha256;x-tos-date';
  const canonicalHeaders = `host:${host}\n` +
    `x-tos-content-sha256:${payloadHash}\n` +
    `x-tos-date:${xTosDate}\n`;

  const canonicalRequest = [
    'PUT',
    `/${encodedKey}`,
    '',
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const algorithm = 'TOS4-HMAC-SHA256';
  const scope = `${dateStamp}/${settings.tosRegion}/tos/request`;
  const stringToSign = [algorithm, xTosDate, scope, sha256Hex(canonicalRequest)].join('\n');
  const signature = signingSignature(settings.tosSK, settings.tosRegion, dateStamp, stringToSign);
  const authorization = `${algorithm} Credential=${settings.tosAK}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const headers = {
    Host: host,
    'X-Tos-Date': xTosDate,
    'X-Tos-Content-Sha256': payloadHash,
    Authorization: authorization,
  };
  if (settings.tosStsToken) {
    headers['X-Tos-Security-Token'] = settings.tosStsToken;
  }

  const res = await fetch(url, {
    method: 'PUT',
    headers,
    body: buffer,
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`TOS PUT 失败: HTTP ${res.status}${text ? `, ${text}` : ''}`);
  }
}

async function deleteObject(settings, objectKey) {
  const endpoint = normalizedEndpointHost(settings.tosEndpoint);
  const host = `${settings.tosBucket}.${endpoint}`;
  const encodedKey = encodePath(objectKey);
  const url = `https://${host}/${encodedKey}`;

  const payloadHash = sha256Hex('');
  const now = new Date();
  const xTosDate = tosTimestampUTC(now);
  const dateStamp = tosDateStampUTC(now);

  const signedHeaders = 'host;x-tos-content-sha256;x-tos-date';
  const canonicalHeaders = `host:${host}\n` +
    `x-tos-content-sha256:${payloadHash}\n` +
    `x-tos-date:${xTosDate}\n`;

  const canonicalRequest = [
    'DELETE',
    `/${encodedKey}`,
    '',
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const algorithm = 'TOS4-HMAC-SHA256';
  const scope = `${dateStamp}/${settings.tosRegion}/tos/request`;
  const stringToSign = [algorithm, xTosDate, scope, sha256Hex(canonicalRequest)].join('\n');
  const signature = signingSignature(settings.tosSK, settings.tosRegion, dateStamp, stringToSign);
  const authorization = `${algorithm} Credential=${settings.tosAK}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const headers = {
    Host: host,
    'X-Tos-Date': xTosDate,
    'X-Tos-Content-Sha256': payloadHash,
    Authorization: authorization,
  };
  if (settings.tosStsToken) {
    headers['X-Tos-Security-Token'] = settings.tosStsToken;
  }

  const res = await fetch(url, { method: 'DELETE', headers });
  if (!res.ok) {
    throw new Error(`TOS DELETE 失败: HTTP ${res.status}`);
  }
}

function presignedURL(settings, method, objectKey, expiresSec) {
  const endpoint = normalizedEndpointHost(settings.tosEndpoint);
  const host = `${settings.tosBucket}.${endpoint}`;
  const encodedKey = encodePath(objectKey);

  const now = new Date();
  const xTosDate = tosTimestampUTC(now);
  const dateStamp = tosDateStampUTC(now);
  const scope = `${dateStamp}/${settings.tosRegion}/tos/request`;
  const algorithm = 'TOS4-HMAC-SHA256';

  const queryItems = [
    ['X-Tos-Algorithm', algorithm],
    ['X-Tos-Credential', `${settings.tosAK}/${scope}`],
    ['X-Tos-Date', xTosDate],
    ['X-Tos-Expires', String(expiresSec)],
    ['X-Tos-SignedHeaders', 'host'],
  ];
  if (settings.tosStsToken) {
    queryItems.push(['X-Tos-Security-Token', settings.tosStsToken]);
  }

  const canonicalQuery = canonicalQueryString(queryItems);
  const canonicalRequest = [
    method,
    `/${encodedKey}`,
    canonicalQuery,
    `host:${host}\n`,
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = [algorithm, xTosDate, scope, sha256Hex(canonicalRequest)].join('\n');
  const signature = signingSignature(settings.tosSK, settings.tosRegion, dateStamp, stringToSign);
  queryItems.push(['X-Tos-Signature', signature]);

  const finalQuery = canonicalQueryString(queryItems);
  return `https://${host}/${encodedKey}?${finalQuery}`;
}

function generateObjectKey(settings, fileName) {
  const prefix = settings.tosObjectPrefix.endsWith('/') ? settings.tosObjectPrefix : `${settings.tosObjectPrefix}/`;
  return `${prefix}${crypto.randomUUID().toLowerCase()}-${fileName}`;
}

async function uploadAudioToTOS(filePath, settings, logger) {
  const baseName = path.basename(filePath);
  const objectKey = generateObjectKey(settings, baseName);
  const stat = fs.statSync(filePath);
  const sizeMB = stat.size / 1024 / 1024;
  const start = Date.now();

  logger(`上传音频到 TOS: key=${objectKey}, 大小=${sizeMB.toFixed(2)}MB`);
  const buf = fs.readFileSync(filePath);
  await putObject(settings, objectKey, buf);
  const elapsed = (Date.now() - start) / 1000;
  logger(`上传完成: key=${objectKey}, 耗时=${elapsed.toFixed(1)}s`);

  const signedGetURL = presignedURL(settings, 'GET', objectKey, settings.tosSignExpiresSec);
  return { key: objectKey, signedGetURL };
}

function buildVolcHeaders(settings, requestID, includeSequence = true) {
  const headers = {
    'Content-Type': 'application/json',
    'X-Api-App-Key': settings.volcAppKey,
    'X-Api-Access-Key': settings.volcAccessKey,
    'X-Api-Resource-Id': settings.volcResourceId,
    'X-Api-Request-Id': requestID,
  };
  if (includeSequence) {
    headers['X-Api-Sequence'] = '-1';
  }
  return headers;
}

function parseNumericPercent(raw) {
  if (raw === undefined || raw === null) return null;
  let value = null;
  if (typeof raw === 'number') value = raw;
  if (typeof raw === 'string') value = Number.parseFloat(raw.replace('%', '').trim());
  if (!Number.isFinite(value)) return null;
  if (value <= 1.0) return Math.max(0, Math.min(100, value * 100));
  return Math.max(0, Math.min(100, value));
}

function extractTaskID(json) {
  const data = json?.Data || json?.data || {};
  const keys = ['TaskID', 'TaskId', 'task_id', 'taskId'];
  for (const k of keys) {
    if (typeof data[k] === 'string' && data[k].trim()) return data[k].trim();
    if (typeof data[k] === 'number') return String(data[k]);
  }
  for (const k of keys) {
    if (typeof json[k] === 'string' && json[k].trim()) return json[k].trim();
    if (typeof json[k] === 'number') return String(json[k]);
  }
  return null;
}

function isSubmitQPSLimited(message) {
  const m = String(message || '').toLowerCase();
  return m.includes('45000292') || m.includes('quota exceeded for types: qps') || m.includes('qps');
}

async function submitTask(settings, signedFileURL, requestID) {
  const url = 'https://openspeech.bytedance.com/api/v3/auc/lark/submit';
  const body = {
    Input: {
      Offline: {
        FileURL: signedFileURL,
        FileType: 'audio',
      },
    },
    Params: {
      AllActivate: false,
      SourceLang: settings.translationEnabled ? settings.translationSourceLang : 'zh_cn',
      AudioTranscriptionEnable: true,
      AudioTranscriptionParams: {
        SpeakerIdentification: true,
        NumberOfSpeaker: 0,
        HotWords: '',
        NeedWordTimeSeries: false,
      },
      SummarizationEnabled: true,
      SummarizationParams: {
        Types: ['summary'],
      },
      TranslationEnable: settings.translationEnabled,
      TranslationParams: {
        TargetLang: settings.translationTargetLang,
      },
      InformationExtractionEnabled: false,
      ChapterEnabled: false,
    },
  };

  const res = await fetch(url, {
    method: 'POST',
    headers: buildVolcHeaders(settings, requestID, true),
    body: JSON.stringify(body),
  });

  const text = await res.text();
  if (!res.ok) {
    throw new Error(`submit HTTP ${res.status}: ${text}`);
  }

  let json = {};
  try { json = JSON.parse(text); } catch {}

  const statusHeader = res.headers.get('X-Api-Status-Code') || '';
  const messageHeader = res.headers.get('X-Api-Message') || '';
  if (statusHeader && statusHeader !== '20000000' && statusHeader !== '0') {
    const bodyMsg = json?.Message || json?.message || '';
    const finalMessage = [messageHeader, bodyMsg].map((v) => String(v).trim()).filter(Boolean).join(' | ');
    throw new Error(`submit 业务失败(${statusHeader}): ${finalMessage}`);
  }

  const taskID = extractTaskID(json);
  if (!taskID) {
    throw new Error(`submit 返回中缺少 TaskID，响应片段: ${text.slice(0, 600).replace(/\n/g, ' ')}`);
  }
  return taskID;
}

async function submitWithRetry(settings, signedFileURL, requestID, logger) {
  let backoff = 4000;
  const maxAttempts = 6;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await submitTask(settings, signedFileURL, requestID);
    } catch (error) {
      const msg = error?.message || String(error);
      if (attempt < maxAttempts && isSubmitQPSLimited(msg)) {
        const waitSec = Math.floor(backoff / 1000) + randInt(0, 3);
        logger(`提交触发 QPS 限流，${waitSec}s 后重试（${attempt}/${maxAttempts}）`);
        await sleep(waitSec * 1000);
        backoff = Math.min(backoff * 2, 45000);
        continue;
      }
      throw error;
    }
  }
  throw new Error('submit 重试次数耗尽');
}

function isHTTP429(err) {
  const m = String(err?.message || err || '').toLowerCase();
  return m.includes('http 429') || m.includes(' 429');
}

async function queryTask(settings, taskID) {
  const url = 'https://openspeech.bytedance.com/api/v3/auc/lark/query';
  const body = { TaskID: taskID };
  const res = await fetch(url, {
    method: 'POST',
    headers: buildVolcHeaders(settings, taskID, true),
    body: JSON.stringify(body),
  });

  const text = await res.text();
  if (!res.ok) {
    throw new Error(`query HTTP ${res.status}: ${text}`);
  }

  let json = {};
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error('query 响应解析失败');
  }

  const data = json?.Data || {};
  const statusRaw = String(data?.Status || '').toLowerCase();
  const status = ['running', 'success', 'failed'].includes(statusRaw) ? statusRaw : 'unknown';

  const keys = ['Progress', 'progress', 'Process', 'process', 'Percent', 'percent'];
  let progressPercent = null;
  for (const k of keys) {
    progressPercent = parseNumericPercent(data?.[k]);
    if (progressPercent !== null) break;
  }
  if (progressPercent === null && data?.Result) {
    for (const k of keys) {
      progressPercent = parseNumericPercent(data.Result?.[k]);
      if (progressPercent !== null) break;
    }
  }

  const result = data?.Result || {};
  return {
    status,
    errCode: data?.ErrCode,
    errMessage: data?.ErrMessage,
    progressPercent,
    transcriptionFileURL: result?.AudioTranscriptionFile || null,
    summarizationFileURL: result?.SummarizationFile || null,
    translationFileURL: result?.TranslationFile || null,
  };
}

async function downloadURL(url) {
  const res = await fetch(url);
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`下载失败: HTTP ${res.status}${text ? `, ${text}` : ''}`);
  }
  const arr = await res.arrayBuffer();
  return Buffer.from(arr);
}

function parseSegment(dict) {
  const textKeys = ['text', 'Text', 'content', 'Content', 'sentence', 'Sentence', 'sentence_text', 'SentenceText', 'transcript', 'Transcript', 'utterance', 'Utterance', 'value', 'Value'];
  let text = null;
  for (const k of textKeys) {
    if (typeof dict[k] === 'string' && dict[k].trim()) {
      text = dict[k].trim();
      break;
    }
  }
  if (!text) return null;

  const startMs = detectTimeMs(dict, ['start_ms', 'StartMs', 'startMs', 'start_time_ms', 'StartTimeMs', 'start_time', 'StartTime', 'start', 'Start', 'begin_time', 'beginTime', 'BeginTime', 'offset', 'Offset', 'timestamp', 'Timestamp']);
  if (startMs === null) return null;

  const endMs = detectTimeMs(dict, ['end_ms', 'EndMs', 'endMs', 'end_time_ms', 'EndTimeMs', 'end_time', 'EndTime', 'end', 'End', 'stop', 'Stop', 'finish_time', 'FinishTime']);

  return {
    startMs,
    endMs,
    speaker: detectSpeaker(dict),
    text,
  };
}

function detectSpeaker(dict) {
  const obj = dict.speaker || dict.Speaker;
  if (obj && typeof obj === 'object') {
    if (typeof obj.name === 'string' && obj.name.trim()) return obj.name.trim();
    if (typeof obj.id === 'string' && obj.id.trim()) return `SPK_${obj.id.trim()}`;
    if (typeof obj.id === 'number') return `SPK_${obj.id}`;
  }

  for (const k of ['speaker', 'Speaker', 'speaker_id', 'speakerId', 'SpeakerId', 'speaker_label', 'speakerLabel', 'SpeakerLabel']) {
    const v = dict[k];
    if (typeof v === 'string' && v.trim()) return v.trim();
    if (typeof v === 'number') return `SPK_${v}`;
  }
  return null;
}

function detectTimeMs(dict, keys) {
  for (const k of keys) {
    const v = numberToMs(dict[k], k);
    if (v !== null) return v;
  }
  return null;
}

function numberToMs(value, key) {
  if (value === undefined || value === null) return null;
  let n = null;
  if (typeof value === 'number') n = value;
  if (typeof value === 'string') n = Number.parseFloat(value);
  if (!Number.isFinite(n)) return null;

  const lowerKey = String(key).toLowerCase();
  if (lowerKey.includes('ms')) return Math.round(n);
  if (lowerKey === 'start_time' || lowerKey === 'end_time' || lowerKey === 'starttime' || lowerKey === 'endtime') {
    if (n >= 1000) return Math.round(n);
    return Math.round(n * 1000);
  }
  if (n > 100000) return Math.round(n);
  return Math.round(n * 1000);
}

function extractAllSegments(node, out) {
  if (Array.isArray(node)) {
    for (const item of node) {
      if (item && typeof item === 'object' && !Array.isArray(item)) {
        const seg = parseSegment(item);
        if (seg) out.push(seg);
      }
      extractAllSegments(item, out);
    }
    return;
  }

  if (node && typeof node === 'object') {
    for (const v of Object.values(node)) {
      extractAllSegments(v, out);
    }
  }
}

function dedupSegments(segments) {
  const seen = new Set();
  const out = [];
  for (const seg of segments) {
    const key = `${seg.startMs}|${seg.speaker || ''}|${seg.text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(seg);
  }
  return out;
}

function formatReadableTime(ms) {
  const sec = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h > 0) return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function endsStop(text) {
  if (!text) return false;
  return /[。！？.!?]$/.test(text);
}

function joinText(left, right) {
  if (!left) return right;
  if (!right) return left;
  const last = left[left.length - 1];
  const first = right[0];
  if (/[A-Za-z0-9]/.test(last) && /[A-Za-z0-9]/.test(first)) return `${left} ${right}`;
  return left + right;
}

function renderTranscriptFromJSON(buffer) {
  let obj;
  try {
    obj = JSON.parse(buffer.toString('utf8'));
  } catch {
    return `# 转写结果不是合法 JSON，原始内容如下\n\n${buffer.toString('utf8')}`;
  }

  const collected = [];
  extractAllSegments(obj, collected);
  let segments = dedupSegments(collected)
    .filter((v) => typeof v.startMs === 'number' && Number.isFinite(v.startMs) && v.text)
    .sort((a, b) => a.startMs - b.startMs || b.text.length - a.text.length);

  if (segments.length === 0) {
    return `# 未识别到标准句段，以下为原始结果 JSON\n\n${JSON.stringify(obj, null, 2)}`;
  }

  const speakers = new Set(segments.map((v) => v.speaker).filter(Boolean));
  const showSpeaker = speakers.size > 1;

  const paragraphs = [];
  let cur = null;
  let prevStart = null;

  for (const seg of segments) {
    const txt = String(seg.text || '').trim();
    if (!txt) continue;

    if (!cur) {
      cur = { startMs: seg.startMs, speaker: seg.speaker, text: txt };
      prevStart = seg.startMs;
      continue;
    }

    const gap = prevStart === null ? 0 : seg.startMs - prevStart;
    const span = seg.startMs - cur.startMs;
    const speakerChanged = showSpeaker && cur.speaker !== seg.speaker;
    const shouldBreak = speakerChanged || span >= 35000 || (gap >= 12000 && cur.text.length >= 48) || (cur.text.length >= 220 && endsStop(cur.text));

    if (shouldBreak) {
      paragraphs.push(cur);
      cur = { startMs: seg.startMs, speaker: seg.speaker, text: txt };
      prevStart = seg.startMs;
      continue;
    }

    cur.text = joinText(cur.text, txt);
    prevStart = seg.startMs;
  }

  if (cur) paragraphs.push(cur);

  return paragraphs
    .map((p) => {
      const sp = showSpeaker ? `[${p.speaker || 'SPK'}] ` : '';
      return `${formatReadableTime(p.startMs)}\n${sp}${p.text}`;
    })
    .join('\n\n');
}

function extractSummaryContent(buffer) {
  let obj = null;
  try {
    obj = JSON.parse(buffer.toString('utf8'));
  } catch {
    const text = buffer.toString('utf8').trim();
    if (text.length >= 12) return { summaryText: text, keywords: [] };
    return { summaryText: null, keywords: [] };
  }

  const keywordCandidates = [];
  const summaryCandidates = [];
  const generic = [];

  function splitKeywords(text) {
    return String(text)
      .split(/[,，;；、|/\n\t]/g)
      .map((v) => v.trim())
      .filter(Boolean);
  }

  function walk(node, parentKey = null) {
    if (Array.isArray(node)) {
      for (const item of node) walk(item, parentKey);
      return;
    }
    if (node && typeof node === 'object') {
      for (const [k, v] of Object.entries(node)) {
        const lower = k.toLowerCase();
        if (lower.includes('keyword') || k.includes('关键词')) {
          if (typeof v === 'string') keywordCandidates.push(...splitKeywords(v));
          if (Array.isArray(v)) {
            for (const it of v) {
              if (typeof it === 'string') keywordCandidates.push(...splitKeywords(it));
              if (it && typeof it === 'object') {
                for (const sub of ['keyword', 'Keyword', 'text', 'Text', 'word', 'Word', 'name', 'Name', 'value', 'Value']) {
                  if (typeof it[sub] === 'string') {
                    keywordCandidates.push(...splitKeywords(it[sub]));
                    break;
                  }
                }
              }
            }
          }
        }

        if (lower.includes('summary') || k.includes('总结') || k.includes('摘要')) {
          if (typeof v === 'string' && v.trim().length >= 12) summaryCandidates.push(v.trim());
          if (Array.isArray(v)) {
            for (const it of v) {
              if (typeof it === 'string' && it.trim().length >= 12) summaryCandidates.push(it.trim());
              if (it && typeof it === 'object') {
                for (const sub of ['summary', 'Summary', 'text', 'Text', 'content', 'Content', 'value', 'Value']) {
                  if (typeof it[sub] === 'string' && it[sub].trim().length >= 12) {
                    summaryCandidates.push(it[sub].trim());
                    break;
                  }
                }
              }
            }
          }
        }

        walk(v, k);
      }
      return;
    }

    if (typeof node === 'string') {
      const t = node.trim();
      if (t.length >= 20) generic.push(t);
      if (parentKey && String(parentKey).toLowerCase().includes('keyword')) {
        keywordCandidates.push(...splitKeywords(t));
      }
      if (parentKey && (String(parentKey).toLowerCase().includes('summary') || String(parentKey).includes('总结') || String(parentKey).includes('摘要'))) {
        if (t.length >= 12) summaryCandidates.push(t);
      }
    }
  }

  walk(obj, null);

  const seen = new Set();
  const keywords = [];
  for (const kw of keywordCandidates) {
    const t = kw.trim();
    if (!t || t.length > 24) continue;
    const key = t.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    keywords.push(t);
    if (keywords.length >= 20) break;
  }

  const summaryPool = [...summaryCandidates, ...generic].map((v) => v.trim()).filter((v) => v.length >= 12);
  const summaryText = summaryPool.sort((a, b) => b.length - a.length)[0] || null;

  return { summaryText, keywords };
}

function renderTranslation(buffer) {
  let obj = null;
  try {
    obj = JSON.parse(buffer.toString('utf8'));
  } catch {
    const t = buffer.toString('utf8').trim();
    return t || null;
  }

  const lines = [];

  function parseLine(dict) {
    const textKeys = ['translation_content', 'TranslationContent', 'translationContent', 'translation', 'Translation', 'text', 'Text', 'content', 'Content', 'sentence', 'Sentence', 'value', 'Value'];
    let text = null;
    for (const k of textKeys) {
      if (typeof dict[k] === 'string' && dict[k].trim()) {
        text = dict[k].trim();
        break;
      }
    }
    if (!text) return null;
    const startMs = detectTimeMs(dict, ['start_ms', 'StartMs', 'startMs', 'start_time_ms', 'StartTimeMs', 'start_time', 'StartTime', 'start', 'Start', 'offset', 'Offset', 'timestamp', 'Timestamp']);
    if (startMs === null) return null;
    return { startMs, text };
  }

  function walk(node) {
    if (Array.isArray(node)) {
      for (const item of node) walk(item);
      return;
    }
    if (node && typeof node === 'object') {
      const line = parseLine(node);
      if (line) lines.push(line);
      for (const v of Object.values(node)) walk(v);
    }
  }

  walk(obj);

  const seen = new Set();
  const out = [];
  for (const line of lines.sort((a, b) => a.startMs - b.startMs)) {
    const key = `${line.startMs}|${line.text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(`${formatReadableTime(line.startMs)}\n${line.text}`);
  }

  if (out.length > 0) return out.join('\n\n');
  const fallback = JSON.stringify(obj);
  return fallback || null;
}

function extractDurationMsFromTranscript(text) {
  if (!text) return null;
  const regex = /^(\d{2}):(\d{2})(?::(\d{2}))?$/gm;
  let maxSec = 0;
  let m;
  while ((m = regex.exec(text)) !== null) {
    const mm = Number.parseInt(m[2], 10);
    const hh = m[3] ? Number.parseInt(m[1], 10) : 0;
    const ss = m[3] ? Number.parseInt(m[2], 10) : Number.parseInt(m[2], 10);
    const realSec = m[3] ? hh * 3600 + ss * 60 + Number.parseInt(m[3], 10) : Number.parseInt(m[1], 10) * 60 + mm;
    if (Number.isFinite(realSec)) maxSec = Math.max(maxSec, realSec);
  }
  if (maxSec <= 0) return null;
  return maxSec * 1000;
}

function formatHeaderDate(date) {
  const y = date.getFullYear();
  const m = date.getMonth() + 1;
  const d = date.getDate();
  const hour = date.getHours();
  const minute = String(date.getMinutes()).padStart(2, '0');
  const period = hour >= 12 ? '下午' : '上午';
  const h12 = hour % 12 === 0 ? 12 : hour % 12;
  return `${y}年${m}月${d}日 ${period} ${h12}:${minute}`;
}

function formatDuration(ms) {
  if (!ms || ms <= 0) return '未知时长';
  const sec = Math.round(ms / 1000);
  const min = Math.floor(sec / 60);
  const remain = sec % 60;
  if (min === 0) return `${remain}秒`;
  if (remain === 0) return `${min}分钟`;
  return `${min}分钟${remain}秒`;
}

function formatOutputText(result) {
  const now = new Date();
  const durationMs = result.audioDurationMs || extractDurationMsFromTranscript(result.text);

  const blocks = [`${formatHeaderDate(now)}|${formatDuration(durationMs)}`];

  if (result.summaryText) {
    blocks.push(`全文总结:\n${result.summaryText}`);
  }
  if (Array.isArray(result.summaryKeywords) && result.summaryKeywords.length > 0) {
    blocks.push(`关键词:\n${result.summaryKeywords.join('、')}`);
  }

  blocks.push(`文字记录:\n${result.text}`);

  if (result.translationText) {
    blocks.push(`翻译结果:\n${result.translationText}`);
  }

  return blocks.join('\n\n');
}

function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

async function transcribeOne(filePath, settings, logger, progress) {
  const name = path.basename(filePath);
  const log = (msg) => logger(stamp(`[${name}] ${msg}`));

  progress(0.02);
  log('开始任务');

  const uploaded = await uploadAudioToTOS(filePath, settings, log);
  progress(0.18);
  log('音频上传完成，已生成临时可访问 URL');

  const requestID = crypto.randomUUID().toLowerCase();
  log('提交妙记任务');
  const taskID = await submitWithRetry(settings, uploaded.signedGetURL, requestID, log);
  progress(0.25);
  log(`任务已提交，TaskID=${taskID}`);

  const deadline = Date.now() + settings.maxWaitMin * 60 * 1000;
  let finalQuery = null;
  let rateBackoffSec = Math.max(settings.pollIntervalSec, 5);

  while (Date.now() < deadline) {
    let query;
    try {
      query = await queryTask(settings, taskID);
      rateBackoffSec = Math.max(settings.pollIntervalSec, 5);
    } catch (error) {
      if (isHTTP429(error)) {
        rateBackoffSec = Math.min(rateBackoffSec * 2, 180);
        const waitSec = rateBackoffSec + randInt(0, 6);
        log(`查询触发限流(429)，${waitSec}s 后重试`);
        await sleep(waitSec * 1000);
        continue;
      }
      throw error;
    }

    finalQuery = query;

    if (query.status === 'success') {
      progress(0.96);
      log('任务完成 ✅ ，开始下载结果 ⏬');

      if (!query.transcriptionFileURL) {
        throw new Error('任务成功但缺少 AudioTranscriptionFile');
      }

      const rawJSONBuffer = await downloadURL(query.transcriptionFileURL);
      const text = renderTranscriptFromJSON(rawJSONBuffer);

      let summaryText = null;
      let summaryKeywords = [];
      let translationText = null;

      if (query.summarizationFileURL) {
        try {
          const summaryBuf = await downloadURL(query.summarizationFileURL);
          const summary = extractSummaryContent(summaryBuf);
          summaryText = summary.summaryText;
          summaryKeywords = summary.keywords;

          if (summaryText) {
            log('全文总结提取成功');
          } else if (summaryKeywords.length > 0) {
            log(`全文总结未命中正文，关键词提取成功: ${summaryKeywords.length} 个`);
          } else {
            log('全文总结已返回，但未提取到正文/关键词');
          }
        } catch (error) {
          log(`全文总结下载/解析失败(已忽略): ${error.message || String(error)}`);
        }
      }

      if (settings.translationEnabled && query.translationFileURL) {
        try {
          const translationBuf = await downloadURL(query.translationFileURL);
          translationText = renderTranslation(translationBuf);
          if (translationText) {
            log('翻译结果提取成功');
          } else {
            log('翻译结果已返回，但未提取到有效文本');
          }
        } catch (error) {
          log(`翻译结果下载/解析失败(已忽略): ${error.message || String(error)}`);
        }
      }

      if (settings.deleteTempObject) {
        try {
          await deleteObject(settings, uploaded.key);
          log(`已删除 TOS 临时音频: ${uploaded.key}`);
        } catch (error) {
          log(`删除 TOS 临时音频失败(已忽略): ${error.message || String(error)}`);
        }
      }

      progress(1);
      return {
        taskID,
        tosObjectKey: uploaded.key,
        rawJSONBuffer,
        text,
        summaryText,
        summaryKeywords,
        translationText,
        audioDurationMs: null,
      };
    }

    if (query.status === 'failed') {
      if (settings.deleteTempObject) {
        try {
          await deleteObject(settings, uploaded.key);
          log(`已删除 TOS 临时音频: ${uploaded.key}`);
        } catch {}
      }
      throw new Error(`妙记任务失败: ${query.errMessage || '未知错误'}`);
    }

    if (query.progressPercent !== null && query.progressPercent !== undefined) {
      const p = Math.max(0, Math.min(100, Number(query.progressPercent)));
      const normalized = 0.25 + (p / 100) * 0.7;
      progress(normalized);
      const waitSec = settings.pollIntervalSec + randInt(0, 4);
      log(`任务进行中，进度约 ${Math.round(p)}%，${waitSec}s 后重试`);
      await sleep(waitSec * 1000);
    } else {
      progress(0.30);
      const waitSec = settings.pollIntervalSec + randInt(0, 4);
      log(`任务进行中，${waitSec}s 后重试`);
      await sleep(waitSec * 1000);
    }
  }

  if (settings.deleteTempObject) {
    try {
      await deleteObject(settings, uploaded.key);
      log(`已删除 TOS 临时音频: ${uploaded.key}`);
    } catch {}
  }

  throw new Error(`超时: ${finalQuery?.errMessage || '超时未完成'}`);
}

async function transcribeBatch(files, settingsInput, logger, progressCb) {
  const settings = sanitizeSettings(settingsInput);
  requireConfig(settings);

  const filePaths = [...new Set(files.map((v) => path.resolve(v)))];
  if (filePaths.length === 0) {
    throw new Error('请先选择音频文件');
  }

  logger(stamp('开始执行上传 -> 提交 -> 轮询 -> 下载流程'));
  logger(stamp(`并发任务数: ${Math.min(settings.maxConcurrentJobs, filePaths.length)}`));

  const fileProgress = new Map(filePaths.map((f) => [f, 0]));

  function recomputeOverall() {
    let total = 0;
    for (const fp of filePaths) total += fileProgress.get(fp) || 0;
    const value = total / filePaths.length;
    const percent = Math.round(value * 100);
    progressCb(value, `转写进度 ${percent}%`);
  }

  const limit = Math.max(1, Math.min(settings.maxConcurrentJobs, filePaths.length));
  const results = {};
  let cursor = 0;

  async function worker() {
    while (true) {
      const idx = cursor;
      cursor += 1;
      if (idx >= filePaths.length) return;
      const f = filePaths[idx];
      const setFileProgress = (v) => {
        const old = fileProgress.get(f) || 0;
        fileProgress.set(f, Math.max(old, Math.max(0, Math.min(1, v))));
        recomputeOverall();
      };
      const result = await transcribeOne(f, settings, logger, setFileProgress);
      setFileProgress(1);
      results[f] = result;
    }
  }

  const workers = [];
  for (let i = 0; i < limit; i += 1) workers.push(worker());
  await Promise.all(workers);

  return results;
}

module.exports = {
  defaultSettings,
  sanitizeSettings,
  loadSettingsFromDisk,
  saveSettingsToDisk,
  transcribeBatch,
  formatOutputText,
};
