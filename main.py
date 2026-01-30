import json
import os
import sys

from qiniu_uploader import load_config, upload_image


def _prompt_input() -> str:
    s = input("请输入图片地址(本地路径或URL): ").strip()
    return s


def main() -> int:
    base_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(base_dir, "config.json")

    try:
        cfg = load_config(config_path)
    except FileNotFoundError:
        print("找不到config.json，请在同目录创建")
        return 1
    except json.JSONDecodeError as e:
        print(f"config.json格式错误: {e}")
        return 1

    user_token = str(cfg.get("user_token", "")).strip()
    if not user_token:
        print("config.json里的 user_token 为空")
        return 1

    enable_webp = bool(cfg.get("enable_webp", True))
    webp_quality = int(cfg.get("webp_quality", 95))
    bucket = str(cfg.get("bucket", "chat68"))
    qiniu_token_url = str(cfg.get("qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token"))

    path_or_url = _prompt_input()
    if not path_or_url:
        print("未输入图片地址")
        return 1

    try:
        result = upload_image(
            path_or_url=path_or_url,
            user_token=user_token,
            enable_webp=enable_webp,
            webp_quality=webp_quality,
            bucket=bucket,
            qiniu_token_url=qiniu_token_url,
        )
    except Exception as e:
        print(f"上传失败: {e}")
        return 1

    print("上传成功")
    print(f"key: {result.key}")
    print(f"hash: {result.hash}")
    print(f"fsize: {result.fsize}")
    print("response_json:")
    print(json.dumps(result.raw, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
