Run (VBScript)

Dependencies:

- Windows `cscript.exe`
- `certutil` (built-in) for MD5
- `cwebp` (optional, only if enable_webp=true)

Config:

- Edit `config.json` (same fields as python version)

Run:

```bat
cscript //nologo main.vbs
```

Or pass input:

```bat
cscript //nologo main.vbs "C:\path\to\image.png"
```

Debug:

```bat
set IMGUTIL_DEBUG=1
cscript //nologo main.vbs "C:\path\to\image.png"
```
