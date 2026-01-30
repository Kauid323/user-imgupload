# Ada version (skeleton + curl driven)

This is a minimal Ada CLI that drives the same flow by calling external tools:

- `curl` for HTTP requests / upload
- `md5sum` or `md5` for MD5
- optional `cwebp` if enable_webp=true

Files:

- `main.adb`: entry point
- `config.json`: example config

Build requires GNAT/Alire.
