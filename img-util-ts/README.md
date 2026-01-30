Run (TypeScript, Node.js):

Dependencies:

- Node.js 18+

Install:

```bash
npm install
```

Run:

```bash
npm run build
npm run start -- "<image_path_or_url>"
```

Or dev mode:

```bash
npm run dev -- "<image_path_or_url>"
```

If you omit the argument, the program will prompt for input.

Config: edit `config.json` (same fields as python version).

Note: If `enable_webp=true`, this tool calls external `cwebp`.
