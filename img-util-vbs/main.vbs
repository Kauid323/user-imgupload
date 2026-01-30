Option Explicit

Const DEFAULT_UPLOAD_HOST = "upload-z2.qiniup.com"

Dim fso: Set fso = CreateObject("Scripting.FileSystemObject")
Dim sh: Set sh = CreateObject("WScript.Shell")

Function DebugEnabled()
  Dim v: v = sh.ExpandEnvironmentStrings("%IMGUTIL_DEBUG%")
  DebugEnabled = (Len(v) > 0 And v <> "0")
End Function

Sub DebugLog(msg)
  If DebugEnabled() Then
    WScript.Echo "[debug] " & msg
  End If
End Sub

Sub Die(msg)
  WScript.Echo msg
  WScript.Quit 1
End Sub

Function ReadAllTextUtf8(path)
  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 2
  stm.Charset = "utf-8"
  stm.Open
  stm.LoadFromFile path
  Dim txt: txt = stm.ReadText
  stm.Close
  If Len(txt) > 0 And AscW(Left(txt, 1)) = &HFEFF Then txt = Mid(txt, 2)
  ReadAllTextUtf8 = txt
End Function

Function WriteAllBytes(path, bytes)
  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 1
  stm.Open
  stm.Write bytes
  stm.SaveToFile path, 2
  stm.Close
  WriteAllBytes = True
End Function

Function ReadAllBytes(path)
  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 1
  stm.Open
  stm.LoadFromFile path
  ReadAllBytes = stm.Read
  stm.Close
End Function

Function BytesToUtf8(bytes)
  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 1
  stm.Open
  stm.Write bytes
  stm.Position = 0
  stm.Type = 2
  stm.Charset = "utf-8"
  BytesToUtf8 = stm.ReadText
  stm.Close
End Function

Function TrimInput(s)
  Dim t: t = Trim(CStr(s))
  Do While Len(t) > 0 And Right(t, 1) = "+"
    t = Trim(Left(t, Len(t) - 1))
  Loop
  If Len(t) >= 2 Then
    Dim a: a = Left(t, 1)
    Dim b: b = Right(t, 1)
    If (a = Chr(34) And b = Chr(34)) Or (a = "'" And b = "'") Then
      t = Mid(t, 2, Len(t) - 2)
    End If
  End If
  TrimInput = t
End Function

Function IsUrl(s)
  Dim t: t = LCase(CStr(s))
  IsUrl = (Left(t, 7) = "http://" Or Left(t, 8) = "https://")
End Function

Function JsonGetString(json, key, defv)
  Dim pos: pos = InStr(json, """" & key & """:")
  If pos = 0 Then
    JsonGetString = defv
    Exit Function
  End If
  Dim start: start = pos + Len("""" & key & """:")
  If Mid(json, start, 1) = " " Then start = start + 1
  Dim endPos: endPos = InStr(start, json, ",")
  If endPos = 0 Then endPos = InStr(start, json, vbLf)
  If endPos = 0 Then endPos = Len(json) + 1
  Dim value: value = Trim(Mid(json, start, endPos - start))
  If Left(value, 1) = """" And Right(value, 1) = """" Then
    value = Mid(value, 2, Len(value) - 2)
  End If
  JsonGetString = value
End Function

Function JsonGetBool(json, key, defv)
  Dim str: str = JsonGetString(json, key, "")
  If str = "" Then
    JsonGetBool = defv
  ElseIf str = "true" Then
    JsonGetBool = True
  ElseIf str = "false" Then
    JsonGetBool = False
  Else
    JsonGetBool = defv
  End If
End Function

Function JsonGetInt(json, key, defv)
  Dim str: str = JsonGetString(json, key, "")
  If str = "" Then
    JsonGetInt = defv
  Else
    On Error Resume Next
    JsonGetInt = CLng(str)
    If Err.Number <> 0 Then
      Err.Clear
      JsonGetInt = defv
    End If
    On Error GoTo 0
  End If
End Function

Function HttpGetBytes(url, headers)
  Dim http: Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
  http.Open "GET", url, False
  Dim k
  For Each k In headers.Keys
    http.SetRequestHeader CStr(k), CStr(headers(k))
  Next
  http.Send
  If http.Status < 200 Or http.Status >= 300 Then
    DebugLog "GET failed status=" & http.Status
    HttpGetBytes = Null
    Exit Function
  End If
  HttpGetBytes = http.ResponseBody
End Function

Function HttpGetText(url, headers)
  Dim b: b = HttpGetBytes(url, headers)
  If IsNull(b) Then
    HttpGetText = ""
  Else
    HttpGetText = BytesToUtf8(b)
  End If
End Function

Function GetUploadToken(userToken, tokenUrl)
  Dim headers: Set headers = CreateObject("Scripting.Dictionary")
  headers.Add "token", userToken
  headers.Add "Content-Type", "application/json"
  Dim resp: resp = HttpGetText(tokenUrl, headers)
  DebugLog "qiniu-token body=" & resp
  If Len(resp) = 0 Then
    GetUploadToken = ""
    Exit Function
  End If
  ' parse code
  Dim posCode: posCode = InStr(resp, """code"":")
  Dim codev: codev = ""
  If posCode > 0 Then
    Dim idx: idx = posCode + Len("""code"":")
    Dim j: j = idx
    Do While j <= Len(resp) And Mid(resp, j, 1) = " "
      j = j + 1
    Loop
    Do While j <= Len(resp) And Mid(resp, j, 1) >= "0" And Mid(resp, j, 1) <= "9"
      codev = codev & Mid(resp, j, 1)
      j = j + 1
    Loop
  End If
  If codev <> "1" Then
    GetUploadToken = ""
    Exit Function
  End If

  ' parse token (prefer data.token)
  Dim tok: tok = ""
  Dim posData: posData = InStr(resp, """data""")
  If posData > 0 Then
    Dim posTok: posTok = InStr(posData, resp, """token"":")
    If posTok = 0 Then posTok = InStr(posData, resp, """token"" :")
    If posTok > 0 Then
      Dim k: k = posTok + Len("""token"":")
      If Mid(resp, k, 1) = " " Then k = k + 1
      If Mid(resp, k, 1) = """" Then k = k + 1
      Dim sb: sb = ""
      Do While k <= Len(resp) And Mid(resp, k, 1) <> """"
        sb = sb & Mid(resp, k, 1)
        k = k + 1
      Loop
      tok = sb
    End If
  End If
  If Len(tok) = 0 Then
    Dim posTok2: posTok2 = InStr(resp, """token"":")
    If posTok2 = 0 Then posTok2 = InStr(resp, """token"" :")
    If posTok2 > 0 Then
      Dim k2: k2 = posTok2 + Len("""token"":")
      If Mid(resp, k2, 1) = " " Then k2 = k2 + 1
      If Mid(resp, k2, 1) = """" Then k2 = k2 + 1
      Dim sb2: sb2 = ""
      Do While k2 <= Len(resp) And Mid(resp, k2, 1) <> """"
        sb2 = sb2 & Mid(resp, k2, 1)
        k2 = k2 + 1
      Loop
      tok = sb2
    End If
  End If

  GetUploadToken = tok
End Function

Function QueryUploadHost(uploadToken, bucket)
  Dim ak
  ak = uploadToken
  If InStr(ak, ":") > 0 Then ak = Split(ak, ":")(0)

  Dim url
  url = "https://api.qiniu.com/v4/query?ak=" & UrlEncode(ak) & "&bucket=" & UrlEncode(bucket)

  Dim headers: Set headers = CreateObject("Scripting.Dictionary")
  Dim resp: resp = HttpGetText(url, headers)
  If Len(resp) = 0 Then
    QueryUploadHost = DEFAULT_UPLOAD_HOST
    Exit Function
  End If

  Dim host
  ' parse domains[0] safely using Chr(34) for quotes
  Dim q: q = Chr(34)
  Dim posD: posD = InStr(resp, """domains""")
  If posD > 0 Then
    Dim posO: posO = InStr(posD, resp, "[")
    If posO > 0 Then
      Dim posQ1: posQ1 = InStr(posO, resp, q)
      If posQ1 > 0 Then
        Dim posQ2: posQ2 = InStr(posQ1 + 1, resp, q)
        If posQ2 > posQ1 Then
          host = Mid(resp, posQ1 + 1, posQ2 - posQ1 - 1)
        End If
      End If
    End If
  End If
  If Len(host) = 0 Then
    QueryUploadHost = DEFAULT_UPLOAD_HOST
    Exit Function
  End If
  host = Replace(host, "http://", "")
  host = Replace(host, "https://", "")
  If InStr(host, "/") > 0 Then host = Split(host, "/")(0)
  If Len(host) = 0 Then host = DEFAULT_UPLOAD_HOST
  QueryUploadHost = host
End Function

Function UrlEncode(s)
  Dim i, ch, code
  Dim out: out = ""
  For i = 1 To Len(s)
    ch = Mid(s, i, 1)
    code = AscW(ch)
    If (code >= 48 And code <= 57) Or (code >= 65 And code <= 90) Or (code >= 97 And code <= 122) Or ch = "-" Or ch = "_" Or ch = "." Or ch = "~" Then
      out = out & ch
    Else
      out = out & "%" & Right("0" & Hex(code), 2)
    End If
  Next
  UrlEncode = out
End Function

Function Md5HexFile(path)
  Dim tmp: tmp = sh.ExpandEnvironmentStrings("%TEMP%") & "\" & fso.GetTempName()
  Dim cmd
  cmd = "cmd /c certutil -hashfile """ & path & """ MD5 > """ & tmp & """"
  sh.Run cmd, 0, True
  Dim txt: txt = ReadAllTextUtf8(tmp)
  On Error Resume Next
  fso.DeleteFile tmp, True
  On Error GoTo 0

  Dim md5: md5 = ""
  Dim parts: parts = Split(txt, vbCrLf)
  Dim i
  For i = 0 To UBound(parts)
    Dim line: line = Trim(parts(i))
    ' lines from certutil look like: "d41d8cd98f00b204e9800998ecf8427e"
    If Len(line) = 32 Then
      md5 = LCase(line)
      Exit For
    End If
  Next
  Md5HexFile = md5
End Function

Function RunCwebp(inPath, outPath, q)
  Dim cmd
  cmd = "cmd /c cwebp -q " & CStr(q) & " """ & inPath & """ -o """ & outPath & """"
  Dim rc: rc = sh.Run(cmd, 0, True)
  RunCwebp = (rc = 0 And fso.FileExists(outPath))
End Function

Function MultipartUpload(uploadUrl, uploadToken, key, fileBytes, mimeType)
  Dim boundary: boundary = "----imgutil" & Replace(CStr(Timer * 1000), ".", "")

  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 1
  stm.Open

  WriteAscii stm, "--" & boundary & vbCrLf
  WriteAscii stm, "Content-Disposition: form-data; name=""token""" & vbCrLf & vbCrLf
  WriteAscii stm, uploadToken & vbCrLf

  WriteAscii stm, "--" & boundary & vbCrLf
  WriteAscii stm, "Content-Disposition: form-data; name=""key""" & vbCrLf & vbCrLf
  WriteAscii stm, key & vbCrLf

  WriteAscii stm, "--" & boundary & vbCrLf
  WriteAscii stm, "Content-Disposition: form-data; name=""file""; filename=""" & key & """" & vbCrLf
  WriteAscii stm, "Content-Type: " & mimeType & vbCrLf & vbCrLf
  stm.Write fileBytes
  WriteAscii stm, vbCrLf

  WriteAscii stm, "--" & boundary & "--" & vbCrLf
  stm.Position = 0

  Dim bodyBytes: bodyBytes = stm.Read
  stm.Close

  Dim http: Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
  http.Open "POST", uploadUrl, False
  http.SetRequestHeader "Content-Type", "multipart/form-data; boundary=" & boundary
  http.SetRequestHeader "User-Agent", "QiniuDart"
  http.Send bodyBytes

  MultipartUpload = http.Status & "\n" & BytesToUtf8(http.ResponseBody)
End Function

Sub WriteAscii(stm, s)
  Dim b
  b = StringToBytesAscii(s)
  stm.Write b
End Sub

Function StringToBytesAscii(s)
  Dim stm: Set stm = CreateObject("ADODB.Stream")
  stm.Type = 2
  stm.Charset = "windows-1252"
  stm.Open
  stm.WriteText s
  stm.Position = 0
  stm.Type = 1
  StringToBytesAscii = stm.Read
  stm.Close
End Function

Sub Main()
  Dim baseDir: baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
  Dim cfgPath: cfgPath = baseDir & "\config.json"
  If Not fso.FileExists(cfgPath) Then
    Die "找不到config.json，请在同目录创建"
  End If

  Dim cfgText: cfgText = ReadAllTextUtf8(cfgPath)

  Dim userToken: userToken = Trim(JsonGetString(cfgText, "user_token", ""))
  Dim enableWebp: enableWebp = JsonGetBool(cfgText, "enable_webp", False)
  Dim webpQuality: webpQuality = JsonGetInt(cfgText, "webp_quality", 95)
  Dim bucket: bucket = JsonGetString(cfgText, "bucket", "chat68")
  Dim tokenUrl: tokenUrl = JsonGetString(cfgText, "qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token")

  If Len(userToken) = 0 Then
    Die "config.json里的 user_token 为空"
  End If

  Dim input
  If WScript.Arguments.Count >= 1 Then
    input = WScript.Arguments(0)
  Else
    WScript.StdOut.Write "请输入图片地址(本地路径或URL): "
    input = WScript.StdIn.ReadLine
  End If
  input = TrimInput(input)
  If Len(input) = 0 Then
    Die "未输入图片地址"
  End If

  Dim srcPath: srcPath = input
  Dim tmpDownload: tmpDownload = sh.ExpandEnvironmentStrings("%TEMP%") & "\" & fso.GetTempName()

  If IsUrl(input) Then
    Dim b
    b = HttpGetBytes(input, CreateObject("Scripting.Dictionary"))
    If IsNull(b) Then
      Die "上传失败: download failed"
    End If
    WriteAllBytes tmpDownload, b
    srcPath = tmpDownload
  End If

  If Not fso.FileExists(srcPath) Then
    Die "上传失败: could not read file"
  End If

  Dim upPath: upPath = srcPath
  Dim ext: ext = "bin"
  Dim dot: dot = InStrRev(srcPath, ".")
  If dot > 0 Then ext = Mid(srcPath, dot + 1)

  If enableWebp Then
    Dim outWebp: outWebp = sh.ExpandEnvironmentStrings("%TEMP%") & "\" & fso.GetTempName() & ".webp"
    If webpQuality <= 0 Or webpQuality > 100 Then webpQuality = 95
    If Not RunCwebp(srcPath, outWebp, webpQuality) Then
      Die "上传失败: cwebp failed (install cwebp or set enable_webp=false)"
    End If
    upPath = outWebp
    ext = "webp"
  End If

  Dim md5: md5 = Md5HexFile(upPath)
  If Len(md5) = 0 Then
    Die "上传失败: md5 failed"
  End If

  Dim key: key = md5 & "." & ext

  Dim uploadToken: uploadToken = GetUploadToken(userToken, tokenUrl)
  If Len(uploadToken) = 0 Then
    Die "上传失败: qiniu-token failed"
  End If

  Dim host: host = QueryUploadHost(uploadToken, bucket)
  Dim uploadUrl: uploadUrl = "https://" & host

  Dim fileBytes: fileBytes = ReadAllBytes(upPath)
  Dim mimeType: mimeType = "application/octet-stream"
  If LCase(ext) = "webp" Then mimeType = "image/webp"

  Dim result: result = MultipartUpload(uploadUrl, uploadToken, key, fileBytes, mimeType)
  Dim statusLine: statusLine = Split(result, "\n")(0)
  Dim body: body = Mid(result, Len(statusLine) + 2)

  If CLng(statusLine) < 200 Or CLng(statusLine) >= 300 Then
    If InStr(body, "no such domain") > 0 Then
      result = MultipartUpload("https://" & DEFAULT_UPLOAD_HOST, uploadToken, key, fileBytes, mimeType)
      statusLine = Split(result, "\n")(0)
      body = Mid(result, Len(statusLine) + 2)
    End If
  End If

  If CLng(statusLine) < 200 Or CLng(statusLine) >= 300 Then
    Die "上传失败: qiniu upload failed: " & statusLine & " " & body
  End If

  WScript.Echo "上传成功"
  WScript.Echo "response_json:"
  WScript.Echo body

  On Error Resume Next
  If IsUrl(input) Then fso.DeleteFile tmpDownload, True
  If enableWebp And upPath <> srcPath Then fso.DeleteFile upPath, True
  On Error GoTo 0
End Sub

Main
