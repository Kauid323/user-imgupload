param(
  [string]$ImageInput = "",
  [switch]$PickFile
)

$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$DefaultUploadHost = "upload-z2.qiniup.com"

function Normalize-Input([string]$s) {
  $t = $s.Trim()
  while ($t.EndsWith("+")) {
    $t = $t.Substring(0, $t.Length - 1).TrimEnd()
  }
  if ($t.Length -ge 2) {
    $a = $t[0]
    $b = $t[$t.Length - 1]
    if (($a -eq '"' -and $b -eq '"') -or ($a -eq "'" -and $b -eq "'")) {
      $t = $t.Substring(1, $t.Length - 2)
    }
  }
  return $t
}

function Load-Config([string]$path) {
  if (!(Test-Path $path)) { throw "找不到config.json，请在同目录创建" }
  $obj = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json

  $bucket = "chat68"
  if ($null -ne $obj.bucket -and -not [string]::IsNullOrWhiteSpace([string]$obj.bucket)) {
    $bucket = [string]$obj.bucket
  }

  $qiniuTokenUrl = "https://chat-go.jwzhd.com/v1/misc/qiniu-token"
  if ($null -ne $obj.qiniu_token_url -and -not [string]::IsNullOrWhiteSpace([string]$obj.qiniu_token_url)) {
    $qiniuTokenUrl = [string]$obj.qiniu_token_url
  }

  return [pscustomobject]@{
    user_token = [string]$obj.user_token
    enable_webp = [bool]$obj.enable_webp
    webp_quality = [int]$obj.webp_quality
    bucket = $bucket
    qiniu_token_url = $qiniuTokenUrl
  }
}

function Invoke-HttpGet([string]$Url, [hashtable]$Headers = $null) {
  $params = @{ Uri = $Url; Method = 'GET'; TimeoutSec = 60 }
  if ($Headers) { $params.Headers = $Headers }
  try {
    $resp = Invoke-WebRequest @params
    return @{ Status = [int]$resp.StatusCode; Body = [string]$resp.Content }
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode.value__
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $body = $reader.ReadToEnd()
      return @{ Status = $status; Body = $body }
    }
    throw
  }
}

function Download-Bytes([string]$Url) {
  $params = @{ Uri = $Url; Method = 'GET'; TimeoutSec = 60 }
  $resp = Invoke-WebRequest @params
  return ,$resp.Content
}

function Run-Cwebp([byte[]]$Bytes, [int]$Quality) {
  $q = $Quality
  if ($q -le 0 -or $q -gt 100) { $q = 95 }

  $tmp = [System.IO.Path]::GetTempPath()
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $in = Join-Path $tmp "imgutil_$t.input"
  $out = Join-Path $tmp "imgutil_$t.webp"

  [System.IO.File]::WriteAllBytes($in, $Bytes)

  $p = Start-Process -FilePath "cwebp" -ArgumentList @('-q', "$q", $in, '-o', $out) -NoNewWindow -PassThru -Wait -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $in -Force -ErrorAction SilentlyContinue

  if (!$p -or $p.ExitCode -ne 0 -or !(Test-Path $out)) {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    throw "上传失败: cwebp failed (install cwebp or set enable_webp=false)"
  }

  $wb = [System.IO.File]::ReadAllBytes($out)
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  return $wb
}

function Md5-Hex([byte[]]$Bytes) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $hash = $md5.ComputeHash($Bytes)
  return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-QiniuUploadToken([string]$UserToken, [string]$TokenUrl) {
  $body = ""
  $status = 0

  try {
    $r = Invoke-HttpGet -Url $TokenUrl -Headers @{ token = $UserToken; 'Content-Type' = 'application/json' }
    $status = [int]$r.Status
    $body = [string]$r.Body
  } catch {
    $status = 0
    $body = ""
  }

  if ($status -lt 200 -or $status -ge 300 -or [string]::IsNullOrWhiteSpace($body)) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
      $curlOut = & curl.exe -sS $TokenUrl -H "token: $UserToken" -H "Content-Type: application/json"
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$curlOut)) {
        $body = [string]$curlOut
        $status = 200
      }
    }
  }

  if ($status -lt 200 -or $status -ge 300 -or [string]::IsNullOrWhiteSpace($body)) {
    if ($env:IMGUTIL_DEBUG -eq '1') {
      Write-Host "[debug] qiniu-token failed: status=$status"
      Write-Host "[debug] qiniu-token body=$body"
    }
    return ""
  }

  try {
    $obj = $body | ConvertFrom-Json
    if ($obj.code -ne 1) {
      if ($env:IMGUTIL_DEBUG -eq '1') {
        Write-Host "[debug] qiniu-token bad code=$($obj.code)"
        Write-Host "[debug] qiniu-token body=$body"
      }
      return ""
    }
    if ($null -ne $obj.data -and $null -ne $obj.data.token -and -not [string]::IsNullOrWhiteSpace([string]$obj.data.token)) {
      return [string]$obj.data.token
    }
    if ($null -ne $obj.token -and -not [string]::IsNullOrWhiteSpace([string]$obj.token)) {
      return [string]$obj.token
    }
    if ($env:IMGUTIL_DEBUG -eq '1') {
      Write-Host "[debug] qiniu-token missing token field"
      Write-Host "[debug] qiniu-token body=$body"
    }
    return ""
  } catch {
    if ($env:IMGUTIL_DEBUG -eq '1') {
      Write-Host "[debug] qiniu-token JSON parse failed"
      Write-Host "[debug] qiniu-token body=$body"
    }
    return ""
  }
}

function Query-UploadHost([string]$UploadToken, [string]$Bucket) {
  $ak = ($UploadToken -split ':')[0]
  $url = "https://api.qiniu.com/v4/query?ak=$([uri]::EscapeDataString($ak))&bucket=$([uri]::EscapeDataString($Bucket))"
  try {
    $r = Invoke-HttpGet -Url $url
    if ($r.Status -lt 200 -or $r.Status -ge 300) { return $DefaultUploadHost }
    $obj = $r.Body | ConvertFrom-Json
    if ($obj.domains -and $obj.domains.Count -gt 0) {
      $h = [string]$obj.domains[0]
      $h = $h -replace '^https?://', ''
      $h = $h -replace '/.*$', ''
      if ($h) { return $h }
    }
    return $DefaultUploadHost
  } catch {
    return $DefaultUploadHost
  }
}

function Upload-Once([string]$UploadUrl, [string]$UploadToken, [string]$Key, [byte[]]$Bytes, [string]$MimeType) {
  $boundary = "----imgutil$([guid]::NewGuid().ToString('N'))"

  $crlf = "`r`n"
  $ms = New-Object System.IO.MemoryStream
  $sw = New-Object System.IO.StreamWriter($ms, (New-Object System.Text.UTF8Encoding($false)))

  $sw.Write("--$boundary$crlf")
  $sw.Write("Content-Disposition: form-data; name=`"token`"$crlf$crlf")
  $sw.Write($UploadToken)
  $sw.Write($crlf)

  $sw.Write("--$boundary$crlf")
  $sw.Write("Content-Disposition: form-data; name=`"key`"$crlf$crlf")
  $sw.Write($Key)
  $sw.Write($crlf)

  $sw.Write("--$boundary$crlf")
  $sw.Write("Content-Disposition: form-data; name=`"file`"; filename=`"$Key`"$crlf")
  $sw.Write("Content-Type: $MimeType$crlf$crlf")
  $sw.Flush()

  $ms.Write($Bytes, 0, $Bytes.Length)

  $sw.Write($crlf)
  $sw.Write("--$boundary--$crlf")
  $sw.Flush()

  $bodyBytes = $ms.ToArray()

  try {
    $resp = Invoke-WebRequest -Uri $UploadUrl -Method Post -TimeoutSec 120 -Headers @{ 'User-Agent' = 'QiniuDart' } -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyBytes
    return @{ Ok = $true; Status = [int]$resp.StatusCode; Body = [string]$resp.Content }
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode.value__
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $body = $reader.ReadToEnd()
      return @{ Ok = $false; Status = $status; Body = $body }
    }
    return @{ Ok = $false; Status = 0; Body = [string]$_.Exception.Message }
  }
}

$cfg = Load-Config -path (Join-Path $PSScriptRoot 'config.json')
if ([string]::IsNullOrWhiteSpace($cfg.user_token)) { throw "config.json里的 user_token 为空" }

if ($PickFile) {
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "选择要上传的图片"
    $ofd.Filter = "Images|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.gif;*.tif;*.tiff|All files|*.*"
    $ofd.Multiselect = $false
    $null = $ofd.ShowDialog()
    if (-not [string]::IsNullOrWhiteSpace($ofd.FileName)) {
      $ImageInput = $ofd.FileName
    }
  } catch {
    throw "无法打开文件选择器：$($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($ImageInput)) {
  $ImageInput = Read-Host "请输入图片地址(本地路径或URL)"
}
$ImageInput = Normalize-Input $ImageInput
if ([string]::IsNullOrWhiteSpace($ImageInput)) { throw "未输入图片地址" }

if ($env:IMGUTIL_DEBUG -eq '1') {
  Write-Host "[debug] ImageInput=$ImageInput"
  Write-Host "[debug] ImageInput.Length=$($ImageInput.Length)"
}

[byte[]]$origBytes = $null
[string]$name = "image"

if ($ImageInput.StartsWith('http://') -or $ImageInput.StartsWith('https://')) {
  $resp = Invoke-WebRequest -Uri $ImageInput -Method Get -TimeoutSec 60
  $origBytes = $resp.Content
  try { $name = ([uri]$ImageInput).Segments[-1] } catch {}
} else {
  if ($env:IMGUTIL_DEBUG -eq '1') {
    Write-Host "[debug] Test-Path(LiteralPath)=$(Test-Path -LiteralPath $ImageInput)"
  }
  if (!(Test-Path -LiteralPath $ImageInput)) { throw "上传失败: could not read file" }
  $origBytes = [System.IO.File]::ReadAllBytes($ImageInput)
  $name = [System.IO.Path]::GetFileName($ImageInput)
}

[byte[]]$uploadBytes = $origBytes
[string]$mimeType = 'application/octet-stream'
[string]$ext = 'bin'

if ($cfg.enable_webp) {
  $uploadBytes = Run-Cwebp -Bytes $origBytes -Quality $cfg.webp_quality
  $mimeType = 'image/webp'
  $ext = 'webp'
} else {
  $dot = $name.LastIndexOf('.')
  if ($dot -ge 0 -and $dot + 1 -lt $name.Length) { $ext = $name.Substring($dot + 1) }
}

$key = "$(Md5-Hex $uploadBytes).$ext"

$uploadToken = Get-QiniuUploadToken -UserToken $cfg.user_token -TokenUrl $cfg.qiniu_token_url
if ([string]::IsNullOrWhiteSpace($uploadToken)) { throw "上传失败: qiniu-token failed" }

$uploadHost = Query-UploadHost -UploadToken $uploadToken -Bucket $cfg.bucket
$uploadUrl = "https://$uploadHost"

$r = Upload-Once -UploadUrl $uploadUrl -UploadToken $uploadToken -Key $key -Bytes $uploadBytes -MimeType $mimeType

if ($env:IMGUTIL_DEBUG -eq '1') {
  Write-Host "[debug] upload status=$($r.Status)"
  Write-Host "[debug] upload body=$($r.Body)"
}

if (-not $r.Ok -or $r.Status -lt 200 -or $r.Status -ge 300) {
  if ($r.Body -like '*no such domain*') {
    $uploadUrl = "https://$DefaultUploadHost"
    $r = Upload-Once -UploadUrl $uploadUrl -UploadToken $uploadToken -Key $key -Bytes $uploadBytes -MimeType $mimeType

    if ($env:IMGUTIL_DEBUG -eq '1') {
      Write-Host "[debug] retry upload status=$($r.Status)"
      Write-Host "[debug] retry upload body=$($r.Body)"
    }
  }
}

if (-not $r.Ok -or $r.Status -lt 200 -or $r.Status -ge 300) {
  throw "上传失败: qiniu upload failed: $($r.Status) $($r.Body)"
}

Write-Host "上传成功"
Write-Host "response_json:"
try {
  $obj = $r.Body | ConvertFrom-Json
  $obj | ConvertTo-Json -Depth 30
} catch {
  Write-Host $r.Body
}
