# 云湖图片上传工具（用户api）

## 配置文件（config.json）

```json
{
  "user_token": "64c19a25-r....", // 填写你的用户token（云湖的是随机UUID4）
  "enable_webp": false, // 是否启用webp压缩
  "webp_quality": 95, // webp质量 (0-100)
  "bucket": "chat68", // 存储桶名称
  "qiniu_token_url": "https://chat-go.jwzhd.com/v1/misc/qiniu-token" // 七牛云图片上传token获取地址
}
```

目前正在语言补完计划，欢迎pr