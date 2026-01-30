Run (Lua, minimal external deps):

Dependencies:

- lua (5.1+ recommended)
- curl (required)
- cwebp (optional, only if enable_webp=true)

Config:

- Edit `config.json` (same fields as python version).

Run:

```bash
lua main.lua "<image_path_or_url>"
```

If you omit the argument, the program will prompt for input.
