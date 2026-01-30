using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

record Config(
    string user_token,
    bool enable_webp,
    int webp_quality,
    string bucket,
    string qiniu_token_url
);

static class Program
{
    private const string DefaultUploadHost = "upload-z2.qiniup.com";

    public static async Task<int> Main(string[] args)
    {
        try
        {
            try
            {
                Console.InputEncoding = Encoding.UTF8;
                Console.OutputEncoding = Encoding.UTF8;
            }
            catch
            {
            }

            var baseDir = GetProgramDir();
            var configPath = Path.Combine(baseDir, "config.json");
            if (!File.Exists(configPath))
            {
                Console.WriteLine($"找不到config.json，请在同目录创建: {configPath}");
                return 1;
            }

            var cfgText = await File.ReadAllTextAsync(configPath, Encoding.UTF8);
            var cfg = JsonSerializer.Deserialize<Config>(cfgText, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
            if (cfg is null)
            {
                Console.WriteLine("config.json格式错误");
                return 1;
            }

            var userToken = (cfg.user_token ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(userToken))
            {
                Console.WriteLine("config.json里的 user_token 为空");
                return 1;
            }

            var enableWebp = cfg.enable_webp;
            var webpQuality = cfg.webp_quality <= 0 || cfg.webp_quality > 100 ? 95 : cfg.webp_quality;
            var bucket = string.IsNullOrWhiteSpace(cfg.bucket) ? "chat68" : cfg.bucket;
            var qiniuTokenUrl = string.IsNullOrWhiteSpace(cfg.qiniu_token_url)
                ? "https://chat-go.jwzhd.com/v1/misc/qiniu-token"
                : cfg.qiniu_token_url;

            string pathOrUrl;
            if (args.Length > 0 && !string.IsNullOrWhiteSpace(args[0]))
            {
                pathOrUrl = NormalizePathOrUrl(args[0]);
            }
            else
            {
                Console.Write("请输入图片地址(本地路径或URL): ");
                pathOrUrl = NormalizePathOrUrl(Console.ReadLine() ?? string.Empty);
            }

            if (string.IsNullOrWhiteSpace(pathOrUrl))
            {
                Console.WriteLine("未输入图片地址");
                return 1;
            }

            var input = await ReadInputAsync(pathOrUrl);

            byte[] uploadBytes;
            string mimeType;
            string ext;

            if (enableWebp)
            {
                uploadBytes = await ToWebpViaCwebpAsync(input.Bytes, webpQuality);
                mimeType = "image/webp";
                ext = "webp";
            }
            else
            {
                uploadBytes = input.Bytes;
                mimeType = input.ContentType ?? "application/octet-stream";
                ext = GetExtFromNameOrMime(input.Name, mimeType);
            }

            var key = $"{Md5Hex(uploadBytes)}.{ext}";

            var http = new HttpClient(new HttpClientHandler
            {
                AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate
            });

            var uploadToken = await GetQiniuUploadTokenAsync(http, userToken, qiniuTokenUrl);
            var host = NormalizeHost(await QueryUploadHostAsync(http, uploadToken, bucket));
            var uploadUrl = $"https://{host}";

            string respText;
            try
            {
                respText = await UploadOnceAsync(http, uploadUrl, uploadToken, key, uploadBytes, mimeType);
            }
            catch (HttpRequestException ex) when (ex.Message.Contains("no such domain", StringComparison.OrdinalIgnoreCase))
            {
                respText = await UploadOnceAsync(http, $"https://{DefaultUploadHost}", uploadToken, key, uploadBytes, mimeType);
            }
            catch (Exception ex) when (ex.Message.Contains("no such domain", StringComparison.OrdinalIgnoreCase))
            {
                respText = await UploadOnceAsync(http, $"https://{DefaultUploadHost}", uploadToken, key, uploadBytes, mimeType);
            }

            Console.WriteLine("上传成功");
            Console.WriteLine("response_json:");
            Console.WriteLine(PrettyJsonIfPossible(respText));

            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"上传失败: {e.Message}");
            return 1;
        }
    }

    private static string GetProgramDir()
    {
        var loc = AppContext.BaseDirectory;
        return string.IsNullOrWhiteSpace(loc) ? Environment.CurrentDirectory : loc;
    }

    private static string NormalizePathOrUrl(string s)
    {
        var t = (s ?? string.Empty).Trim();

        // 防止复制命令时把 '+' 一起带上（如 "C:\\...png"+）
        while (t.EndsWith('+'))
        {
            t = t[..^1].TrimEnd();
        }

        if (t.Length >= 2)
        {
            if ((t.StartsWith('"') && t.EndsWith('"')) || (t.StartsWith('\'') && t.EndsWith('\'')))
            {
                return t[1..^1].Trim();
            }
        }
        return t;
    }

    private static bool IsUrl(string s) => s.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || s.StartsWith("https://", StringComparison.OrdinalIgnoreCase);

    private sealed record InputData(byte[] Bytes, string Name, string? ContentType);

    private static async Task<InputData> ReadInputAsync(string pathOrUrl)
    {
        if (IsUrl(pathOrUrl))
        {
            var uri = new Uri(pathOrUrl);
            using var http = new HttpClient();
            using var resp = await http.GetAsync(uri);
            var bytes = await resp.Content.ReadAsByteArrayAsync();
            if (!resp.IsSuccessStatusCode)
            {
                throw new Exception($"download failed: {(int)resp.StatusCode} {Encoding.UTF8.GetString(bytes)}");
            }

            var ct = resp.Content.Headers.ContentType?.MediaType;
            var name = Path.GetFileName(uri.LocalPath);
            if (string.IsNullOrWhiteSpace(name)) name = "image";
            return new InputData(bytes, name, ct);
        }

        var p = Path.GetFullPath(pathOrUrl);
        var bytesLocal = await File.ReadAllBytesAsync(p);
        var nameLocal = Path.GetFileName(p);
        var ctLocal = GuessMimeFromExtension(nameLocal);
        return new InputData(bytesLocal, nameLocal, ctLocal);
    }

    private static string GuessMimeFromExtension(string filename)
    {
        var ext = Path.GetExtension(filename).ToLowerInvariant();
        return ext switch
        {
            ".png" => "image/png",
            ".jpg" => "image/jpeg",
            ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            _ => "application/octet-stream",
        };
    }

    private static string GetExtFromNameOrMime(string name, string mime)
    {
        var ext = Path.GetExtension(name).TrimStart('.');
        if (!string.IsNullOrWhiteSpace(ext)) return ext;

        var mt = mime.ToLowerInvariant();
        if (mt.Contains("png")) return "png";
        if (mt.Contains("jpeg") || mt.Contains("jpg")) return "jpg";
        if (mt.Contains("gif")) return "gif";
        if (mt.Contains("webp")) return "webp";
        return "bin";
    }

    private static string Md5Hex(byte[] bytes)
    {
        var hash = MD5.HashData(bytes);
        var sb = new StringBuilder(hash.Length * 2);
        foreach (var b in hash)
            sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    private static async Task<byte[]> ToWebpViaCwebpAsync(byte[] inputBytes, int quality)
    {
        var q = quality <= 0 || quality > 100 ? 95 : quality;
        var tmp = Path.GetTempPath();
        var inPath = Path.Combine(tmp, $"imgutil_{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}_{Environment.ProcessId}.input");
        var outPath = Path.Combine(tmp, $"imgutil_{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}_{Environment.ProcessId}.webp");

        await File.WriteAllBytesAsync(inPath, inputBytes);

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cwebp",
                Arguments = $"-q {q} \"{inPath}\" -o \"{outPath}\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc is null) throw new Exception("failed to start cwebp");
            var stdout = await proc.StandardOutput.ReadToEndAsync();
            var stderr = await proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();
            if (proc.ExitCode != 0)
            {
                throw new Exception($"cwebp failed: {stdout}\n{stderr}");
            }
            return await File.ReadAllBytesAsync(outPath);
        }
        catch (Win32Exception e)
        {
            throw new Exception($"failed to run cwebp (install libwebp/cwebp or set enable_webp=false): {e.Message}");
        }
        finally
        {
            TryDelete(inPath);
            TryDelete(outPath);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static async Task<string> GetQiniuUploadTokenAsync(HttpClient http, string userToken, string qiniuTokenUrl)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, qiniuTokenUrl);
        req.Headers.TryAddWithoutValidation("token", userToken);
        req.Headers.TryAddWithoutValidation("Content-Type", "application/json");

        using var resp = await http.SendAsync(req);
        var text = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode)
        {
            throw new Exception($"qiniu-token http error: {(int)resp.StatusCode} {text}");
        }

        using var doc = JsonDocument.Parse(text);
        if (!doc.RootElement.TryGetProperty("code", out var codeEl) || codeEl.GetInt32() != 1)
        {
            throw new Exception($"qiniu-token api error: {text}");
        }

        if (!doc.RootElement.TryGetProperty("data", out var dataEl) || !dataEl.TryGetProperty("token", out var tokEl))
        {
            throw new Exception($"qiniu-token missing token: {text}");
        }

        var tok = tokEl.GetString();
        if (string.IsNullOrWhiteSpace(tok))
        {
            throw new Exception($"qiniu-token missing token: {text}");
        }
        return tok;
    }

    private static async Task<string> QueryUploadHostAsync(HttpClient http, string uploadToken, string bucket)
    {
        var ak = uploadToken.Split(':')[0];
        var url = $"https://api.qiniu.com/v4/query?ak={Uri.EscapeDataString(ak)}&bucket={Uri.EscapeDataString(bucket)}";
        try
        {
            using var resp = await http.GetAsync(url);
            if (!resp.IsSuccessStatusCode) return DefaultUploadHost;
            var payload = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(payload);

            if (!doc.RootElement.TryGetProperty("hosts", out var hostsEl) || hostsEl.ValueKind != JsonValueKind.Array || hostsEl.GetArrayLength() == 0)
                return DefaultUploadHost;

            var first = hostsEl[0];
            if (!first.TryGetProperty("up", out var upEl)) return DefaultUploadHost;
            if (!upEl.TryGetProperty("domains", out var domainsEl) || domainsEl.ValueKind != JsonValueKind.Array || domainsEl.GetArrayLength() == 0)
                return DefaultUploadHost;

            var d = domainsEl[0].GetString();
            return string.IsNullOrWhiteSpace(d) ? DefaultUploadHost : d;
        }
        catch
        {
            return DefaultUploadHost;
        }
    }

    private static string NormalizeHost(string domainOrUrl)
    {
        var s = (domainOrUrl ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(s)) return DefaultUploadHost;

        if (s.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || s.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            if (Uri.TryCreate(s, UriKind.Absolute, out var u) && !string.IsNullOrWhiteSpace(u.Host))
                return u.Host;
        }

        var slash = s.IndexOf('/');
        if (slash >= 0) s = s[..slash];
        return string.IsNullOrWhiteSpace(s) ? DefaultUploadHost : s;
    }

    private static async Task<string> UploadOnceAsync(HttpClient http, string uploadUrl, string uploadToken, string key, byte[] bytes, string mimeType)
    {
        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(uploadToken), "token");
        content.Add(new StringContent(key), "key");

        var fileContent = new ByteArrayContent(bytes);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue(mimeType);
        content.Add(fileContent, "file", key);

        using var req = new HttpRequestMessage(HttpMethod.Post, uploadUrl);
        req.Content = content;
        req.Headers.TryAddWithoutValidation("user-agent", "QiniuDart");
        req.Headers.TryAddWithoutValidation("accept-encoding", "gzip");

        using var resp = await http.SendAsync(req);
        var text = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode)
        {
            throw new Exception($"qiniu upload failed: {(int)resp.StatusCode} {text} (uploadUrl={uploadUrl})");
        }
        return text;
    }

    private static string PrettyJsonIfPossible(string raw)
    {
        try
        {
            using var doc = JsonDocument.Parse(raw);
            return JsonSerializer.Serialize(doc.RootElement, new JsonSerializerOptions { WriteIndented = true });
        }
        catch
        {
            return raw;
        }
    }
}
