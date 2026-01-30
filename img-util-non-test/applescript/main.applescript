-- Config (edit here)
property USER_TOKEN : ""
property ENABLE_WEBP : false
property WEBP_QUALITY : 95
property BUCKET : "chat68"
property TOKEN_URL : "https://chat-go.jwzhd.com/v1/misc/qiniu-token"
property DEFAULT_UPLOAD_HOST : "upload-z2.qiniup.com"

on isUrl(s)
  return (s starts with "http://") or (s starts with "https://")
end isUrl

on sh(cmd)
  return do shell script cmd
end sh

on pyJson(expr, jsonText)
  set cmd to "python3 -c " & quoted form of ("import json,sys; o=json.loads(sys.argv[1]);\n" & expr)
  return sh(cmd & " " & quoted form of jsonText)
end pyJson

on readConfigIfExists()
  try
    set cfgText to sh("cat config.json")
    if cfgText is "" then return
    set USER_TOKEN to pyJson("print(str(o.get('user_token','') or '').strip())", cfgText)
    set BUCKET to pyJson("print(str(o.get('bucket','chat68') or 'chat68'))", cfgText)
    set TOKEN_URL to pyJson("print(str(o.get('qiniu_token_url','https://chat-go.jwzhd.com/v1/misc/qiniu-token') or 'https://chat-go.jwzhd.com/v1/misc/qiniu-token'))", cfgText)
    set ENABLE_WEBP to (pyJson("print('true' if bool(o.get('enable_webp', False)) else 'false')", cfgText) is "true")
    set WEBP_QUALITY to (pyJson("print(int(o.get('webp_quality',95) or 95))", cfgText) as integer)
  on error
    return
  end try
end readConfigIfExists

on md5File(p)
  -- macOS has `md5 -q`
  return sh("md5 -q " & quoted form of p)
end md5File

on getToken()
  set cmd to "curl -sS " & quoted form of TOKEN_URL & " -H " & quoted form of ("token: " & USER_TOKEN) & " -H " & quoted form of "Content-Type: application/json"
  set resp to sh(cmd)
  -- minimal parse: prefer data.token then token
  try
    set codev to pyJson("print(int(o.get('code',0)))", resp)
    if codev is not "1" then error "bad code"
    set t to pyJson("print(str(((o.get('data') or {}).get('token')) or o.get('token') or ''))", resp)
    if t is "" then error "missing token"
    return t
  on error
    error "qiniu-token failed"
  end try
end getToken

on queryHost(uploadToken)
  try
    set ak to text 1 thru ((offset of ":" in uploadToken) - 1) of uploadToken
  on error
    set ak to uploadToken
  end try
  set url to "https://api.qiniu.com/v4/query?ak=" & ak & "&bucket=" & BUCKET
  try
    set resp to sh("curl -sS " & quoted form of url)
    set h to pyJson("d=(o.get('domains') or [''])[0] if isinstance(o.get('domains'),list) else '';\nprint(str(d).replace('http://','').replace('https://','').split('/')[0] if d else '')", resp)
    if h is "" then return DEFAULT_UPLOAD_HOST
    return h
  on error
    return DEFAULT_UPLOAD_HOST
  end try
end queryHost

on uploadOnce(uploadUrl, token, key, filePath)
  set cmd to "curl -sS " & quoted form of uploadUrl & " -F " & quoted form of ("token=" & token) & " -F " & quoted form of ("key=" & key) & " -F " & quoted form of ("file=@" & filePath)
  return sh(cmd)
end uploadOnce

on run argv
  readConfigIfExists()
  if USER_TOKEN is "" then error "user_token empty"
  set input to ""
  if (count of argv) > 0 then set input to item 1 of argv
  if input is "" then
    display dialog "请输入图片地址(本地路径或URL):" default answer ""
    set input to text returned of result
  end if

  set tmpDir to (POSIX path of (path to temporary items))
  set srcPath to input

  if isUrl(input) then
    set dl to tmpDir & "imgutil_download.bin"
    sh("curl -L -sS " & quoted form of input & " -o " & quoted form of dl)
    set srcPath to dl
  end if

  set upPath to srcPath
  set ext to "bin"

  if ENABLE_WEBP then
    set outPath to tmpDir & "imgutil.webp"
    sh("cwebp -q " & WEBP_QUALITY & " " & quoted form of srcPath & " -o " & quoted form of outPath)
    set upPath to outPath
    set ext to "webp"
  else
    try
      set AppleScript's text item delimiters to "."
      set parts to text items of srcPath
      if (count of parts) > 1 then set ext to item -1 of parts
    end try
  end if

  set md5 to md5File(upPath)
  set key to md5 & "." & ext

  set t to getToken()
  set host to queryHost(t)
  set uploadUrl to "https://" & host

  set resp to uploadOnce(uploadUrl, t, key, upPath)
  if resp contains "no such domain" then
    set resp to uploadOnce("https://" & DEFAULT_UPLOAD_HOST, t, key, upPath)
  end if

  return "上传成功\nresponse_json:\n" & resp
end run
