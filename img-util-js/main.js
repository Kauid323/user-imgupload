import path from 'path';
import readline from 'readline';
import { fileURLToPath } from 'url';

import { loadConfig, uploadImage } from './uploader.js';

function prompt(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(String(answer || '').trim());
    });
  });
}

async function main() {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);
  const configPath = path.join(__dirname, 'config.json');

  let cfg;
  try {
    cfg = await loadConfig(configPath);
  } catch (e) {
    console.log('找不到或无法解析config.json:', e?.message || e);
    process.exit(1);
  }

  const userToken = String(cfg.user_token || '').trim();
  if (!userToken) {
    console.log('config.json里的 user_token 为空');
    process.exit(1);
  }

  const enableWebp = Boolean(cfg.enable_webp);
  const webpQuality = Number(cfg.webp_quality ?? 95);
  const bucket = String(cfg.bucket || 'chat68');
  const qiniuTokenUrl = String(cfg.qiniu_token_url || 'https://chat-go.jwzhd.com/v1/misc/qiniu-token');

  const pathOrUrl = await prompt('请输入图片地址(本地路径或URL): ');
  if (!pathOrUrl) {
    console.log('未输入图片地址');
    process.exit(1);
  }

  try {
    const result = await uploadImage({
      pathOrUrl,
      userToken,
      enableWebp,
      webpQuality,
      bucket,
      qiniuTokenUrl,
    });

    console.log('上传成功');
    console.log(`key: ${result.key}`);
    console.log(`hash: ${result.hash}`);
    console.log(`fsize: ${result.fsize}`);
    console.log('response_json:');
    console.log(JSON.stringify(result.raw, null, 2));
  } catch (e) {
    console.log('上传失败:', e?.message || e);
    process.exit(1);
  }
}

await main();
