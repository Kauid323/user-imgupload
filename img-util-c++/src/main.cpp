#include <curl/curl.h>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <string>
#include <vector>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#define access _access
#define F_OK 0
#endif

static const char *DEFAULT_UPLOAD_HOST = "upload-z2.qiniup.com";

struct Buffer {
    std::string data;
};

static size_t curl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    auto *b = static_cast<Buffer *>(userdata);
    b->data.append(ptr, size * nmemb);
    return size * nmemb;
}

static inline uint32_t rol(uint32_t x, uint32_t n) { return (x << n) | (x >> (32 - n)); }

static void md5(const unsigned char *initial_msg, size_t initial_len, unsigned char digest[16]) {
    uint32_t h0 = 0x67452301;
    uint32_t h1 = 0xefcdab89;
    uint32_t h2 = 0x98badcfe;
    uint32_t h3 = 0x10325476;

    static const uint32_t r[] = {
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
    };

    static const uint32_t k[] = {
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,
        0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
        0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,
        0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,
        0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
        0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,
        0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,
        0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
        0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
    };

    size_t new_len = initial_len + 1;
    while (new_len % 64 != 56) new_len++;

    std::vector<unsigned char> msg(new_len + 8, 0);
    memcpy(msg.data(), initial_msg, initial_len);
    msg[initial_len] = 0x80;

    unsigned long long bits_len = static_cast<unsigned long long>(initial_len) * 8;
    memcpy(msg.data() + new_len, &bits_len, 8);

    for (size_t offset = 0; offset < new_len; offset += 64) {
        auto *w = reinterpret_cast<uint32_t *>(msg.data() + offset);
        uint32_t a = h0;
        uint32_t b = h1;
        uint32_t c = h2;
        uint32_t d = h3;

        for (uint32_t i = 0; i < 64; i++) {
            uint32_t f, g;
            if (i < 16) {
                f = (b & c) | ((~b) & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | ((~d) & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | (~d));
                g = (7 * i) % 16;
            }
            uint32_t temp = d;
            d = c;
            c = b;
            uint32_t x = a + f + k[i] + w[g];
            b = b + rol(x, r[i]);
            a = temp;
        }

        h0 += a;
        h1 += b;
        h2 += c;
        h3 += d;
    }

    memcpy(digest + 0, &h0, 4);
    memcpy(digest + 4, &h1, 4);
    memcpy(digest + 8, &h2, 4);
    memcpy(digest + 12, &h3, 4);
}

static std::string md5_hex(const unsigned char *data, size_t len) {
    unsigned char dig[16];
    md5(data, len, dig);
    static const char *hex = "0123456789abcdef";
    std::string out;
    out.resize(32);
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[(dig[i] >> 4) & 0xF];
        out[i * 2 + 1] = hex[dig[i] & 0xF];
    }
    return out;
}

static bool read_text_file(const std::string &path, std::string &out) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(n));
    size_t r = fread(out.data(), 1, out.size(), f);
    fclose(f);
    out.resize(r);
    return true;
}

static bool read_bin_file(const std::string &path, std::vector<unsigned char> &out) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(n));
    size_t r = fread(out.data(), 1, out.size(), f);
    fclose(f);
    out.resize(r);
    return true;
}

static const char *json_find_key(const std::string &json, const std::string &key) {
    std::string pat = "\"" + key + "\"";
    const char *base = json.c_str();
    const char *p = strstr(base, pat.c_str());
    if (!p) return nullptr;
    p = strchr(p + pat.size(), ':');
    if (!p) return nullptr;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

static bool json_get_bool(const std::string &json, const std::string &key, bool defv) {
    const char *p = json_find_key(json, key);
    if (!p) return defv;
    if (strncmp(p, "true", 4) == 0) return true;
    if (strncmp(p, "false", 5) == 0) return false;
    return defv;
}

static int json_get_int(const std::string &json, const std::string &key, int defv) {
    const char *p = json_find_key(json, key);
    if (!p) return defv;
    return atoi(p);
}

static std::string json_get_string(const std::string &json, const std::string &key, const std::string &defv) {
    const char *p = json_find_key(json, key);
    if (!p || *p != '"') return defv;
    p++;
    const char *e = strchr(p, '"');
    if (!e) return defv;
    return std::string(p, static_cast<size_t>(e - p));
}

static void json_pretty_print(const std::string &raw) {
    const char *s = raw.c_str();
    int indent = 0;
    bool in_str = false;
    bool esc = false;
    while (*s) {
        char c = *s++;
        if (esc) {
            std::cout << c;
            esc = false;
            continue;
        }
        if (in_str && c == '\\') {
            std::cout << c;
            esc = true;
            continue;
        }
        if (c == '"') {
            std::cout << c;
            in_str = !in_str;
            continue;
        }
        if (in_str) {
            std::cout << c;
            continue;
        }
        if (c == '{' || c == '[') {
            std::cout << c << "\n";
            indent++;
            for (int i = 0; i < indent; i++) std::cout << "  ";
        } else if (c == '}' || c == ']') {
            std::cout << "\n";
            indent = indent > 0 ? indent - 1 : 0;
            for (int i = 0; i < indent; i++) std::cout << "  ";
            std::cout << c;
        } else if (c == ',') {
            std::cout << c << "\n";
            for (int i = 0; i < indent; i++) std::cout << "  ";
        } else if (c == ':') {
            std::cout << ": ";
        } else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        } else {
            std::cout << c;
        }
    }
    std::cout << "\n";
}

static void normalize_input_inplace(std::string &s) {
    while (!s.empty()) {
        char c = s.back();
        if (c == '\n' || c == '\r' || c == '+' || std::isspace(static_cast<unsigned char>(c))) s.pop_back();
        else break;
    }
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) start++;
    if (start > 0) s.erase(0, start);
    if (s.size() >= 2) {
        if ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\'')) {
            s = s.substr(1, s.size() - 2);
        }
    }
}

static bool run_cwebp(const std::vector<unsigned char> &in, int quality, std::vector<unsigned char> &out) {
    char in_path[512];
    char out_path[512];
    unsigned long long t = static_cast<unsigned long long>(time(nullptr));

#ifdef _WIN32
    char tmp[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp);
    snprintf(in_path, sizeof(in_path), "%simgutil_%llu.input", tmp, t);
    snprintf(out_path, sizeof(out_path), "%simgutil_%llu.webp", tmp, t);
#else
    snprintf(in_path, sizeof(in_path), "/tmp/imgutil_%llu.input", t);
    snprintf(out_path, sizeof(out_path), "/tmp/imgutil_%llu.webp", t);
#endif

    FILE *f = fopen(in_path, "wb");
    if (!f) return false;
    fwrite(in.data(), 1, in.size(), f);
    fclose(f);

    char cmd[1200];
#ifdef _WIN32
    snprintf(cmd, sizeof(cmd), "cwebp -q %d \"%s\" -o \"%s\"", quality, in_path, out_path);
#else
    snprintf(cmd, sizeof(cmd), "cwebp -q %d '%s' -o '%s'", quality, in_path, out_path);
#endif

    int rc = system(cmd);
    remove(in_path);
    if (rc != 0) {
        remove(out_path);
        return false;
    }

    std::vector<unsigned char> wb;
    if (!read_bin_file(out_path, wb)) {
        remove(out_path);
        return false;
    }
    remove(out_path);
    out.swap(wb);
    return true;
}

static bool http_get_bytes(const std::string &url, struct curl_slist *headers, Buffer &resp, long &status) {
    CURL *curl = curl_easy_init();
    if (!curl) return false;

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 60L);
    if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    CURLcode rc = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(curl);
    return rc == CURLE_OK;
}

static std::string get_qiniu_upload_token(const std::string &user_token, const std::string &qiniu_token_url) {
    struct curl_slist *hdrs = nullptr;
    std::string tok_hdr = "token: " + user_token;
    hdrs = curl_slist_append(hdrs, tok_hdr.c_str());
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");

    Buffer resp;
    long st = 0;
    bool ok = http_get_bytes(qiniu_token_url, hdrs, resp, st);
    curl_slist_free_all(hdrs);

    if (!ok || st < 200 || st >= 300) return "";

    const char *p = strstr(resp.data.c_str(), "\"code\"");
    if (!p) return "";
    p = strchr(p, ':');
    if (!p) return "";
    int code = atoi(p + 1);
    if (code != 1) return "";

    return json_get_string(resp.data, "token", "");
}

static std::string query_upload_host(const std::string &upload_token, const std::string &bucket) {
    std::string ak = upload_token;
    size_t pos = ak.find(':');
    if (pos != std::string::npos) ak.resize(pos);

    std::string url = "https://api.qiniu.com/v4/query?ak=" + ak + "&bucket=" + bucket;

    Buffer resp;
    long st = 0;
    if (!http_get_bytes(url, nullptr, resp, st) || st < 200 || st >= 300) return DEFAULT_UPLOAD_HOST;

    const char *d = strstr(resp.data.c_str(), "\"domains\"");
    if (!d) return DEFAULT_UPLOAD_HOST;
    const char *q = strchr(d, '[');
    if (!q) return DEFAULT_UPLOAD_HOST;
    q++;
    while (*q && *q != '"') q++;
    if (*q != '"') return DEFAULT_UPLOAD_HOST;
    q++;
    const char *qe = strchr(q, '"');
    if (!qe) return DEFAULT_UPLOAD_HOST;

    std::string host(q, static_cast<size_t>(qe - q));
    if (host.rfind("http://", 0) == 0) host.erase(0, 7);
    else if (host.rfind("https://", 0) == 0) host.erase(0, 8);
    size_t slash = host.find('/');
    if (slash != std::string::npos) host.resize(slash);
    if (host.empty()) return DEFAULT_UPLOAD_HOST;
    return host;
}

static bool upload_once(const std::string &upload_url,
                        const std::string &upload_token,
                        const std::string &key,
                        const std::vector<unsigned char> &bytes,
                        const std::string &mime_type,
                        std::string &out_resp,
                        long &out_status) {
    CURL *curl = curl_easy_init();
    if (!curl) return false;

    Buffer resp;

    curl_easy_setopt(curl, CURLOPT_URL, upload_url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 60L);

    struct curl_slist *hdrs = nullptr;
    hdrs = curl_slist_append(hdrs, "user-agent: QiniuDart");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part;

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "token");
    curl_mime_data(part, upload_token.c_str(), CURL_ZERO_TERMINATED);

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "key");
    curl_mime_data(part, key.c_str(), CURL_ZERO_TERMINATED);

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filename(part, key.c_str());
    curl_mime_type(part, mime_type.c_str());
    curl_mime_data(part, reinterpret_cast<const char *>(bytes.data()), bytes.size());

    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);

    CURLcode rc = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &out_status);

    curl_mime_free(mime);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);

    out_resp = resp.data;
    return rc == CURLE_OK;
}

static std::string basename_from_path_or_url(const std::string &s) {
    size_t p1 = s.find_last_of("/\\");
    if (p1 == std::string::npos) return s;
    return s.substr(p1 + 1);
}

int main(int argc, char **argv) {
    curl_global_init(CURL_GLOBAL_DEFAULT);

#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
#endif

    std::string cfg_text;
    std::string cfg_path = "config.json";
    if (!read_text_file(cfg_path, cfg_text)) {
        std::cout << "找不到config.json，请在同目录创建\n";
        return 1;
    }

    std::string user_token = json_get_string(cfg_text, "user_token", "");
    bool enable_webp = json_get_bool(cfg_text, "enable_webp", false);
    int webp_quality = json_get_int(cfg_text, "webp_quality", 95);
    std::string bucket = json_get_string(cfg_text, "bucket", "chat68");
    std::string qiniu_token_url = json_get_string(cfg_text, "qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token");

    if (user_token.empty()) {
        std::cout << "config.json里的 user_token 为空\n";
        return 1;
    }

    std::string input;
    if (argc >= 2 && argv[1] && argv[1][0]) {
        input = argv[1];
    } else {
        std::cout << "请输入图片地址(本地路径或URL): ";
        std::getline(std::cin, input);
    }
    normalize_input_inplace(input);
    if (input.empty()) {
        std::cout << "未输入图片地址\n";
        return 1;
    }

    std::vector<unsigned char> orig_bytes;
    std::string name;
    std::string content_type;

    if (input.rfind("http://", 0) == 0 || input.rfind("https://", 0) == 0) {
        Buffer resp;
        long st = 0;
        if (!http_get_bytes(input, nullptr, resp, st) || st < 200 || st >= 300) {
            std::cout << "上传失败: download failed\n";
            return 1;
        }
        orig_bytes.assign(resp.data.begin(), resp.data.end());
        name = basename_from_path_or_url(input);
    } else {
        if (!read_bin_file(input, orig_bytes)) {
            std::cout << "上传失败: could not read file\n";
            return 1;
        }
        name = basename_from_path_or_url(input);
        content_type = "application/octet-stream";
    }

    std::vector<unsigned char> upload_bytes = orig_bytes;
    std::string mime_type;
    std::string ext;

    if (enable_webp) {
        std::vector<unsigned char> wb;
        int q = (webp_quality <= 0 || webp_quality > 100) ? 95 : webp_quality;
        if (!run_cwebp(upload_bytes, q, wb)) {
            std::cout << "上传失败: cwebp failed (install cwebp or set enable_webp=false)\n";
            return 1;
        }
        upload_bytes.swap(wb);
        mime_type = "image/webp";
        ext = "webp";
    } else {
        mime_type = content_type.empty() ? "application/octet-stream" : content_type;
        size_t dot = name.find_last_of('.');
        if (dot != std::string::npos && dot + 1 < name.size()) ext = name.substr(dot + 1);
        else ext = "bin";
    }

    std::string md5v = md5_hex(upload_bytes.data(), upload_bytes.size());
    std::string key = md5v + "." + ext;

    std::string utoken = get_qiniu_upload_token(user_token, qiniu_token_url);
    if (utoken.empty()) {
        std::cout << "上传失败: qiniu-token failed\n";
        return 1;
    }

    std::string host = query_upload_host(utoken, bucket);
    std::string upload_url = "https://" + host;

    std::string up_resp;
    long st = 0;
    bool ok = upload_once(upload_url, utoken, key, upload_bytes, mime_type, up_resp, st);
    if (!ok || st < 200 || st >= 300) {
        if (up_resp.find("no such domain") != std::string::npos) {
            upload_url = std::string("https://") + DEFAULT_UPLOAD_HOST;
            ok = upload_once(upload_url, utoken, key, upload_bytes, mime_type, up_resp, st);
        }
    }

    if (!ok || st < 200 || st >= 300) {
        std::cout << "上传失败: qiniu upload failed: " << st << " " << up_resp << "\n";
        return 1;
    }

    std::cout << "上传成功\n";
    std::cout << "response_json:\n";
    json_pretty_print(up_resp);

    curl_global_cleanup();
    return 0;
}
