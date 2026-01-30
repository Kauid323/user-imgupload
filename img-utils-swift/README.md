Run (macOS, SwiftPM):

- Build:

```bash
swift build -c release
```

- Run:

```bash
swift run -c release img-util-swift "<image_path_or_url>"
```

If you omit the argument, the program will prompt for input.

Config: edit `config.json` (same fields as python version).

Note: If `enable_webp=true`, this tool calls external `cwebp`.
