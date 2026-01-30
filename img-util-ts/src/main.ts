import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import readline from 'node:readline';

import axios from 'axios';
import FormData from 'form-data';
import mime from 'mime-types';

const DEFAULT_UPLOAD_HOST = 'upload-z2.qiniup.com';

function debugEnabled(): boolean {
  const v = process.env.IMGUTIL_DEBUG;
  return !!v && v !== '0';
}

function debugLog(msg: string): void {
  if (debugEnabled()) {
    console.error(`[debug] ${msg}`);
  }
}

type Config = {
  user_token: string;
  enable_webp: boolean;
  webp_quality: number;
  bucket: string;
  qiniu_token_url: string;
};

function normalizeInput(s: string): string {
  let t = s.trim();
  while (t.endsWith('+')) t = t.slice(0, -1).trimEnd();
  if (t.length >= 2) {
    const a = t[0];
    const b = t[t.length - 1];
    if ((a === '"' && b === '"') || (a === "'" && b === "'")) {
      t = t.slice(1, -1);
    }
  }
  return t;
}

function isUrl(s: string): boolean {
  return s.startsWith('http://') || s.startsWith('https://');
}

function readConfig(): Config {
  const cfgPath = path.join(process.cwd(), 'config.json');
  if (!fs.existsSync(cfgPath)) {
    throw new Error('找不到config.json，请在同目录创建');
  }
  const raw = fs.readFileSync(cfgPath, 'utf8');
  const obj = JSON.parse(raw) as Partial<Config>;
  return {
    user_token: obj.user_token ?? '',
    enable_webp: obj.enable_webp ?? false,
    webp_quality: obj.webp_quality ?? 95,
    bucket: obj.bucket ?? 'chat68',
    qiniu_token_url: obj.qiniu_token_url ?? 'https://chat-go.jwzhd.com/v1/misc/qiniu-token',
  };
}

async function promptInput(): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ans = await new Promise<string>((resolve) => rl.question('请输入图片地址(本地路径或URL): ', resolve));
  rl.close();
  return ans;
}

async function downloadBytes(url: string): Promise<Buffer> {
  const resp = await axios.get<ArrayBuffer>(url, {
    responseType: 'arraybuffer',
    timeout: 60000,
    maxRedirects: 5,
  });
  return Buffer.from(resp.data);
}

function runCwebp(inputBytes: Buffer, quality: number): Buffer {
  const q = quality <= 0 || quality > 100 ? 95 : quality;
  const tmpDir = os.tmpdir();
  const t = Date.now().toString();
  const inPath = path.join(tmpDir, `imgutil_${t}.input`);
  const outPath = path.join(tmpDir, `imgutil_${t}.webp`);

  fs.writeFileSync(inPath, inputBytes);

  const r = spawnSync('cwebp', ['-q', String(q), inPath, '-o', outPath], {
    stdio: 'pipe',
    windowsHide: true,
  });

  try { fs.unlinkSync(inPath); } catch {}

  if (r.status !== 0 || !fs.existsSync(outPath)) {
    try { fs.unlinkSync(outPath); } catch {}
    throw new Error('上传失败: cwebp failed (install cwebp or set enable_webp=false)');
  }

  const out = fs.readFileSync(outPath);
  try { fs.unlinkSync(outPath); } catch {}
  return out;
}

function md5Hex(bytes: Buffer): string {
  return crypto.createHash('md5').update(bytes).digest('hex');
}

async function getQiniuUploadToken(userToken: string, tokenUrl: string): Promise<string> {
  try {
    const resp = await axios.get(tokenUrl, {
      headers: {
        token: userToken,
        'Content-Type': 'application/json',
      },
      timeout: 60000,
      validateStatus: () => true,
    });

    debugLog(`qiniu-token status=${resp.status}`);
    if (debugEnabled()) {
      const bodyStr = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
      debugLog(`qiniu-token body=${bodyStr}`);
    }

    if (resp.status < 200 || resp.status >= 300) return '';

    const data = resp.data;
    if (!data || typeof data !== 'object') return '';
    if ((data as any).code !== 1) return '';

    const token1 = (data as any)?.data?.token;
    if (typeof token1 === 'string' && token1.length > 0) return token1;

    const token2 = (data as any)?.token;
    if (typeof token2 === 'string' && token2.length > 0) return token2;

    return '';
  } catch (e: any) {
    debugLog(`qiniu-token request failed: ${String(e?.message ?? e)}`);
    return '';
  }
}

async function queryUploadHost(uploadToken: string, bucket: string): Promise<string> {
  const ak = uploadToken.split(':', 1)[0] ?? uploadToken;
  const url = `https://api.qiniu.com/v4/query?ak=${encodeURIComponent(ak)}&bucket=${encodeURIComponent(bucket)}`;
  try {
    const resp = await axios.get(url, { timeout: 60000 });
    const data = resp.data;
    const domains = (data as any)?.domains;
    if (Array.isArray(domains) && typeof domains[0] === 'string' && domains[0].length > 0) {
      let host = domains[0] as string;
      host = host.replace(/^https?:\/\//, '');
      host = host.replace(/\/.*$/, '');
      if (host.length > 0) return host;
    }
    return DEFAULT_UPLOAD_HOST;
  } catch {
    return DEFAULT_UPLOAD_HOST;
  }
}

async function uploadOnce(uploadUrl: string, uploadToken: string, key: string, bytes: Buffer, mimeType: string): Promise<{ status: number; body: string }> {
  const form = new FormData();
  form.append('token', uploadToken);
  form.append('key', key);
  form.append('file', bytes, { filename: key, contentType: mimeType });

  const resp = await axios.post(uploadUrl, form, {
    headers: {
      ...form.getHeaders(),
      'User-Agent': 'QiniuDart',
    },
    timeout: 120000,
    maxBodyLength: Infinity,
    maxContentLength: Infinity,
    validateStatus: () => true,
  });

  return { status: resp.status, body: typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data) };
}

function prettyPrintJson(raw: string): void {
  try {
    const obj = JSON.parse(raw);
    console.log(JSON.stringify(obj, null, 2));
  } catch {
    console.log(raw);
  }
}

async function main(): Promise<void> {
  const cfg = readConfig();
  if (!cfg.user_token) throw new Error('config.json里的 user_token 为空');

  const arg1 = process.argv.slice(2).join(' ');
  const inputRaw = arg1.length > 0 ? arg1 : await promptInput();
  const input = normalizeInput(inputRaw);
  if (!input) throw new Error('未输入图片地址');

  let origBytes: Buffer;
  let name: string;

  if (isUrl(input)) {
    origBytes = await downloadBytes(input);
    try {
      name = new URL(input).pathname.split('/').pop() || 'image';
    } catch {
      name = 'image';
    }
  } else {
    if (!fs.existsSync(input)) throw new Error('上传失败: could not read file');
    origBytes = fs.readFileSync(input);
    name = path.basename(input);
  }

  let uploadBytes = origBytes;
  let mimeType = 'application/octet-stream';
  let ext = 'bin';

  if (cfg.enable_webp) {
    uploadBytes = runCwebp(origBytes, cfg.webp_quality);
    mimeType = 'image/webp';
    ext = 'webp';
  } else {
    const m = mime.lookup(name);
    if (typeof m === 'string') mimeType = m;
    const dot = name.lastIndexOf('.');
    if (dot >= 0 && dot + 1 < name.length) ext = name.slice(dot + 1);
  }

  const key = `${md5Hex(uploadBytes)}.${ext}`;

  const uploadToken = await getQiniuUploadToken(cfg.user_token, cfg.qiniu_token_url);
  if (!uploadToken) throw new Error('上传失败: qiniu-token failed');

  const host = await queryUploadHost(uploadToken, cfg.bucket);
  let uploadUrl = `https://${host}`;

  let r = await uploadOnce(uploadUrl, uploadToken, key, uploadBytes, mimeType);
  if (r.status < 200 || r.status >= 300) {
    if (r.body.includes('no such domain')) {
      uploadUrl = `https://${DEFAULT_UPLOAD_HOST}`;
      r = await uploadOnce(uploadUrl, uploadToken, key, uploadBytes, mimeType);
    }
  }

  if (r.status < 200 || r.status >= 300) {
    throw new Error(`上传失败: qiniu upload failed: ${r.status} ${r.body}`);
  }

  console.log('上传成功');
  console.log('response_json:');
  prettyPrintJson(r.body);
}

main().catch((e) => {
  console.error(String(e?.message ?? e));
  process.exit(1);
});
