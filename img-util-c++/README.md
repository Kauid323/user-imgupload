- Difference:
img-util-c的可以在运行该工具后输入路径上传图片，和加参数运行（就是后面加"<image_path_or_url>"）而这个只能
```powershell
img-util-cpp.exe "<image_path_or_url>"
```


Run (Windows, CMake + libcurl):

- Install libcurl (example with vcpkg):

```powershell
vcpkg install curl
```

- Configure & build:

```powershell
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=<path-to-vcpkg>/scripts/buildsystems/vcpkg.cmake
cmake --build build --config Release
```

- Run:

```powershell
.\build\Release\img-util-cpp.exe "<image_path_or_url>"
```

If you omit the argument, the program will prompt for input.

Config: edit `config.json` (same fields as python version).

Note: If `enable_webp=true`, this tool calls external `cwebp`.
