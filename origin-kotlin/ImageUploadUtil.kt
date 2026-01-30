package com.yhchat.canary.utils

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import com.yhchat.canary.data.api.QiniuUploadResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * 图片上传工具类
 * 参考Python实现：tool.py中的upload方法
 */
object ImageUploadUtil {
    
    private const val TAG = "ImageUploadUtil"
    
    // 七牛bucket映射
    private const val IMAGE_BUCKET = "chat68"
    
    private val client = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()
    
    /**
     * 压缩图片为WebP格式
     * @param context 上下文
     * @param imageUri 原始图片URI
     * @param quality 压缩质量 (0-100)
     * @return 压缩后的字节数组
     */
    private suspend fun compressToWebP(
        context: Context,
        imageUri: Uri,
        quality: Int = 95
    ): ByteArray = withContext(Dispatchers.IO) {
        Log.d(TAG, "🗜️ 开始压缩图片为WebP格式，质量: $quality%")
        
        // 读取原始图片
        val inputStream = context.contentResolver.openInputStream(imageUri)
            ?: throw Exception("无法读取图片")
        
        val originalBitmap = BitmapFactory.decodeStream(inputStream)
        inputStream.close()
        
        if (originalBitmap == null) {
            throw Exception("无法解码图片")
        }
        
        Log.d(TAG, "✅ 原始图片尺寸: ${originalBitmap.width}x${originalBitmap.height}")
        
        // 压缩为WebP格式
        val outputStream = java.io.ByteArrayOutputStream()
        val success = originalBitmap.compress(Bitmap.CompressFormat.WEBP, quality, outputStream)
        
        if (!success) {
            originalBitmap.recycle()
            throw Exception("WebP压缩失败")
        }
        
        val compressedBytes = outputStream.toByteArray()
        originalBitmap.recycle()
        outputStream.close()
        
        Log.d(TAG, "✅ WebP压缩完成，压缩后大小: ${compressedBytes.size} bytes")
        
        compressedBytes
    }

    /**
     * 上传图片到七牛云（自动压缩为WebP格式）
     * 参考Python实现：tool.py中的upload方法
     * @param context 上下文
     * @param imageUri 图片URI
     * @param uploadToken 七牛上传token
     * @return 上传结果，包含key、hash等信息
     */
    suspend fun uploadImage(
        context: Context,
        imageUri: Uri,
        uploadToken: String
    ): Result<QiniuUploadResponse> = withContext(Dispatchers.IO) {
        try {
            Log.d(TAG, "📤 ========== 开始上传图片 ==========")
            Log.d(TAG, "📤 图片URI: $imageUri")
            
            // 1. 获取WebP压缩质量设置
            val sharedPrefs = context.getSharedPreferences("image_settings", Context.MODE_PRIVATE)
            val webpQuality = sharedPrefs.getInt("webp_quality", 95)
            
            // 2. 压缩图片为WebP格式
            val imageBytes = compressToWebP(context, imageUri, webpQuality)
            
            Log.d(TAG, "✅ WebP压缩完成，大小: ${imageBytes.size} bytes")
            
            // 3. 计算MD5 - 参考Python: md5.hexdigest()
            val md5 = calculateMD5(imageBytes)
            Log.d(TAG, "✅ MD5计算完成: $md5")
            
            // 4. 设置为WebP格式
            val mimeType = "image/webp"
            val extension = "webp"
            
            // 文件key = MD5.扩展名
            val fileKey = "$md5.$extension"
            Log.d(TAG, "✅ 文件key: $fileKey")
            Log.d(TAG, "✅ MIME类型: $mimeType")
            
            // 5. 获取图片尺寸
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, options)
            val width = options.outWidth
            val height = options.outHeight
            Log.d(TAG, "✅ 图片尺寸: ${width}x${height}")
            
            // 6. 获取上传host - 参考Python实现
            // uhost = httpx.get(f"https://api.qiniu.com/v4/query?ak={utoken.split(':')[0]}&bucket={bucket}").json()["hosts"][0]["up"]["domains"][0]
            val ak = uploadToken.split(":")[0]
            val queryUrl = "https://api.qiniu.com/v4/query?ak=$ak&bucket=$IMAGE_BUCKET"
            Log.d(TAG, "📤 查询上传host: $queryUrl")
            
            val queryRequest = Request.Builder()
                .url(queryUrl)
                .get()
                .build()
            
            val queryResponse = client.newCall(queryRequest).execute()
            val uploadHost = if (queryResponse.isSuccessful) {
                val queryJson = JSONObject(queryResponse.body?.string() ?: "{}")
                val hosts = queryJson.getJSONArray("hosts")
                val host = hosts.getJSONObject(0)
                val up = host.getJSONObject("up")
                val domains = up.getJSONArray("domains")
                domains.getString(0)
            } else {
                Log.w(TAG, "⚠️ 查询host失败，使用默认: upload-z2.qiniup.com")
                "upload-z2.qiniup.com"
            }
            
            Log.d(TAG, "✅ 上传host: $uploadHost")
            
            // 7. 保存图片到临时文件
            val cacheDir = context.cacheDir
            val tempFile = File(cacheDir, fileKey)
            FileOutputStream(tempFile).use { outputStream ->
                outputStream.write(imageBytes)
            }
            Log.d(TAG, "✅ 临时文件: ${tempFile.absolutePath}")
            
            // 8. 构建multipart/form-data请求 - 参考Python实现
            // params = {
            //     "token": (None, utoken),
            //     "key": (None, name),
            //     "file": (name, file)
            // }
            val requestBody = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart("token", uploadToken)
                .addFormDataPart("key", fileKey)
                .addFormDataPart(
                    "file",
                    fileKey,
                    tempFile.asRequestBody(mimeType.toMediaTypeOrNull())
                )
                .build()
            
            Log.d(TAG, "📤 开始上传到七牛云...")
            Log.d(TAG, "📤 上传URL: https://$uploadHost")
            
            val request = Request.Builder()
                .url("https://$uploadHost")
                .addHeader("user-agent", "QiniuDart")
                .addHeader("accept-encoding", "gzip")
                .post(requestBody)
                .build()
            
            // 9. 执行上传
            val response = client.newCall(request).execute()
            
            Log.d(TAG, "📥 七牛云响应码: ${response.code}")
            
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                Log.d(TAG, "✅ 上传成功！响应: $responseBody")
                
                if (responseBody != null) {
                    val json = JSONObject(responseBody)
                    
                    // 解析响应
                    val uploadResponse = QiniuUploadResponse(
                        key = json.getString("key"),
                        hash = json.getString("hash"),
                        fsize = json.getLong("fsize"),
                        avinfo = if (json.has("avinfo")) {
                            val avinfo = json.getJSONObject("avinfo")
                            val videoInfo = if (avinfo.has("video")) {
                                val video = avinfo.getJSONObject("video")
                                com.yhchat.canary.data.api.QiniuVideoInfo(
                                    width = video.optInt("width", width),
                                    height = video.optInt("height", height)
                                )
                            } else null
                            com.yhchat.canary.data.api.QiniuAvInfo(video = videoInfo)
                        } else {
                            // 如果没有avinfo，使用BitmapFactory获取的尺寸
                            com.yhchat.canary.data.api.QiniuAvInfo(
                                video = com.yhchat.canary.data.api.QiniuVideoInfo(
                                    width = width,
                                    height = height
                                )
                            )
                        }
                    )
                    
                    Log.d(TAG, "✅ ========== 上传完成 ==========")
                    Log.d(TAG, "✅ key: ${uploadResponse.key}")
                    Log.d(TAG, "✅ hash: ${uploadResponse.hash}")
                    Log.d(TAG, "✅ size: ${uploadResponse.fsize}")
                    
                    // 清理临时文件
                    tempFile.delete()
                    
                    Result.success(uploadResponse)
                } else {
                    Log.e(TAG, "❌ 响应体为空")
                    tempFile.delete()
                    Result.failure(Exception("上传失败：响应为空"))
                }
            } else {
                val errorBody = response.body?.string()
                Log.e(TAG, "❌ 上传失败: ${response.code}")
                Log.e(TAG, "❌ 错误详情: $errorBody")
                tempFile.delete()
                Result.failure(Exception("上传失败: ${response.code}"))
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ 上传异常", e)
            e.printStackTrace()
            Result.failure(e)
        }
    }
    
    /**
     * 获取七牛云上传token
     */
    suspend fun getQiniuUploadToken(context: Context, token: String): String = withContext(Dispatchers.IO) {
        try {
            Log.d(TAG, "🔑 开始获取七牛云上传token")
            Log.d(TAG, "🔑 用户token: ${token.take(10)}...")
            
            val request = Request.Builder()
                .url("https://chat-go.jwzhd.com/v1/misc/qiniu-token")
                .addHeader("token", token)
                .addHeader("Content-Type", "application/json")
                .get()
                .build()
            
            Log.d(TAG, "🔑 发送请求到: ${request.url}")
            
            val response = client.newCall(request).execute()
            val responseCode = response.code
            val responseBody = response.body?.string()
            
            Log.d(TAG, "🔑 响应码: $responseCode")
            Log.d(TAG, "🔑 响应体: $responseBody")
            
            if (response.isSuccessful && responseBody != null) {
                val jsonObject = JSONObject(responseBody)
                val code = jsonObject.optInt("code", 0)
                if (code == 1) {
                    val dataObject = jsonObject.optJSONObject("data")
                    val uploadToken = dataObject?.optString("token", null)
                    Log.d(TAG, "🔑 获取到上传token: ${uploadToken?.take(20)}...")
                    uploadToken ?: ""
                } else {
                    val msg = jsonObject.optString("msg", "未知错误")
                    Log.e(TAG, "🔑 API返回错误: code=$code, msg=$msg")
                    ""
                }
            } else {
                Log.e(TAG, "🔑 获取token失败: $responseCode - $responseBody")
                ""
            }
        } catch (e: Exception) {
            Log.e(TAG, "🔑 获取token异常: ${e.message}", e)
            ""
        }
    }
    
    /**
     * 计算字节数组的MD5值
     */
    private fun calculateMD5(bytes: ByteArray): String {
        val md5Digest = MessageDigest.getInstance("MD5")
        val md5Bytes = md5Digest.digest(bytes)
        return md5Bytes.joinToString("") { "%02x".format(it) }
    }
}

