import crypto from 'crypto';
import fs from 'fs/promises';
import path from 'path';

import axios from 'axios';
import FormData from 'form-data';
import mime from 'mime-types';
import sharp from 'sharp';

const DEFAULT_UPLOAD_HOST = 'upload-z2.qiniup.com';

export async function loadConfig(configPath) {
  const txt = await fs.readFile(configPath, 'utf8');
  return JSON.parse(txt);
}

function isUrl(s) {
  return s.startsWith('http://') || s.startsWith('https://');
}

async function readInputBytes(pathOrUrl, timeoutMs = 60000) {
  if (isUrl(pathOrUrl)) {
    const resp = await axios.get(pathOrUrl, {
      responseType: 'arraybuffer',
      timeout: timeoutMs,
      validateStatus: () => true,
    });
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`download failed: ${resp.status} ${typeof resp.data === 'string' ? resp.data : ''}`);
    }
    const contentType = resp.headers?.['content-type'];
    const name = path.basename(new URL(pathOrUrl).pathname) || 'image';
    return { bytes: Buffer.from(resp.data), name, contentType };
  }

  const bytes = await fs.readFile(pathOrUrl);
  const name = path.basename(pathOrUrl);
  const contentType = mime.lookup(name) || undefined;
  return { bytes, name, contentType };
}

async function toWebp(bytes, quality) {
  const q = Number.isFinite(quality) ? quality : 95;
  return sharp(bytes)
    .flatten({ background: { r: 255, g: 255, b: 255 } })
    .webp({ quality: Math.max(0, Math.min(100, q)) })
    .toBuffer();
}

function md5Hex(bytes) {
  return crypto.createHash('md5').update(bytes).digest('hex');
}

export async function getQiniuUploadToken(userToken, qiniuTokenUrl, timeoutMs = 60000) {
  const resp = await axios.get(qiniuTokenUrl, {
    headers: { token: userToken, 'Content-Type': 'application/json' },
    timeout: timeoutMs,
    validateStatus: () => true,
  });
  if (resp.status < 200 || resp.status >= 300) {
    throw new Error(`qiniu-token http error: ${resp.status} ${JSON.stringify(resp.data)}`);
  }
  const payload = resp.data;
  if (!payload || Number(payload.code) !== 1) {
    throw new Error(`qiniu-token api error: ${JSON.stringify(payload)}`);
  }
  const utoken = payload?.data?.token;
  if (!utoken) {
    throw new Error(`qiniu-token missing token: ${JSON.stringify(payload)}`);
  }
  return utoken;
}

export async function queryUploadHost(uploadToken, bucket, timeoutMs = 60000) {
  const ak = String(uploadToken).split(':')[0];
  const url = `https://api.qiniu.com/v4/query?ak=${encodeURIComponent(ak)}&bucket=${encodeURIComponent(bucket)}`;
  try {
    const resp = await axios.get(url, {
      timeout: timeoutMs,
      validateStatus: () => true,
    });
    if (resp.status < 200 || resp.status >= 300) return DEFAULT_UPLOAD_HOST;
    const payload = resp.data;
    const hosts = payload?.hosts;
    const domain = hosts?.[0]?.up?.domains?.[0];
    if (!domain) return DEFAULT_UPLOAD_HOST;
    return String(domain).replace(/^https?:\/\//i, '').split('/')[0] || DEFAULT_UPLOAD_HOST;
  } catch {
    return DEFAULT_UPLOAD_HOST;
  }
}

export async function uploadImage({
  pathOrUrl,
  userToken,
  enableWebp,
  webpQuality,
  bucket,
  qiniuTokenUrl,
  timeoutMs = 120000,
}) {
  const { bytes: originalBytes, name: originalName, contentType: originalContentType } = await readInputBytes(pathOrUrl, timeoutMs);

  let uploadBytes;
  let mimeType;
  let extension;

  if (enableWebp) {
    uploadBytes = await toWebp(originalBytes, webpQuality);
    mimeType = 'image/webp';
    extension = 'webp';
  } else {
    uploadBytes = originalBytes;
    mimeType = originalContentType || 'application/octet-stream';
    const ext = path.extname(originalName).replace(/^\./, '');
    extension = ext || (mime.extension(mimeType) || 'bin');
  }

  const key = `${md5Hex(uploadBytes)}.${extension}`;

  const utoken = await getQiniuUploadToken(userToken, qiniuTokenUrl, timeoutMs);
  const host = await queryUploadHost(utoken, bucket, timeoutMs);
  const uploadUrl = `https://${host}`;

  const form = new FormData();
  form.append('token', utoken);
  form.append('key', key);
  form.append('file', uploadBytes, { filename: key, contentType: mimeType });

  const resp = await axios.post(uploadUrl, form, {
    headers: {
      ...form.getHeaders(),
      'user-agent': 'QiniuDart',
      'accept-encoding': 'gzip',
    },
    timeout: timeoutMs,
    maxBodyLength: Infinity,
    maxContentLength: Infinity,
    validateStatus: () => true,
  });

  if (resp.status < 200 || resp.status >= 300) {
    throw new Error(`qiniu upload failed: ${resp.status} ${typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data)}`);
  }

  return {
    key: resp.data?.key ?? '',
    hash: resp.data?.hash ?? '',
    fsize: resp.data?.fsize ?? 0,
    raw: resp.data,
  };
}
