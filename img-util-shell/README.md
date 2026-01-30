Run (Shell/Bash):

Dependencies:

- bash
- curl
- md5sum (Linux) or md5 (macOS)
- jq (recommended for JSON parsing/pretty print)
- cwebp (optional, only if enable_webp=true)

Run:

```bash
bash main.sh "<image_path_or_url>"
```

If you omit the argument, the script will prompt for input.

Config: edit `config.json`.
