use anyhow::{anyhow, Context, Result};
use reqwest::multipart;
use serde::Deserialize;
use serde_json::Value;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use url::Url;

const DEFAULT_UPLOAD_HOST: &str = "upload-z2.qiniup.com";

#[derive(Debug, Deserialize)]
struct Config {
    user_token: String,
    enable_webp: bool,
    webp_quality: Option<u8>,
    bucket: Option<String>,
    qiniu_token_url: Option<String>,
}

#[derive(Debug)]
struct InputData {
    bytes: Vec<u8>,
    name: String,
    content_type: Option<String>,
}

fn is_url(s: &str) -> bool {
    s.starts_with("http://") || s.starts_with("https://")
}

fn load_config(config_path: &Path) -> Result<Config> {
    let txt = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read config: {}", config_path.display()))?;
    let cfg: Config = serde_json::from_str(&txt).context("invalid config.json")?;
    Ok(cfg)
}

async fn read_input_bytes(path_or_url: &str) -> Result<InputData> {
    if is_url(path_or_url) {
        let url = Url::parse(path_or_url).context("invalid url")?;
        let resp = reqwest::Client::new()
            .get(url.clone())
            .send()
            .await
            .context("download failed")?;
        let status = resp.status();
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.split(';').next().unwrap_or(s).trim().to_string());
        let bytes = resp.bytes().await.context("read response body")?.to_vec();
        if !status.is_success() {
            return Err(anyhow!(
                "download failed: {} {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            ));
        }
        let name = url
            .path_segments()
            .and_then(|mut s| s.next_back())
            .filter(|s| !s.is_empty())
            .unwrap_or("image")
            .to_string();
        return Ok(InputData {
            bytes,
            name,
            content_type,
        });
    }

    let p = Path::new(path_or_url);
    let bytes = fs::read(p)
        .with_context(|| format!("failed to read file: {}", p.display()))?;
    let name = p
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("file")
        .to_string();
    let content_type = mime_guess::from_path(p)
        .first_raw()
        .map(|s| s.to_string());
    Ok(InputData {
        bytes,
        name,
        content_type,
    })
}

fn md5_hex(bytes: &[u8]) -> String {
    format!("{:x}", md5::compute(bytes))
}

fn normalize_host(domain_or_url: &str) -> String {
    let s = domain_or_url.trim();
    if s.is_empty() {
        return DEFAULT_UPLOAD_HOST.to_string();
    }
    if s.starts_with("http://") || s.starts_with("https://") {
        if let Ok(u) = Url::parse(s) {
            if let Some(host) = u.host_str() {
                return host.to_string();
            }
        }
    }
    s.split('/').next().unwrap_or(DEFAULT_UPLOAD_HOST).to_string()
}

fn to_webp_via_cwebp(input_bytes: &[u8], quality: u8) -> Result<Vec<u8>> {
    let q = if quality == 0 { 95 } else { quality };

    let tmp_dir = std::env::temp_dir();
    let in_path = tmp_dir.join(format!("imgutil-{}.input", uuid_like()));
    let out_path = tmp_dir.join(format!("imgutil-{}.webp", uuid_like()));

    fs::write(&in_path, input_bytes).context("write temp input")?;

    let output = Command::new("cwebp")
        .args([
            "-q",
            &q.to_string(),
            in_path.to_string_lossy().as_ref(),
            "-o",
            out_path.to_string_lossy().as_ref(),
        ])
        .output();

    let _ = fs::remove_file(&in_path);

    let output = match output {
        Ok(o) => o,
        Err(e) => {
            let _ = fs::remove_file(&out_path);
            return Err(anyhow!(
                "failed to run cwebp (install libwebp/cwebp or set enable_webp=false): {}",
                e
            ));
        }
    };

    if !output.status.success() {
        let _ = fs::remove_file(&out_path);
        return Err(anyhow!(
            "cwebp failed: {}",
            String::from_utf8_lossy(&output.stdout)
        ));
    }

    let webp = fs::read(&out_path).context("read temp webp")?;
    let _ = fs::remove_file(&out_path);
    Ok(webp)
}

fn uuid_like() -> String {
    // no extra dependency: use timestamp+pid
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("{}-{}", ts, std::process::id())
}

async fn get_qiniu_upload_token(user_token: &str, qiniu_token_url: &str) -> Result<String> {
    let client = reqwest::Client::new();
    let resp = client
        .get(qiniu_token_url)
        .header("token", user_token)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .send()
        .await
        .context("request qiniu-token")?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(anyhow!("qiniu-token http error: {} {}", status.as_u16(), text));
    }

    let payload: Value = serde_json::from_str(&text).context("parse qiniu-token json")?;
    if payload.get("code").and_then(|v| v.as_i64()) != Some(1) {
        return Err(anyhow!("qiniu-token api error: {}", text));
    }
    let tok = payload
        .get("data")
        .and_then(|d| d.get("token"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("qiniu-token missing token: {}", text))?;
    Ok(tok.to_string())
}

async fn query_upload_host(upload_token: &str, bucket: &str) -> String {
    let ak = upload_token.split(':').next().unwrap_or("");
    let url = format!(
        "https://api.qiniu.com/v4/query?ak={}&bucket={}",
        urlencoding::encode(ak),
        urlencoding::encode(bucket)
    );

    let client = reqwest::Client::new();
    let resp = match client.get(url).send().await {
        Ok(r) => r,
        Err(_) => return DEFAULT_UPLOAD_HOST.to_string(),
    };

    if !resp.status().is_success() {
        return DEFAULT_UPLOAD_HOST.to_string();
    }

    let payload: Value = match resp.json().await {
        Ok(p) => p,
        Err(_) => return DEFAULT_UPLOAD_HOST.to_string(),
    };

    let domain = payload
        .get("hosts")
        .and_then(|h| h.get(0))
        .and_then(|h0| h0.get("up"))
        .and_then(|u| u.get("domains"))
        .and_then(|d| d.get(0))
        .and_then(|v| v.as_str());

    domain
        .map(|d| normalize_host(d))
        .unwrap_or_else(|| DEFAULT_UPLOAD_HOST.to_string())
}

async fn upload_once(
    upload_url: &str,
    upload_token: &str,
    key: &str,
    bytes: Vec<u8>,
    mime_type: &str,
) -> Result<String> {
    let part = multipart::Part::bytes(bytes)
        .file_name(key.to_string())
        .mime_str(mime_type)
        .unwrap_or_else(|_| multipart::Part::bytes(Vec::new()));

    let form = multipart::Form::new()
        .text("token", upload_token.to_string())
        .text("key", key.to_string())
        .part("file", part);

    let client = reqwest::Client::new();
    let resp = client
        .post(upload_url)
        .header(reqwest::header::USER_AGENT, "QiniuDart")
        .header(reqwest::header::ACCEPT_ENCODING, "gzip")
        .multipart(form)
        .send()
        .await
        .context("qiniu upload request")?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(anyhow!(
            "qiniu upload failed: {} {} (uploadUrl={})",
            status.as_u16(),
            text,
            upload_url
        ));
    }
    Ok(text)
}

#[tokio::main]
async fn main() -> Result<()> {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let config_path = exe_dir.join("config.json");
    let cfg = load_config(&config_path)?;

    let user_token = cfg.user_token.trim().to_string();
    if user_token.is_empty() {
        return Err(anyhow!("config.json里的 user_token 为空"));
    }

    let enable_webp = cfg.enable_webp;
    let webp_quality = cfg.webp_quality.unwrap_or(95);
    let bucket = cfg.bucket.unwrap_or_else(|| "chat68".to_string());
    let qiniu_token_url = cfg
        .qiniu_token_url
        .unwrap_or_else(|| "https://chat-go.jwzhd.com/v1/misc/qiniu-token".to_string());

    print!("请输入图片地址(本地路径或URL): ");
    io::stdout().flush().ok();
    let mut input = String::new();
    io::stdin().read_line(&mut input).context("read input")?;
    let path_or_url = input.trim();
    if path_or_url.is_empty() {
        return Err(anyhow!("未输入图片地址"));
    }

    let in_data = read_input_bytes(path_or_url).await?;

    let (upload_bytes, mime_type, ext) = if enable_webp {
        let wb = to_webp_via_cwebp(&in_data.bytes, webp_quality)?;
        (wb, "image/webp".to_string(), "webp".to_string())
    } else {
        let mt = in_data
            .content_type
            .clone()
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let ext = Path::new(&in_data.name)
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or_else(|| {
                mime_guess::get_mime_extensions_str(&mt)
                    .and_then(|arr| arr.first().copied())
                    .unwrap_or("bin")
            })
            .to_string();
        (in_data.bytes, mt, ext)
    };

    let key = format!("{}.{}", md5_hex(&upload_bytes), ext);

    let utoken = get_qiniu_upload_token(&user_token, &qiniu_token_url).await?;
    let host = query_upload_host(&utoken, &bucket).await;
    let upload_url = format!("https://{}", host);

    let mut resp_text = match upload_once(&upload_url, &utoken, &key, upload_bytes.clone(), &mime_type).await {
        Ok(t) => t,
        Err(e) => {
            let msg = e.to_string();
            if msg.contains("no such domain") {
                let fallback_url = format!("https://{}", DEFAULT_UPLOAD_HOST);
                upload_once(&fallback_url, &utoken, &key, upload_bytes, &mime_type).await?
            } else {
                return Err(e);
            }
        }
    };

    // try pretty json
    if let Ok(v) = serde_json::from_str::<Value>(&resp_text) {
        resp_text = serde_json::to_string_pretty(&v).unwrap_or(resp_text);
    }

    println!("上传成功");
    println!("response_json:");
    println!("{}", resp_text);

    Ok(())
}
