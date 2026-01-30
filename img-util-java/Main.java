import java.io.*;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Main {

    static class Config {
        String userToken;
        boolean enableWebp;
        int webpQuality;
        String bucket;
        String qiniuTokenUrl;
    }

    public static void main(String[] args) throws Exception {
        File baseDir = getProgramDir();
        File configFile = new File(baseDir, "config.json");
        if (!configFile.exists()) {
            System.out.println("找不到config.json，请在当前目录创建: " + configFile.getAbsolutePath());
            System.exit(1);
        }

        String cfgText = Files.readString(configFile.toPath(), StandardCharsets.UTF_8);
        Config cfg = parseConfig(cfgText);
        if (cfg.userToken == null || cfg.userToken.isBlank()) {
            System.out.println("config.json里的 user_token 为空");
            System.exit(1);
        }
        if (cfg.bucket == null || cfg.bucket.isBlank()) cfg.bucket = "chat68";
        if (cfg.qiniuTokenUrl == null || cfg.qiniuTokenUrl.isBlank()) cfg.qiniuTokenUrl = "https://chat-go.jwzhd.com/v1/misc/qiniu-token";
        if (cfg.webpQuality <= 0 || cfg.webpQuality > 100) cfg.webpQuality = 95;

        String pathOrUrl;
        if (args != null && args.length > 0 && args[0] != null && !args[0].isBlank()) {
            // 支持：java Main.java "C:\\path with space\\xxx.png"
            pathOrUrl = args[0];
        } else {
            System.out.print("请输入图片地址(本地路径或URL): ");
            Console console = System.console();
            if (console != null) {
                pathOrUrl = console.readLine();
            } else {
                // 源码模式(java Main.java)下 console 可能为 null，fallback 用 UTF-8
                BufferedReader br = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
                pathOrUrl = br.readLine();
            }
        }
        if (pathOrUrl == null || pathOrUrl.isBlank()) {
            System.out.println("未输入图片地址");
            System.exit(1);
        }

        pathOrUrl = normalizePathOrUrl(pathOrUrl.trim());

        byte[] originalBytes = readBytes(pathOrUrl.trim());
        byte[] uploadBytes = originalBytes;
        String mimeType = guessMimeType(pathOrUrl.trim(), originalBytes);
        String extension = guessExtension(pathOrUrl.trim(), mimeType);

        if (cfg.enableWebp) {
            WebpResult wr = toWebpViaCwebp(originalBytes, cfg.webpQuality);
            uploadBytes = wr.webpBytes;
            mimeType = "image/webp";
            extension = "webp";
        }

        String md5 = md5Hex(uploadBytes);
        String key = md5 + "." + extension;

        String uploadToken = getQiniuUploadToken(cfg.qiniuTokenUrl, cfg.userToken);
        String uploadHost = normalizeUploadHost(queryUploadHost(uploadToken, cfg.bucket));
        String uploadUrl = "https://" + uploadHost;

        String responseJson;
        try {
            responseJson = multipartUpload(uploadUrl, uploadToken, key, uploadBytes, mimeType);
        } catch (RuntimeException e) {
            // 遇到域名不匹配时回退默认域名再试一次
            if (e.getMessage() != null && e.getMessage().contains("no such domain")) {
                String fallbackHost = "upload-z2.qiniup.com";
                String fallbackUrl = "https://" + fallbackHost;
                responseJson = multipartUpload(fallbackUrl, uploadToken, key, uploadBytes, mimeType);
            } else {
                throw e;
            }
        }

        System.out.println("上传成功");
        System.out.println("response_json:");
        System.out.println(prettyJsonIfPossible(responseJson));
    }

    static File getProgramDir() {
        try {
            File loc = new File(Main.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            if (loc.isFile()) {
                File parent = loc.getParentFile();
                if (parent != null) return parent;
            }
            if (loc.isDirectory()) {
                return loc;
            }
        } catch (Exception ignored) {
        }
        return new File(System.getProperty("user.dir"));
    }

    static Config parseConfig(String json) {
        Config c = new Config();
        c.userToken = matchString(json, "user_token");
        c.enableWebp = matchBoolean(json, "enable_webp", false);
        c.webpQuality = matchInt(json, "webp_quality", 95);
        c.bucket = matchString(json, "bucket");
        c.qiniuTokenUrl = matchString(json, "qiniu_token_url");
        return c;
    }

    static String matchString(String json, String key) {
        Pattern p = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
        Matcher m = p.matcher(json);
        return m.find() ? m.group(1) : null;
    }

    static boolean matchBoolean(String json, String key, boolean def) {
        Pattern p = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(true|false)", Pattern.CASE_INSENSITIVE);
        Matcher m = p.matcher(json);
        if (!m.find()) return def;
        return "true".equalsIgnoreCase(m.group(1));
    }

    static int matchInt(String json, String key, int def) {
        Pattern p = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(\\d+)");
        Matcher m = p.matcher(json);
        if (!m.find()) return def;
        try {
            return Integer.parseInt(m.group(1));
        } catch (Exception e) {
            return def;
        }
    }

    static boolean isUrl(String s) {
        return s.startsWith("http://") || s.startsWith("https://");
    }

    static byte[] readBytes(String pathOrUrl) throws Exception {
        if (isUrl(pathOrUrl)) {
            URL u = URI.create(pathOrUrl).toURL();
            HttpURLConnection conn = (HttpURLConnection) u.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(60000);
            conn.setReadTimeout(60000);
            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            byte[] b = readAllBytes(in);
            if (code < 200 || code >= 300) {
                throw new RuntimeException("download failed: " + code + " " + new String(b, StandardCharsets.UTF_8));
            }
            return b;
        }

        // 支持 file:///C:/xxx 这种输入
        if (pathOrUrl.toLowerCase(Locale.ROOT).startsWith("file://")) {
            try {
                Path p = Path.of(new java.net.URI(pathOrUrl));
                return Files.readAllBytes(p);
            } catch (Exception ignored) {
            }
        }

        try {
            Path p = Path.of(pathOrUrl);
            return Files.readAllBytes(p);
        } catch (java.nio.file.NoSuchFileException e) {
            throw new RuntimeException(
                    "文件不存在: " + pathOrUrl + "\n" +
                            "请确认路径包含盘符(例如 C:\\Users\\...)，并且中文路径在当前终端未被转成 ?。\n" +
                            "建议：\n" +
                            "1) 直接拖拽文件到终端输入路径（最不容易乱码）\n" +
                            "2) 用参数传入：java Main.java \"C:\\\\Users\\\\...\\\\xxx.png\"\n" +
                            "3) 先执行 chcp 65001，再运行 java -Dfile.encoding=UTF-8 Main.java\n" +
                            "4) 或改用 javac Main.java && java -Dfile.encoding=UTF-8 Main",
                    e
            );
        } catch (java.nio.file.InvalidPathException e) {
            throw new RuntimeException("本地路径不合法(Windows路径必须包含盘符，例如 C:\\Users\\...): " + pathOrUrl, e);
        }
    }

    static String normalizePathOrUrl(String s) {
        if (s == null) return "";
        String t = s.trim();
        if (t.length() >= 2) {
            char first = t.charAt(0);
            char last = t.charAt(t.length() - 1);
            if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
                t = t.substring(1, t.length() - 1).trim();
            }
        }

        // 你这次的输入是 :\Users\...（缺盘符），这里尝试用当前程序目录的盘符补齐
        if (!isUrl(t) && (t.startsWith(":\\") || t.startsWith(":/"))) {
            String drive = null;
            try {
                File base = getProgramDir();
                String abs = base.getAbsolutePath();
                if (abs.length() >= 2 && abs.charAt(1) == ':') {
                    drive = abs.substring(0, 2);
                }
            } catch (Exception ignored) {
            }
            if (drive == null) {
                String ud = System.getProperty("user.dir", "");
                if (ud.length() >= 2 && ud.charAt(1) == ':') {
                    drive = ud.substring(0, 2);
                }
            }
            if (drive != null) {
                // t 形如 :\Users\...，去掉开头的 ':' 再拼盘符，避免变成 C::\...
                t = drive + t.substring(1);
            }
        }
        return t;
    }

    static String guessMimeType(String pathOrUrl, byte[] bytes) {
        try {
            if (!isUrl(pathOrUrl)) {
                String mt = Files.probeContentType(Path.of(pathOrUrl));
                if (mt != null && !mt.isBlank()) return mt;
            }
        } catch (Exception ignored) {
        }
        // fallback
        if (bytes.length >= 12) {
            // PNG
            if ((bytes[0] & 0xFF) == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return "image/png";
            // JPEG
            if ((bytes[0] & 0xFF) == 0xFF && (bytes[1] & 0xFF) == 0xD8) return "image/jpeg";
            // GIF
            if (bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F') return "image/gif";
        }
        return "application/octet-stream";
    }

    static String guessExtension(String pathOrUrl, String mimeType) {
        String ext = "";
        try {
            if (!isUrl(pathOrUrl)) {
                String name = Path.of(pathOrUrl).getFileName().toString();
                int idx = name.lastIndexOf('.');
                if (idx >= 0 && idx + 1 < name.length()) ext = name.substring(idx + 1);
            } else {
                String p = URI.create(pathOrUrl).getPath();
                int idx = p.lastIndexOf('.');
                if (idx >= 0 && idx + 1 < p.length()) ext = p.substring(idx + 1);
            }
        } catch (Exception ignored) {
        }

        if (ext != null && !ext.isBlank()) return ext;

        String mt = mimeType == null ? "" : mimeType.toLowerCase(Locale.ROOT);
        if (mt.contains("png")) return "png";
        if (mt.contains("jpeg") || mt.contains("jpg")) return "jpg";
        if (mt.contains("gif")) return "gif";
        return "bin";
    }

    static String getQiniuUploadToken(String qiniuTokenUrl, String userToken) throws Exception {
        URL u = URI.create(qiniuTokenUrl).toURL();
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(60000);
        conn.setReadTimeout(60000);
        conn.setRequestProperty("token", userToken);
        conn.setRequestProperty("Content-Type", "application/json");

        int code = conn.getResponseCode();
        InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
        String body = new String(readAllBytes(in), StandardCharsets.UTF_8);
        if (code < 200 || code >= 300) {
            throw new RuntimeException("qiniu-token http error: " + code + " " + body);
        }
        Pattern ok = Pattern.compile("\\\"code\\\"\\s*:\\s*1");
        if (!ok.matcher(body).find()) {
            throw new RuntimeException("qiniu-token api error: " + body);
        }
        Pattern p = Pattern.compile("\\\"token\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
        Matcher m = p.matcher(body);
        if (!m.find()) {
            throw new RuntimeException("qiniu-token missing token: " + body);
        }
        return m.group(1);
    }

    static String queryUploadHost(String uploadToken, String bucket) {
        try {
            String ak = uploadToken.split(":")[0];
            String q = "https://api.qiniu.com/v4/query?ak=" + urlEncode(ak) + "&bucket=" + urlEncode(bucket);
            URL u = URI.create(q).toURL();
            HttpURLConnection conn = (HttpURLConnection) u.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(60000);
            conn.setReadTimeout(60000);
            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            String body = new String(readAllBytes(in), StandardCharsets.UTF_8);
            if (code < 200 || code >= 300) return "upload-z2.qiniup.com";

            Pattern p = Pattern.compile("\\\"domains\\\"\\s*:\\s*\\[\\s*\\\"([^\\\"]+)\\\"");
            Matcher m = p.matcher(body);
            if (m.find()) return m.group(1);
            return "upload-z2.qiniup.com";
        } catch (Exception e) {
            return "upload-z2.qiniup.com";
        }
    }

    static String normalizeUploadHost(String domainOrUrl) {
        if (domainOrUrl == null) return "upload-z2.qiniup.com";
        String s = domainOrUrl.trim();
        if (s.isEmpty()) return "upload-z2.qiniup.com";

        // 有些情况下 domains 可能返回带 scheme 的 URL，或者带 path
        if (s.startsWith("http://") || s.startsWith("https://")) {
            try {
                URI u = URI.create(s);
                if (u.getHost() != null && !u.getHost().isEmpty()) {
                    s = u.getHost();
                }
            } catch (Exception ignored) {
            }
        }
        int slash = s.indexOf('/');
        if (slash >= 0) s = s.substring(0, slash);

        // 去掉可能的端口后空白
        s = s.trim();
        if (s.isEmpty()) return "upload-z2.qiniup.com";
        return s;
    }

    static String multipartUpload(String uploadUrl, String uploadToken, String key, byte[] fileBytes, String mimeType) throws Exception {
        String boundary = "----JavaBoundary" + System.currentTimeMillis();

        URL u = URI.create(uploadUrl).toURL();
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(60000);
        conn.setReadTimeout(120000);
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
        conn.setRequestProperty("user-agent", "QiniuDart");
        conn.setRequestProperty("accept-encoding", "gzip");

        try (OutputStream out = conn.getOutputStream()) {
            writeFormField(out, boundary, "token", uploadToken);
            writeFormField(out, boundary, "key", key);
            writeFileField(out, boundary, "file", key, mimeType, fileBytes);
            out.write(("--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8));
        }

        int code = conn.getResponseCode();
        InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
        String body = new String(readAllBytes(in), StandardCharsets.UTF_8);
        if (code < 200 || code >= 300) {
            throw new RuntimeException("qiniu upload failed: " + code + " " + body + " (uploadUrl=" + uploadUrl + ")");
        }
        return body;
    }

    static void writeFormField(OutputStream out, String boundary, String name, String value) throws IOException {
        out.write(("--" + boundary + "\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(("Content-Disposition: form-data; name=\"" + name + "\"\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(("\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(value.getBytes(StandardCharsets.UTF_8));
        out.write(("\r\n").getBytes(StandardCharsets.UTF_8));
    }

    static void writeFileField(OutputStream out, String boundary, String fieldName, String filename, String mimeType, byte[] bytes) throws IOException {
        out.write(("--" + boundary + "\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(("Content-Disposition: form-data; name=\"" + fieldName + "\"; filename=\"" + filename + "\"\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(("Content-Type: " + mimeType + "\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(("\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(bytes);
        out.write(("\r\n").getBytes(StandardCharsets.UTF_8));
    }

    static byte[] readAllBytes(InputStream in) throws IOException {
        if (in == null) return new byte[0];
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) >= 0) {
            if (n > 0) bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }

    static String md5Hex(byte[] bytes) throws Exception {
        MessageDigest md = MessageDigest.getInstance("MD5");
        byte[] sum = md.digest(bytes);
        StringBuilder sb = new StringBuilder();
        for (byte b : sum) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    static String urlEncode(String s) {
        try {
            return java.net.URLEncoder.encode(s, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return s;
        }
    }

    static class WebpResult {
        final byte[] webpBytes;

        WebpResult(byte[] webpBytes) {
            this.webpBytes = webpBytes;
        }
    }

    static WebpResult toWebpViaCwebp(byte[] inputBytes, int quality) throws Exception {
        if (quality <= 0 || quality > 100) quality = 95;

        Path in = Files.createTempFile("imgutil-java-", ".input");
        Path out = Files.createTempFile("imgutil-java-", ".webp");
        try {
            Files.write(in, inputBytes);
            ProcessBuilder pb = new ProcessBuilder(
                    "cwebp",
                    "-q",
                    String.valueOf(quality),
                    in.toAbsolutePath().toString(),
                    "-o",
                    out.toAbsolutePath().toString()
            );
            pb.redirectErrorStream(true);
            Process p = pb.start();
            String log;
            try (InputStream pin = p.getInputStream()) {
                log = new String(readAllBytes(pin), StandardCharsets.UTF_8);
            }
            int code = p.waitFor();
            if (code != 0) {
                throw new RuntimeException("cwebp failed: " + log);
            }
            return new WebpResult(Files.readAllBytes(out));
        } finally {
            try { Files.deleteIfExists(in); } catch (Exception ignored) {}
            try { Files.deleteIfExists(out); } catch (Exception ignored) {}
        }
    }

    static String prettyJsonIfPossible(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        if (!(s.startsWith("{") || s.startsWith("["))) return raw;

        StringBuilder out = new StringBuilder();
        int indent = 0;
        boolean inString = false;
        boolean escape = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (escape) {
                out.append(c);
                escape = false;
                continue;
            }
            if (c == '\\' && inString) {
                out.append(c);
                escape = true;
                continue;
            }
            if (c == '"') {
                out.append(c);
                inString = !inString;
                continue;
            }
            if (inString) {
                out.append(c);
                continue;
            }
            switch (c) {
                case '{':
                case '[':
                    out.append(c).append('\n');
                    indent++;
                    appendIndent(out, indent);
                    break;
                case '}':
                case ']':
                    out.append('\n');
                    indent = Math.max(0, indent - 1);
                    appendIndent(out, indent);
                    out.append(c);
                    break;
                case ',':
                    out.append(c).append('\n');
                    appendIndent(out, indent);
                    break;
                case ':':
                    out.append(": ");
                    break;
                default:
                    if (!Character.isWhitespace(c)) out.append(c);
            }
        }
        return out.toString();
    }

    static void appendIndent(StringBuilder sb, int indent) {
        for (int i = 0; i < indent; i++) sb.append("  ");
    }
}