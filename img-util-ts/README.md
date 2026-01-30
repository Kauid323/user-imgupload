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
npm run start -- "C:\Users\admin\Pictures\xxx.png"
```

Or dev mode:

```bash
npm run dev -- "C:\Users\admin\Pictures\xxx.png"
```

If you omit the argument, the program will prompt for input.

Config: edit `config.json`

Note: If `enable_webp=true`, this tool calls external `cwebp`.
