package main

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

const defaultUploadHost = "upload-z2.qiniup.com"

type UploadResult struct {
	Key   string                 `json:"key"`
	Hash  string                 `json:"hash"`
	Fsize int64                  `json:"fsize"`
	Raw   map[string]any         `json:"-"`
}

type Config struct {
	UserToken    string `json:"user_token"`
	EnableWebP   bool   `json:"enable_webp"`
	WebPQuality  int    `json:"webp_quality"`
	Bucket       string `json:"bucket"`
	QiniuTokenURL string `json:"qiniu_token_url"`
}

func isURL(s string) bool {
	return strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://")
}

func readInputBytes(pathOrURL string, timeout time.Duration) ([]byte, string, string, error) {
	if isURL(pathOrURL) {
		u, err := url.Parse(pathOrURL)
		if err != nil {
			return nil, "", "", err
		}
		client := &http.Client{Timeout: timeout}
		resp, err := client.Get(pathOrURL)
		if err != nil {
			return nil, "", "", err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			b, _ := io.ReadAll(resp.Body)
			return nil, "", "", fmt.Errorf("download failed: %d %s", resp.StatusCode, string(b))
		}
		b, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, "", "", err
		}
		name := path.Base(u.Path)
		if name == "" || name == "/" || name == "." {
			name = "image"
		}
		ct := resp.Header.Get("content-type")
		if ct == "" {
			ct = http.DetectContentType(b)
		}
		if idx := strings.Index(ct, ";"); idx >= 0 {
			ct = strings.TrimSpace(ct[:idx])
		}
		return b, name, ct, nil
	}

	b, err := os.ReadFile(pathOrURL)
	if err != nil {
		return nil, "", "", err
	}
	name := filepath.Base(pathOrURL)
	ct := mime.TypeByExtension(filepath.Ext(name))
	if ct == "" {
		ct = http.DetectContentType(b)
	}
	if idx := strings.Index(ct, ";"); idx >= 0 {
		ct = strings.TrimSpace(ct[:idx])
	}
	return b, name, ct, nil
}

func toWebP(imageBytes []byte, quality int) ([]byte, error) {
	// 说明：为了避免 Windows 下 CGO/libwebp 依赖问题，这里改为调用外部 cwebp 工具。
	// 你需要确保 cwebp 在 PATH 中可用（例如安装 libwebp 或把 cwebp.exe 放到同目录/环境变量）。
	if quality <= 0 || quality > 100 {
		quality = 95
	}

	inFile, err := os.CreateTemp("", "imgutil-*.input")
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = os.Remove(inFile.Name())
		_ = inFile.Close()
	}()
	if _, err := inFile.Write(imageBytes); err != nil {
		return nil, err
	}
	if err := inFile.Close(); err != nil {
		return nil, err
	}

	outFile, err := os.CreateTemp("", "imgutil-*.webp")
	if err != nil {
		return nil, err
	}
	outName := outFile.Name()
	_ = outFile.Close()
	defer func() { _ = os.Remove(outName) }()

	cmd := exec.Command("cwebp", "-q", fmt.Sprintf("%d", quality), inFile.Name(), "-o", outName)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("cwebp failed: %v %s", err, strings.TrimSpace(string(output)))
	}
	return os.ReadFile(outName)
}

func md5Hex(b []byte) string {
	sum := md5.Sum(b)
	return hex.EncodeToString(sum[:])
}

func getQiniuUploadToken(userToken, qiniuTokenURL string, timeout time.Duration) (string, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, qiniuTokenURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("token", userToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("qiniu-token http error: %d %s", resp.StatusCode, string(b))
	}

	var payload map[string]any
	if err := json.Unmarshal(b, &payload); err != nil {
		return "", err
	}
	code, _ := payload["code"].(float64)
	if int(code) != 1 {
		return "", fmt.Errorf("qiniu-token api error: %s", string(b))
	}
	data, _ := payload["data"].(map[string]any)
	if data == nil {
		return "", errors.New("qiniu-token missing data")
	}
	tok, _ := data["token"].(string)
	if strings.TrimSpace(tok) == "" {
		return "", errors.New("qiniu-token missing token")
	}
	return tok, nil
}

func queryUploadHost(uploadToken, bucket string, timeout time.Duration) string {
	parts := strings.Split(uploadToken, ":")
	if len(parts) == 0 {
		return defaultUploadHost
	}
	ak := parts[0]
	qurl := fmt.Sprintf("https://api.qiniu.com/v4/query?ak=%s&bucket=%s", url.QueryEscape(ak), url.QueryEscape(bucket))

	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(qurl)
	if err != nil {
		return defaultUploadHost
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return defaultUploadHost
	}

	var payload map[string]any
	if err := json.Unmarshal(b, &payload); err != nil {
		return defaultUploadHost
	}
	hosts, _ := payload["hosts"].([]any)
	if len(hosts) == 0 {
		return defaultUploadHost
	}
	h0, _ := hosts[0].(map[string]any)
	up, _ := h0["up"].(map[string]any)
	domains, _ := up["domains"].([]any)
	if len(domains) == 0 {
		return defaultUploadHost
	}
	d0, _ := domains[0].(string)
	if d0 == "" {
		return defaultUploadHost
	}
	return d0
}

func uploadImage(pathOrURL string, cfg Config) (UploadResult, map[string]any, error) {
	if strings.TrimSpace(cfg.UserToken) == "" {
		return UploadResult{}, nil, errors.New("config user_token is empty")
	}
	if strings.TrimSpace(cfg.Bucket) == "" {
		cfg.Bucket = "chat68"
	}
	if strings.TrimSpace(cfg.QiniuTokenURL) == "" {
		cfg.QiniuTokenURL = "https://chat-go.jwzhd.com/v1/misc/qiniu-token"
	}

	timeout := 120 * time.Second
	origBytes, origName, origMime, err := readInputBytes(pathOrURL, timeout)
	if err != nil {
		return UploadResult{}, nil, err
	}

	var uploadBytes []byte
	mimeType := origMime
	ext := strings.TrimPrefix(filepath.Ext(origName), ".")

	if cfg.EnableWebP {
		uploadBytes, err = toWebP(origBytes, cfg.WebPQuality)
		if err != nil {
			return UploadResult{}, nil, err
		}
		mimeType = "image/webp"
		ext = "webp"
	} else {
		uploadBytes = origBytes
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
		if ext == "" {
			if exts, _ := mime.ExtensionsByType(mimeType); len(exts) > 0 {
				ext = strings.TrimPrefix(exts[0], ".")
			}
			if ext == "" {
				ext = "bin"
			}
		}
	}

	md5v := md5Hex(uploadBytes)
	key := md5v + "." + ext

	utoken, err := getQiniuUploadToken(cfg.UserToken, cfg.QiniuTokenURL, timeout)
	if err != nil {
		return UploadResult{}, nil, err
	}
	host := queryUploadHost(utoken, cfg.Bucket, timeout)
	uploadURL := "https://" + host

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("token", utoken)
	_ = mw.WriteField("key", key)
	fw, err := mw.CreateFormFile("file", key)
	if err != nil {
		return UploadResult{}, nil, err
	}
	if _, err := fw.Write(uploadBytes); err != nil {
		return UploadResult{}, nil, err
	}
	_ = mw.Close()

	req, err := http.NewRequest(http.MethodPost, uploadURL, &body)
	if err != nil {
		return UploadResult{}, nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("user-agent", "QiniuDart")
	req.Header.Set("accept-encoding", "gzip")

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return UploadResult{}, nil, err
	}
	defer resp.Body.Close()
	respBytes, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return UploadResult{}, nil, fmt.Errorf("qiniu upload failed: %d %s", resp.StatusCode, string(respBytes))
	}

	var payload map[string]any
	if err := json.Unmarshal(respBytes, &payload); err != nil {
		return UploadResult{}, nil, err
	}

	res := UploadResult{}
	if v, ok := payload["key"].(string); ok {
		res.Key = v
	}
	if v, ok := payload["hash"].(string); ok {
		res.Hash = v
	}
	switch v := payload["fsize"].(type) {
	case float64:
		res.Fsize = int64(v)
	case int64:
		res.Fsize = v
	case int:
		res.Fsize = int64(v)
	}
	res.Raw = payload
	return res, payload, nil
}
