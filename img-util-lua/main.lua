local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write_all(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function trim(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  while s:sub(-1) == "+" do s = s:sub(1, -2) end
  if (#s >= 2 and ((s:sub(1,1) == '"' and s:sub(-1) == '"') or (s:sub(1,1) == "'" and s:sub(-1) == "'"))) then
    s = s:sub(2, -2)
  end
  return s
end

local function is_url(s)
  return s:match("^https?://") ~= nil
end

local function basename(p)
  local s = p:gsub("\\", "/")
  local i = s:match("^.*()/")
  if i then return s:sub(i + 1) end
  return s
end

local function shell_quote(s)
  if package.config:sub(1,1) == "\\" then
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function exec_capture(cmd)
  local p = io.popen(cmd .. " 2>&1")
  if not p then return nil, "popen failed" end
  local out = p:read("*a")
  local ok, reason, code = p:close()
  local exit_code = 0
  if type(ok) == "number" then
    exit_code = ok
  else
    exit_code = code or (ok and 0 or 1)
  end
  return out, exit_code
end

local function json_find_key(json, key)
  local pat = '"' .. key .. '"%s*:%s*'
  local s, e = json:find(pat)
  if not s then return nil end
  return e + 1
end

local function json_get_string(json, key, defv)
  local i = json_find_key(json, key)
  if not i then return defv end
  if json:sub(i,i) ~= '"' then return defv end
  local j = i + 1
  local k = j
  while k <= #json do
    local c = json:sub(k,k)
    if c == '"' and json:sub(k-1,k-1) ~= "\\" then
      return json:sub(j, k - 1)
    end
    k = k + 1
  end
  return defv
end

local function json_get_bool(json, key, defv)
  local i = json_find_key(json, key)
  if not i then return defv end
  local tail = json:sub(i, i + 10)
  if tail:match("^true") then return true end
  if tail:match("^false") then return false end
  return defv
end

local function json_get_int(json, key, defv)
  local i = json_find_key(json, key)
  if not i then return defv end
  local n = json:sub(i):match("^%-?%d+")
  if not n then return defv end
  return tonumber(n)
end

local function pretty_print_json(raw)
  local indent = 0
  local in_str = false
  local esc = false
  local out = {}
  local function push(x) out[#out+1] = x end
  local function push_indent()
    push(string.rep("  ", indent))
  end

  local i = 1
  while i <= #raw do
    local c = raw:sub(i,i)
    if esc then
      push(c)
      esc = false
      i = i + 1
    elseif in_str and c == "\\" then
      push(c)
      esc = true
      i = i + 1
    elseif c == '"' then
      push(c)
      in_str = not in_str
      i = i + 1
    elseif in_str then
      push(c)
      i = i + 1
    elseif c == "{" or c == "[" then
      push(c)
      push("\n")
      indent = indent + 1
      push_indent()
      i = i + 1
    elseif c == "}" or c == "]" then
      push("\n")
      indent = math.max(0, indent - 1)
      push_indent()
      push(c)
      i = i + 1
    elseif c == "," then
      push(c)
      push("\n")
      push_indent()
      i = i + 1
    elseif c == ":" then
      push(": ")
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    else
      push(c)
      i = i + 1
    end
  end

  io.write(table.concat(out), "\n")
end

-- MD5 implementation (pure Lua)
-- Based on public domain Lua MD5 implementations; kept self-contained.
local function band(a,b) return a & b end
local function bor(a,b) return a | b end
local function bxor(a,b) return a ~ b end
local function bnot(a) return (~a) & 0xffffffff end
local function lshift(a,n) return (a << n) & 0xffffffff end
local function rshift(a,n) return (a >> n) & 0xffffffff end
local function rol(a,n) return bor(lshift(a,n), rshift(a, 32 - n)) end

local function to_bytes_le(n)
  local b1 = n & 0xff
  local b2 = (n >> 8) & 0xff
  local b3 = (n >> 16) & 0xff
  local b4 = (n >> 24) & 0xff
  return string.char(b1,b2,b3,b4)
end

local function from_bytes_le(s, i)
  local b1 = s:byte(i) or 0
  local b2 = s:byte(i+1) or 0
  local b3 = s:byte(i+2) or 0
  local b4 = s:byte(i+3) or 0
  return (b1 | (b2<<8) | (b3<<16) | (b4<<24)) & 0xffffffff
end

local r = {
  7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
  5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
  4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
  6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
}

local k = {
  0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,
  0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
  0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
  0x6b901122,0xfd987193,0xa679438e,0x49b40821,
  0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,
  0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
  0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,
  0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
  0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
  0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
  0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,
  0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
  0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,
  0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
  0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
  0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
}

local function md5_raw(msg)
  local len = #msg
  msg = msg .. "\128"
  local pad = (56 - (#msg % 64)) % 64
  msg = msg .. string.rep("\0", pad)
  local bit_len = len * 8
  local low = bit_len & 0xffffffff
  local high = math.floor(bit_len / 2^32) & 0xffffffff
  msg = msg .. to_bytes_le(low) .. to_bytes_le(high)

  local h0,h1,h2,h3 = 0x67452301,0xefcdab89,0x98badcfe,0x10325476

  for offset = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      w[i] = from_bytes_le(msg, offset + i*4)
    end

    local a,b,c,d = h0,h1,h2,h3
    for i = 0, 63 do
      local f,g
      if i < 16 then
        f = bor(band(b,c), band(bnot(b), d))
        g = i
      elseif i < 32 then
        f = bor(band(d,b), band(bnot(d), c))
        g = (5*i + 1) % 16
      elseif i < 48 then
        f = bxor(b, bxor(c, d))
        g = (3*i + 5) % 16
      else
        f = bxor(c, bor(b, bnot(d)))
        g = (7*i) % 16
      end
      local temp = d
      d = c
      c = b
      local x = (a + f + k[i+1] + w[g]) & 0xffffffff
      b = (b + rol(x, r[i+1])) & 0xffffffff
      a = temp
    end

    h0 = (h0 + a) & 0xffffffff
    h1 = (h1 + b) & 0xffffffff
    h2 = (h2 + c) & 0xffffffff
    h3 = (h3 + d) & 0xffffffff
  end

  return to_bytes_le(h0) .. to_bytes_le(h1) .. to_bytes_le(h2) .. to_bytes_le(h3)
end

local function md5_hex(msg)
  local raw = md5_raw(msg)
  return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function ensure_tools(cfg)
  local out, code = exec_capture("curl --version")
  if not out or code ~= 0 then
    error("curl not found in PATH")
  end
  if cfg.enable_webp then
    local out2, code2 = exec_capture("cwebp -version")
    if not out2 or code2 ~= 0 then
      error("cwebp not found in PATH (enable_webp=true)")
    end
  end
end

local function get_upload_token(cfg)
  local cmd = "curl -sS " .. shell_quote(cfg.qiniu_token_url) .. " -H " .. shell_quote("token: " .. cfg.user_token) .. " -H " .. shell_quote("Content-Type: application/json")
  local out, code = exec_capture(cmd)
  if not out or code ~= 0 then return nil, "qiniu-token request failed" end
  local codev = json_get_int(out, "code", 0)
  if codev ~= 1 then return nil, "qiniu-token bad code" end
  local token = json_get_string(out, "token", "")
  if token == "" then return nil, "qiniu-token missing token" end
  return token, nil
end

local function query_upload_host(upload_token, bucket)
  local ak = upload_token:match("^([^:]+)") or upload_token
  local url = "https://api.qiniu.com/v4/query?ak=" .. ak .. "&bucket=" .. bucket
  local out, code = exec_capture("curl -sS " .. shell_quote(url))
  if not out or code ~= 0 then return DEFAULT_UPLOAD_HOST end

  local domains_pos = out:find('"domains"')
  if not domains_pos then return DEFAULT_UPLOAD_HOST end
  local first = out:match('"domains"%s*:%s*%[%s*"([^"]+)"')
  if not first or first == "" then return DEFAULT_UPLOAD_HOST end
  first = first:gsub("^https?://", "")
  first = first:gsub("/.*$", "")
  if first == "" then return DEFAULT_UPLOAD_HOST end
  return first
end

local function download_url_to_file(url, path)
  local cmd = "curl -L -sS " .. shell_quote(url) .. " -o " .. shell_quote(path)
  local out, code = exec_capture(cmd)
  if code ~= 0 then return nil, out end
  return true, nil
end

local function run_cwebp_file(in_path, out_path, quality)
  local cmd = "cwebp -q " .. tostring(quality) .. " " .. shell_quote(in_path) .. " -o " .. shell_quote(out_path)
  local out, code = exec_capture(cmd)
  if code ~= 0 then return nil, out end
  return true, nil
end

local function upload_file(upload_url, upload_token, key, file_path)
  local cmd = "curl -sS " .. shell_quote(upload_url) .. " -F " .. shell_quote("token=" .. upload_token) .. " -F " .. shell_quote("key=" .. key) .. " -F " .. shell_quote("file=@" .. file_path)
  local out, code = exec_capture(cmd)
  if not out or code ~= 0 then return nil, out or "upload failed" end
  return out, nil
end

local function load_config()
  local txt = read_all("config.json")
  if not txt then error("config.json not found") end
  local cfg = {
    user_token = json_get_string(txt, "user_token", ""),
    enable_webp = json_get_bool(txt, "enable_webp", false),
    webp_quality = json_get_int(txt, "webp_quality", 95),
    bucket = json_get_string(txt, "bucket", "chat68"),
    qiniu_token_url = json_get_string(txt, "qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token"),
  }
  return cfg
end

local function main()
  local cfg = load_config()
  if cfg.user_token == "" then
    io.write("config.json里的 user_token 为空\n")
    return 1
  end

  ensure_tools(cfg)

  local input = arg[1]
  if not input or input == "" then
    io.write("请输入图片地址(本地路径或URL): ")
    input = io.read("*l")
  end
  input = trim(input or "")
  if input == "" then
    io.write("未输入图片地址\n")
    return 1
  end

  local tmp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local t = tostring(os.time())
  local download_path = tmp_dir .. package.config:sub(1,1) .. "imgutil_" .. t .. ".bin"
  local src_path = input

  if is_url(input) then
    local ok, err = download_url_to_file(input, download_path)
    if not ok then
      io.write("上传失败: download failed\n")
      return 1
    end
    src_path = download_path
  end

  local orig = read_all(src_path)
  if not orig then
    io.write("上传失败: could not read file\n")
    return 1
  end

  local upload_path = src_path
  local ext = "bin"

  if cfg.enable_webp then
    local out_path = tmp_dir .. package.config:sub(1,1) .. "imgutil_" .. t .. ".webp"
    local q = cfg.webp_quality
    if q <= 0 or q > 100 then q = 95 end
    local ok, err = run_cwebp_file(src_path, out_path, q)
    if not ok then
      io.write("上传失败: cwebp failed (install cwebp or set enable_webp=false)\n")
      return 1
    end
    upload_path = out_path
    orig = read_all(upload_path)
    if not orig then
      io.write("上传失败: could not read file\n")
      return 1
    end
    ext = "webp"
  else
    local bn = basename(src_path)
    local dot = bn:match("%.([^.]+)$")
    if dot and dot ~= "" then ext = dot end
  end

  local key = md5_hex(orig) .. "." .. ext

  local upload_token, err = get_upload_token(cfg)
  if not upload_token then
    io.write("上传失败: qiniu-token failed\n")
    return 1
  end

  local host = query_upload_host(upload_token, cfg.bucket)
  local upload_url = "https://" .. host

  local resp, err2 = upload_file(upload_url, upload_token, key, upload_path)
  if not resp then
    io.write("上传失败: qiniu upload failed: " .. (err2 or "") .. "\n")
    return 1
  end

  if resp:find("no such domain", 1, true) then
    upload_url = "https://" .. DEFAULT_UPLOAD_HOST
    resp = select(1, upload_file(upload_url, upload_token, key, upload_path))
  end

  if not resp then
    io.write("上传失败: qiniu upload failed\n")
    return 1
  end

  io.write("上传成功\n")
  io.write("response_json:\n")
  pretty_print_json(resp)

  if is_url(input) then os.remove(download_path) end
  if cfg.enable_webp and upload_path ~= src_path then os.remove(upload_path) end

  return 0
end

local ok, code = pcall(main)
if not ok then
  io.write("上传失败: " .. tostring(code) .. "\n")
  os.exit(1)
end
os.exit(code)
