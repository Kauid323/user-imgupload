import hashlib
import json
import mimetypes
import os
from dataclasses import dataclass
from io import BytesIO
from typing import Any, Dict, Optional, Tuple

import requests
from PIL import Image


DEFAULT_UPLOAD_HOST = "upload-z2.qiniup.com"


@dataclass
class UploadResult:
    key: str
    hash: str
    fsize: int
    raw: Dict[str, Any]


def load_config(config_path: str) -> Dict[str, Any]:
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _is_url(s: str) -> bool:
    return s.startswith("http://") or s.startswith("https://")


def _read_input_bytes(path_or_url: str, timeout: int = 60) -> Tuple[bytes, str, Optional[str]]:
    if _is_url(path_or_url):
        resp = requests.get(path_or_url, timeout=timeout)
        resp.raise_for_status()
        content_type = resp.headers.get("content-type")
        ext = None
        if content_type:
            ext = mimetypes.guess_extension(content_type.split(";")[0].strip())
            if ext:
                ext = ext.lstrip(".")
        return resp.content, os.path.basename(path_or_url), content_type

    with open(path_or_url, "rb") as f:
        data = f.read()
    name = os.path.basename(path_or_url)
    mime, _ = mimetypes.guess_type(name)
    return data, name, mime


def _to_webp(image_bytes: bytes, quality: int) -> bytes:
    img = Image.open(BytesIO(image_bytes))
    if img.mode in ("RGBA", "LA"):
        background = Image.new("RGBA", img.size, (255, 255, 255, 255))
        background.paste(img, mask=img.split()[-1])
        img = background.convert("RGB")
    elif img.mode != "RGB":
        img = img.convert("RGB")

    out = BytesIO()
    img.save(out, format="WEBP", quality=quality, method=6)
    return out.getvalue()


def _md5_hex(b: bytes) -> str:
    return hashlib.md5(b).hexdigest()


def get_qiniu_upload_token(user_token: str, qiniu_token_url: str, timeout: int = 60) -> str:
    resp = requests.get(
        qiniu_token_url,
        headers={"token": user_token, "Content-Type": "application/json"},
        timeout=timeout,
    )
    resp.raise_for_status()
    payload = resp.json()
    if int(payload.get("code", 0)) != 1:
        raise RuntimeError(f"qiniu-token api error: {payload}")
    data = payload.get("data") or {}
    utoken = data.get("token")
    if not utoken:
        raise RuntimeError(f"qiniu-token missing token: {payload}")
    return utoken


def query_upload_host(upload_token: str, bucket: str, timeout: int = 60) -> str:
    ak = upload_token.split(":")[0]
    url = f"https://api.qiniu.com/v4/query?ak={ak}&bucket={bucket}"
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
        payload = resp.json()
        hosts = payload.get("hosts") or []
        if not hosts:
            return DEFAULT_UPLOAD_HOST
        up = (hosts[0] or {}).get("up") or {}
        domains = up.get("domains") or []
        return domains[0] if domains else DEFAULT_UPLOAD_HOST
    except Exception:
        return DEFAULT_UPLOAD_HOST


def upload_image(
    *,
    path_or_url: str,
    user_token: str,
    enable_webp: bool,
    webp_quality: int,
    bucket: str,
    qiniu_token_url: str,
    timeout: int = 120,
) -> UploadResult:
    original_bytes, original_name, original_mime = _read_input_bytes(path_or_url, timeout=timeout)

    if enable_webp:
        upload_bytes = _to_webp(original_bytes, quality=webp_quality)
        mime_type = "image/webp"
        extension = "webp"
    else:
        upload_bytes = original_bytes
        mime_type = original_mime or "application/octet-stream"
        ext = os.path.splitext(original_name)[1].lstrip(".")
        extension = ext if ext else (mimetypes.guess_extension(mime_type) or "bin").lstrip(".")

    md5 = _md5_hex(upload_bytes)
    key = f"{md5}.{extension}"

    utoken = get_qiniu_upload_token(user_token=user_token, qiniu_token_url=qiniu_token_url, timeout=timeout)
    host = query_upload_host(upload_token=utoken, bucket=bucket, timeout=timeout)

    upload_url = f"https://{host}"

    data = {"token": utoken, "key": key}
    files = {"file": (key, upload_bytes, mime_type)}

    resp = requests.post(
        upload_url,
        data=data,
        files=files,
        headers={"user-agent": "QiniuDart", "accept-encoding": "gzip"},
        timeout=timeout,
    )
    if resp.status_code < 200 or resp.status_code >= 300:
        raise RuntimeError(f"qiniu upload failed: {resp.status_code} {resp.text}")

    payload = resp.json()
    return UploadResult(
        key=str(payload.get("key", "")),
        hash=str(payload.get("hash", "")),
        fsize=int(payload.get("fsize", 0)),
        raw=payload,
    )
