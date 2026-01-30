Run (Objective-C CLI)

Dependencies:

- clang (macOS) or GNUstep clang
- Foundation
- cwebp (optional, only if enable_webp=true)

Config:

- Edit `config.json`

Build (macOS):

```bash
clang -fobjc-arc -framework Foundation main.m -o img-util-objc
```

Run:

```bash
./img-util-objc "<image_path_or_url>"
```

Debug:

```bash
IMGUTIL_DEBUG=1 ./img-util-objc "<image_path_or_url>"
```

Notes:

- This tool reads `config.json` from the current working directory.
- If `enable_webp=true`, it calls external `cwebp`.
