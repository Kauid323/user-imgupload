#!/usr/bin/env bash
set -euo pipefail

DEFAULT_UPLOAD_HOST="upload-z2.qiniup.com"

USER_TOKEN=""
ENABLE_WEBP="false"
WEBP_QUALITY="95"
BUCKET="chat-68"
TOKEN_URL="https://chat-go.jwzhd.com/v1/misc/qiniu-token"

trim() {
  local s="$1"
  s="${s##+([[:space:]])}"
  s="${s%%+([[:space:]])}"
  while [[ "$s" == *"+" ]]; do s="${s%+}"; s="${s%%+([[:space:]])}"; done
  if [[ ${#s} -ge 2 ]]; then
    local a="${s:0:1}"
    local b="${s: -1}"
    if [[ ( "$a" == '"' && "$b" == '"' ) || ( "$a" == "'" && "$b" == "'" ) ]]; then
      s="${s:1:${#s}-2}"
    fi
  fi
  printf "%s" "$s"
}

is_url() {
  [[ "$1" =~ ^https?:// ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

die() { echo "$1" >&2; exit 1; }

debug_enabled() {
  [[ -n "${IMGUTIL_DEBUG:-}" && "${IMGUTIL_DEBUG:-}" != "0" ]]
}

debug_log() {
  if debug_enabled; then
    echo "[debug] $1" >&2
  fi
}

json_get() {
  local key="$1"
  local def="$2"
  if have jq; then
    local v
    v=$(jq -r --arg k "$key" '.[$k] // empty' config.json 2>/dev/null || true)
    v=${v//$'\r'/}
    v=${v//$'\n'/}
    if [[ -z "$v" ]]; then
      echo "$def"
    else
      echo "$v"
    fi
  else
    local v
    v=$(grep -oE '"'"$key"'"[[:space:]]*:[[:space:]]*([^,}]+)' config.json | head -n1 | sed -E 's/^.*:[[:space:]]*//' || true)
    v=${v//$'\r'/}
    v=${v//$'\n'/}
    if [[ "$v" == "" ]]; then echo "$def"; return; fi
    if [[ "$v" =~ ^\".*\"$ ]]; then
      echo "${v:1:${#v}-2}"
    else
      echo "$v"
    fi
  fi
}

pretty_json() {
  if have jq; then
    jq .
  else
    cat
  fi
}

md5_hex_file() {
  local f="$1"
  if have md5sum; then
    md5sum "$f" | awk '{print $1}'
  elif have md5; then
    md5 -q "$f"
  else
    die "md5 tool not found (need md5sum or md5)"
  fi
}

get_upload_token() {
  local user_token="$1"
  local token_url="$2"
  token_url=${token_url//$'\r'/}
  token_url=${token_url//$'\n'/}
  debug_log "token_url=${token_url}"
  [[ -n "$token_url" ]] || return 1
  [[ "$token_url" =~ ^https?:// ]] || return 1
  local resp
  resp=$(curl -sS "$token_url" -H "token: $user_token" -H "Content-Type: application/json") || return 1
  if have jq; then
    local code token
    code=$(echo "$resp" | jq -r '.code // 0' 2>/dev/null || echo 0)
    [[ "$code" == "1" ]] || return 1
    token=$(echo "$resp" | jq -r '.data.token // .token // empty' 2>/dev/null || true)
    [[ -n "$token" ]] || return 1
    echo "$token"
    return 0
  fi
  local code
  code=$(echo "$resp" | grep -oE '"code"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | sed -E 's/^.*:[[:space:]]*//' || true)
  [[ "$code" == "1" ]] || return 1
  local token
  token=$(echo "$resp" | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
  [[ -n "$token" ]] || return 1
  echo "$token"
}

query_upload_host() {
  local upload_token="$1"
  local bucket="$2"
  local ak="${upload_token%%:*}"
  local url="https://api.qiniu.com/v4/query?ak=${ak}&bucket=${bucket}"
  local resp
  resp=$(curl -sS "$url") || { echo "$DEFAULT_UPLOAD_HOST"; return; }
  if have jq; then
    local d
    d=$(echo "$resp" | jq -r '.domains[0] // empty' 2>/dev/null || true)
    if [[ -n "$d" ]]; then
      d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"
      [[ -n "$d" ]] && { echo "$d"; return; }
    fi
    echo "$DEFAULT_UPLOAD_HOST"; return
  fi
  local d
  d=$(echo "$resp" | sed -nE 's/.*"domains"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
  d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"
  [[ -n "$d" ]] && echo "$d" || echo "$DEFAULT_UPLOAD_HOST"
}

main() {
  local user_token enable_webp webp_quality bucket token_url
  user_token="$USER_TOKEN"
  enable_webp="$ENABLE_WEBP"
  webp_quality="$WEBP_QUALITY"
  bucket="$BUCKET"
  token_url="$TOKEN_URL"

  debug_log "bucket=${bucket}"
  debug_log "enable_webp=${enable_webp}"
  debug_log "webp_quality=${webp_quality}"

  [[ -n "$user_token" ]] || die "user_token 为空（请在 main.sh 设置 USER_TOKEN）"

  have curl || die "curl not found"

  local input="${1-}"
  if [[ -z "$input" ]]; then
    read -r -p "请输入图片地址(本地路径或URL): " input
  fi
  input=$(trim "$input")
  [[ -n "$input" ]] || die "未输入图片地址"

  local tmpdir
  tmpdir="${TMPDIR:-/tmp}"
  local t
  t=$(date +%s)

  local src_path="$input"
  local dl_path="$tmpdir/imgutil_${t}.bin"

  if is_url "$input"; then
    curl -L -sS "$input" -o "$dl_path" || die "上传失败: download failed"
    src_path="$dl_path"
  fi

  [[ -f "$src_path" ]] || die "上传失败: could not read file"

  local up_path="$src_path"
  local ext="bin"

  if [[ "$enable_webp" == "true" ]]; then
    have cwebp || die "上传失败: cwebp failed (install cwebp or set enable_webp=false)"
    local out_path="$tmpdir/imgutil_${t}.webp"
    local q="$webp_quality"
    [[ "$q" =~ ^[0-9]+$ ]] || q=95
    if (( q <= 0 || q > 100 )); then q=95; fi
    cwebp -q "$q" "$src_path" -o "$out_path" >/dev/null 2>&1 || die "上传失败: cwebp failed (install cwebp or set enable_webp=false)"
    up_path="$out_path"
    ext="webp"
  else
    local base
    base=$(basename "$src_path")
    if [[ "$base" == *.* ]]; then
      ext="${base##*.}"
    fi
  fi

  local md5
  md5=$(md5_hex_file "$up_path")
  local key="${md5}.${ext}"

  local upload_token
  upload_token=$(get_upload_token "$user_token" "$token_url") || die "上传失败: qiniu-token failed"

  local host
  host=$(query_upload_host "$upload_token" "$bucket")

  local upload_url="https://${host}"

  local resp
  resp=$(curl -sS "$upload_url" \
    -F "token=${upload_token}" \
    -F "key=${key}" \
    -F "file=@${up_path}" ) || die "上传失败: qiniu upload failed"

  if [[ "$resp" == *"no such domain"* ]]; then
    upload_url="https://${DEFAULT_UPLOAD_HOST}"
    resp=$(curl -sS "$upload_url" \
      -F "token=${upload_token}" \
      -F "key=${key}" \
      -F "file=@${up_path}" ) || die "上传失败: qiniu upload failed"
  fi

  echo "上传成功"
  echo "response_json:"
  echo "$resp" | pretty_json

  if is_url "$input"; then rm -f "$dl_path" || true; fi
  if [[ "$enable_webp" == "true" && "$up_path" != "$src_path" ]]; then rm -f "$up_path" || true; fi
}

main "$@"
