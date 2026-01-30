# ActionScript 3 (AIR)

This folder is an Adobe AIR desktop app skeleton.

What it does:

- Select a local image (FileReference)
- Fetch qiniu upload token
- Query upload host
- Multipart upload using `URLRequest` with a manually-built multipart body

Limitations:

- WebP conversion is not implemented (AIR would need a native extension or external tool)
- MD5 key naming is not implemented (requires an MD5 implementation)

Files:

- `src/Main.as`
- `src/MultipartFormData.as`
- `air/application.xml`

Build (concept):

```bash
adt -package -storetype pkcs12 -keystore your.p12 -storepass pass \
  ImgUtil.air air/application.xml -C bin Main.swf
```
