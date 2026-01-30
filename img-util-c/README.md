Run (Windows, CMake + libcurl):

已编译好的：[img-util-c.exe](/build64/Release/img-util-c.exe)

- Install libcurl (example with vcpkg):

```powershell
vcpkg install curl
```

- Configure & build:

```powershell
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=<path-to-vcpkg>/scripts/buildsystems/vcpkg.cmake
cmake --build build --config Release
```
- Install curl:
In vcpkg directory,run:
```powershell
.\vcpkg install curl:x64-windows
```

- Run:

```powershell
.\build\Release\img-util-c.exe
```

Config: edit `config.json` (same fields as python version).

Note: If `enable_webp=true`, this tool calls external `cwebp`.
