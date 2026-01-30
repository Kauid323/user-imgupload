#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
 #include <ctype.h>

#ifdef _WIN32
#include <windows.h>
#include <io.h>
#define access _access
#define F_OK 0
#endif

#define DEFAULT_UPLOAD_HOST "upload-z2.qiniup.com"

static char *xstrdup(const char *s) {
    if (!s) return NULL;
#ifdef _WIN32
    return _strdup(s);
#else
    return strdup(s);
#endif
}

typedef struct {
    char *data;
    size_t size;
} Buffer;

#ifdef _WIN32
static wchar_t *utf8_to_wide_fallback(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) {
        n = MultiByteToWideChar(CP_ACP, 0, s, -1, NULL, 0);
        if (n <= 0) return NULL;
        wchar_t *w = (wchar_t *)calloc((size_t)n, sizeof(wchar_t));
        if (!w) return NULL;
        MultiByteToWideChar(CP_ACP, 0, s, -1, w, n);
        return w;
    }
    wchar_t *w = (wchar_t *)calloc((size_t)n, sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n);
    return w;
}

static char *wide_to_utf8(const wchar_t *ws) {
    if (!ws) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, ws, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *out = (char *)malloc((size_t)n);
    if (!out) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, ws, -1, out, n, NULL, NULL);
    return out;
}

static int read_console_line_utf8(char *out, size_t out_cap) {
    if (!out || out_cap == 0) return 0;
    out[0] = '\0';

    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    if (hIn == INVALID_HANDLE_VALUE || hIn == NULL) return 0;

    wchar_t wbuf[2048];
    DWORD read = 0;
    if (!ReadConsoleW(hIn, wbuf, (DWORD)(sizeof(wbuf) / sizeof(wbuf[0]) - 1), &read, NULL)) return 0;
    wbuf[read] = L'\0';

    char *u8 = wide_to_utf8(wbuf);
    if (!u8) return 0;
    snprintf(out, out_cap, "%s", u8);
    free(u8);
    return 1;
}

static FILE *fopen_utf8(const char *path, const char *mode) {
    wchar_t *wpath = utf8_to_wide_fallback(path);
    wchar_t *wmode = utf8_to_wide_fallback(mode);
    if (!wpath || !wmode) {
        free(wpath);
        free(wmode);
        return fopen(path, mode);
    }
    FILE *f = _wfopen(wpath, wmode);
    if (!f) {
        const char *dbg = getenv("IMGUTIL_DEBUG");
        if (dbg && dbg[0] == '1') {
            DWORD err = GetLastError();
            fwprintf(stderr, L"[debug] _wfopen failed. GetLastError=%lu\n", (unsigned long)err);
            fwprintf(stderr, L"[debug] wpath=%ls\n", wpath);
            fwprintf(stderr, L"[debug] wmode=%ls\n", wmode);
        }
    }
    free(wpath);
    free(wmode);
    return f ? f : fopen(path, mode);
}
#endif

static void buf_init(Buffer *b) {
    b->data = NULL;
    b->size = 0;
}

static int buf_append(Buffer *b, const void *data, size_t len) {
    char *p = (char *)realloc(b->data, b->size + len + 1);
    if (!p) return 0;
    b->data = p;
    memcpy(b->data + b->size, data, len);
    b->size += len;
    b->data[b->size] = '\0';
    return 1;
}

static size_t curl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t len = size * nmemb;
    Buffer *b = (Buffer *)userdata;
    if (!buf_append(b, ptr, len)) return 0;
    return len;
}

static unsigned int rol(unsigned int x, unsigned int n) { return (x << n) | (x >> (32 - n)); }

static void md5(const unsigned char *initial_msg, size_t initial_len, unsigned char digest[16]) {
    unsigned int h0 = 0x67452301;
    unsigned int h1 = 0xefcdab89;
    unsigned int h2 = 0x98badcfe;
    unsigned int h3 = 0x10325476;

    static const unsigned int r[] = {
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
    };

    static const unsigned int k[] = {
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
    unsigned char *msg = (unsigned char *)calloc(new_len + 8, 1);
    memcpy(msg, initial_msg, initial_len);
    msg[initial_len] = 0x80;

    unsigned long long bits_len = (unsigned long long)initial_len * 8;
    memcpy(msg + new_len, &bits_len, 8);

    for (size_t offset = 0; offset < new_len; offset += 64) {
        unsigned int *w = (unsigned int *)(msg + offset);
        unsigned int a = h0;
        unsigned int b = h1;
        unsigned int c = h2;
        unsigned int d = h3;

        for (unsigned int i = 0; i < 64; i++) {
            unsigned int f, g;
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
            unsigned int temp = d;
            d = c;
            c = b;
            unsigned int x = a + f + k[i] + w[g];
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

    free(msg);
}

static void md5_hex(const unsigned char *data, size_t len, char out[33]) {
    unsigned char dig[16];
    md5(data, len, dig);
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[(dig[i] >> 4) & 0xF];
        out[i * 2 + 1] = hex[dig[i] & 0xF];
    }
    out[32] = '\0';
}

static char *read_text_file(const char *path) {
 #ifdef _WIN32
    FILE *f = fopen_utf8(path, "rb");
 #else
    FILE *f = fopen(path, "rb");
 #endif
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t r = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[r] = '\0';
    return buf;
}

static unsigned char *read_bin_file(const char *path, size_t *out_len) {
 #ifdef _WIN32
    FILE *f = fopen_utf8(path, "rb");
 #else
    FILE *f = fopen(path, "rb");
 #endif
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = (unsigned char *)malloc((size_t)n);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t r = fread(buf, 1, (size_t)n, f);
    fclose(f);
    *out_len = r;
    return buf;
}

static const char *json_find_key(const char *json, const char *key) {
    static char pat[256];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return NULL;
    p = strchr(p + strlen(pat), ':');
    if (!p) return NULL;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

static int json_get_bool(const char *json, const char *key, int defv) {
    const char *p = json_find_key(json, key);
    if (!p) return defv;
    if (strncmp(p, "true", 4) == 0) return 1;
    if (strncmp(p, "false", 5) == 0) return 0;
    return defv;
}

static int json_get_int(const char *json, const char *key, int defv) {
    const char *p = json_find_key(json, key);
    if (!p) return defv;
    return atoi(p);
}

static char *json_get_string(const char *json, const char *key, const char *defv) {
    const char *p = json_find_key(json, key);
    if (!p || *p != '"') {
        return defv ? xstrdup(defv) : NULL;
    }
    p++;
    const char *e = strchr(p, '"');
    if (!e) return defv ? xstrdup(defv) : NULL;
    size_t n = (size_t)(e - p);
    char *s = (char *)malloc(n + 1);
    memcpy(s, p, n);
    s[n] = '\0';
    return s;
}

static void normalize_input_inplace(char *s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || isspace((unsigned char)s[n - 1]) || s[n - 1] == '+')) {
        s[n - 1] = '\0';
        n--;
    }
    size_t start = 0;
    while (s[start] && isspace((unsigned char)s[start])) start++;
    if (start > 0) memmove(s, s + start, strlen(s + start) + 1);

    n = strlen(s);
    if (n >= 2) {
        if ((s[0] == '"' && s[n - 1] == '"') || (s[0] == '\'' && s[n - 1] == '\'')) {
            memmove(s, s + 1, n - 2);
            s[n - 2] = '\0';
        }
    }
}

static void json_pretty_print(const char *raw) {
    const char *s = raw;
    int indent = 0;
    int in_str = 0;
    int esc = 0;
    while (*s) {
        char c = *s++;
        if (esc) {
            putchar(c);
            esc = 0;
            continue;
        }
        if (in_str && c == '\\') {
            putchar(c);
            esc = 1;
            continue;
        }
        if (c == '"') {
            putchar(c);
            in_str = !in_str;
            continue;
        }
        if (in_str) {
            putchar(c);
            continue;
        }
        if (c == '{' || c == '[') {
            putchar(c);
            putchar('\n');
            indent++;
            for (int i = 0; i < indent; i++) printf("  ");
        } else if (c == '}' || c == ']') {
            putchar('\n');
            indent = indent > 0 ? indent - 1 : 0;
            for (int i = 0; i < indent; i++) printf("  ");
            putchar(c);
        } else if (c == ',') {
            putchar(c);
            putchar('\n');
            for (int i = 0; i < indent; i++) printf("  ");
        } else if (c == ':') {
            putchar(':');
            putchar(' ');
        } else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        } else {
            putchar(c);
        }
    }
    putchar('\n');
}

static int run_cwebp(const unsigned char *in, size_t in_len, int quality, unsigned char **out, size_t *out_len) {
    char in_path[512];
    char out_path[512];
    unsigned long long t = (unsigned long long)time(NULL);
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
    if (!f) return 0;
    fwrite(in, 1, in_len, f);
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
        return 0;
    }

    *out = read_bin_file(out_path, out_len);
    remove(out_path);
    return *out != NULL;
}

static int http_get_bytes(const char *url, struct curl_slist *headers, Buffer *resp, long *status) {
    CURL *curl = curl_easy_init();
    if (!curl) return 0;
    buf_init(resp);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, resp);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 60L);
    if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    CURLcode rc = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status);
    curl_easy_cleanup(curl);

    return rc == CURLE_OK;
}

static char *get_qiniu_upload_token(const char *user_token, const char *qiniu_token_url) {
    struct curl_slist *hdrs = NULL;
    char tok_hdr[512];
    snprintf(tok_hdr, sizeof(tok_hdr), "token: %s", user_token);
    hdrs = curl_slist_append(hdrs, tok_hdr);
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");

    Buffer resp;
    long st = 0;
    if (!http_get_bytes(qiniu_token_url, hdrs, &resp, &st)) {
        curl_slist_free_all(hdrs);
        free(resp.data);
        return NULL;
    }
    curl_slist_free_all(hdrs);

    if (st < 200 || st >= 300) {
        free(resp.data);
        return NULL;
    }
    const char *p = strstr(resp.data, "\"code\"");
    if (!p) {
        free(resp.data);
        return NULL;
    }
    p = strchr(p, ':');
    if (!p) {
        free(resp.data);
        return NULL;
    }
    int code = atoi(p + 1);
    if (code != 1) {
        free(resp.data);
        return NULL;
    }

    char *out = json_get_string(resp.data, "token", NULL);
    free(resp.data);
    return out;
}

static char *query_upload_host(const char *upload_token, const char *bucket) {
    const char *colon = strchr(upload_token, ':');
    size_t ak_len = colon ? (size_t)(colon - upload_token) : strlen(upload_token);
    char ak[256];
    if (ak_len >= sizeof(ak)) ak_len = sizeof(ak) - 1;
    memcpy(ak, upload_token, ak_len);
    ak[ak_len] = '\0';

    char url[1024];
    snprintf(url, sizeof(url), "https://api.qiniu.com/v4/query?ak=%s&bucket=%s", ak, bucket);

    Buffer resp;
    long st = 0;
    if (!http_get_bytes(url, NULL, &resp, &st)) {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }

    if (st < 200 || st >= 300) {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }

    const char *d = strstr(resp.data, "\"domains\"");
    if (!d) {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }
    const char *q = strchr(d, '[');
    if (!q) {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }
    q++;
    while (*q && *q != '"') q++;
    if (*q != '"') {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }
    q++;
    const char *qe = strchr(q, '"');
    if (!qe) {
        free(resp.data);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }

    size_t n = (size_t)(qe - q);
    char *host = (char *)malloc(n + 1);
    memcpy(host, q, n);
    host[n] = '\0';
    free(resp.data);

    if (strncmp(host, "http://", 7) == 0) {
        memmove(host, host + 7, strlen(host + 7) + 1);
    } else if (strncmp(host, "https://", 8) == 0) {
        memmove(host, host + 8, strlen(host + 8) + 1);
    }
    char *slash = strchr(host, '/');
    if (slash) *slash = '\0';
    if (host[0] == '\0') {
        free(host);
        return xstrdup(DEFAULT_UPLOAD_HOST);
    }
    return host;
}

static int upload_once(const char *upload_url, const char *upload_token, const char *key,
                       const unsigned char *bytes, size_t bytes_len, const char *mime_type,
                       Buffer *out_resp, long *out_status) {
    CURL *curl = curl_easy_init();
    if (!curl) return 0;

    buf_init(out_resp);

    curl_easy_setopt(curl, CURLOPT_URL, upload_url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, out_resp);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 60L);

    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "user-agent: QiniuDart");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);

    curl_mime *mime = curl_mime_init(curl);
    curl_mimepart *part;

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "token");
    curl_mime_data(part, upload_token, CURL_ZERO_TERMINATED);

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "key");
    curl_mime_data(part, key, CURL_ZERO_TERMINATED);

    part = curl_mime_addpart(mime);
    curl_mime_name(part, "file");
    curl_mime_filename(part, key);
    curl_mime_type(part, mime_type);
    curl_mime_data(part, (const char *)bytes, bytes_len);

    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);

    CURLcode rc = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, out_status);

    curl_mime_free(mime);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);

    return rc == CURLE_OK;
}

int main(int argc, char **argv) {
    curl_global_init(CURL_GLOBAL_DEFAULT);

    char exe_dir[1024] = {0};
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    GetModuleFileNameA(NULL, exe_dir, (DWORD)sizeof(exe_dir));
    char *slash = strrchr(exe_dir, '\\');
    if (slash) *slash = '\0';
#else
    strcpy(exe_dir, ".");
#endif

    char cfg_path[1200];
 #ifdef _WIN32
    snprintf(cfg_path, sizeof(cfg_path), "%s\\config.json", exe_dir);
 #else
    snprintf(cfg_path, sizeof(cfg_path), "%s/config.json", exe_dir);
 #endif
    if (access(cfg_path, F_OK) != 0) {
        strcpy(cfg_path, "config.json");
    }

    char *cfg_txt = read_text_file(cfg_path);
    if (!cfg_txt) {
        printf("找不到config.json，请在同目录创建\n");
        return 1;
    }

    char *user_token = json_get_string(cfg_txt, "user_token", "");
    int enable_webp = json_get_bool(cfg_txt, "enable_webp", 0);
    int webp_quality = json_get_int(cfg_txt, "webp_quality", 95);
    char *bucket = json_get_string(cfg_txt, "bucket", "chat68");
    char *qiniu_token_url = json_get_string(cfg_txt, "qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token");

    free(cfg_txt);

    if (!user_token || user_token[0] == '\0') {
        printf("config.json里的 user_token 为空\n");
        free(user_token);
        free(bucket);
        free(qiniu_token_url);
        return 1;
    }

    char input[2048] = {0};
#ifdef _WIN32
    if (argc >= 2) {
        int wargc = 0;
        wchar_t **wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
        if (wargv && wargc >= 2) {
            char *u8 = wide_to_utf8(wargv[1]);
            if (u8) {
                snprintf(input, sizeof(input), "%s", u8);
                free(u8);
            }
        } else if (argv[1] && argv[1][0]) {
            snprintf(input, sizeof(input), "%s", argv[1]);
        }
        if (wargv) LocalFree(wargv);
    }
    if (input[0] == '\0') {
        printf("请输入图片地址(本地路径或URL): ");
        if (!read_console_line_utf8(input, sizeof(input))) {
            printf("未输入图片地址\n");
            return 1;
        }
    }
#else
    if (argc >= 2 && argv[1] && argv[1][0]) {
        snprintf(input, sizeof(input), "%s", argv[1]);
    } else {
        printf("请输入图片地址(本地路径或URL): ");
        if (!fgets(input, sizeof(input), stdin)) {
            printf("未输入图片地址\n");
            return 1;
        }
    }
#endif
    normalize_input_inplace(input);
    if (input[0] == '\0') {
        printf("未输入图片地址\n");
        return 1;
    }

    unsigned char *orig_bytes = NULL;
    size_t orig_len = 0;
    char name[256] = {0};
    char content_type[128] = {0};

    if (strncmp(input, "http://", 7) == 0 || strncmp(input, "https://", 8) == 0) {
        Buffer resp;
        long st = 0;
        if (!http_get_bytes(input, NULL, &resp, &st) || st < 200 || st >= 300) {
            printf("上传失败: download failed\n");
            free(resp.data);
            return 1;
        }
        orig_bytes = (unsigned char *)resp.data;
        orig_len = resp.size;
        const char *bn = strrchr(input, '/');
        snprintf(name, sizeof(name), "%s", bn ? bn + 1 : "image");
        content_type[0] = '\0';
    } else {
        orig_bytes = read_bin_file(input, &orig_len);
        if (!orig_bytes) {
            printf("上传失败: could not read file\n");
            return 1;
        }
        const char *bn = strrchr(input, '\\');
        snprintf(name, sizeof(name), "%s", bn ? bn + 1 : input);
        snprintf(content_type, sizeof(content_type), "application/octet-stream");
    }

    unsigned char *upload_bytes = orig_bytes;
    size_t upload_len = orig_len;
    char mime_type[64];
    char ext[16];

    if (enable_webp) {
        unsigned char *wb = NULL;
        size_t wl = 0;
        if (!run_cwebp(orig_bytes, orig_len, webp_quality <= 0 || webp_quality > 100 ? 95 : webp_quality, &wb, &wl)) {
            printf("上传失败: cwebp failed (install cwebp or set enable_webp=false)\n");
            free(orig_bytes);
            free(user_token);
            free(bucket);
            free(qiniu_token_url);
            return 1;
        }
        free(orig_bytes);
        upload_bytes = wb;
        upload_len = wl;
        snprintf(mime_type, sizeof(mime_type), "image/webp");
        snprintf(ext, sizeof(ext), "webp");
    } else {
        snprintf(mime_type, sizeof(mime_type), "%s", content_type[0] ? content_type : "application/octet-stream");
        const char *dot = strrchr(name, '.');
        if (dot && dot[1]) {
            snprintf(ext, sizeof(ext), "%s", dot + 1);
        } else {
            snprintf(ext, sizeof(ext), "bin");
        }
    }

    char md5v[33];
    md5_hex(upload_bytes, upload_len, md5v);

    char key[64];
    snprintf(key, sizeof(key), "%s.%s", md5v, ext);

    char *utoken = get_qiniu_upload_token(user_token, qiniu_token_url);
    if (!utoken) {
        printf("上传失败: qiniu-token failed\n");
        free(upload_bytes);
        free(user_token);
        free(bucket);
        free(qiniu_token_url);
        return 1;
    }

    char *host = query_upload_host(utoken, bucket);
    if (!host) host = xstrdup(DEFAULT_UPLOAD_HOST);

    char upload_url[512];
    snprintf(upload_url, sizeof(upload_url), "https://%s", host);

    Buffer up_resp;
    long st = 0;
    int ok = upload_once(upload_url, utoken, key, upload_bytes, upload_len, mime_type, &up_resp, &st);
    if (!ok || st < 200 || st >= 300) {
        if (up_resp.data && strstr(up_resp.data, "no such domain")) {
            free(up_resp.data);
            snprintf(upload_url, sizeof(upload_url), "https://%s", DEFAULT_UPLOAD_HOST);
            ok = upload_once(upload_url, utoken, key, upload_bytes, upload_len, mime_type, &up_resp, &st);
        }
    }

    if (!ok || st < 200 || st >= 300) {
        printf("上传失败: qiniu upload failed: %ld %s\n", st, up_resp.data ? up_resp.data : "");
        free(up_resp.data);
        free(upload_bytes);
        free(user_token);
        free(bucket);
        free(qiniu_token_url);
        free(utoken);
        free(host);
        curl_global_cleanup();
        return 1;
    }

    printf("上传成功\n");
    printf("response_json:\n");
    if (up_resp.data) {
        json_pretty_print(up_resp.data);
    }

    free(up_resp.data);
    free(upload_bytes);
    free(user_token);
    free(bucket);
    free(qiniu_token_url);
    free(utoken);
    free(host);

    curl_global_cleanup();
    return 0;
}
