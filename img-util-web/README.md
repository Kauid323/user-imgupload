Run (HTML/Browser):

This is a pure front-end implementation.

Important limitations:

- You must serve the folder via a local HTTP server (opening index.html directly may block fetching config.json due to browser security).
- Fetching an image URL requires the remote server to allow CORS.
- Calling `qiniu_token_url`, `api.qiniu.com`, and uploading to Qiniu from the browser may be blocked by CORS depending on server settings. If you hit CORS errors, use a small proxy server (or use the CLI versions).

How to run:

- Option A (Node):

```bash
npx http-server . -p 5173
```

- Option B (Python):

```bash
python -m http.server 5173
```

Then open:

- http://127.0.0.1:5173/

Config:

- Edit `config.json`.

WebP:

- If enable_webp=true, the browser will convert using Canvas to WebP.
