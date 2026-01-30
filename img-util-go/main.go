package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func loadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(b, &cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func main() {
	exe, _ := os.Executable()
	baseDir := filepath.Dir(exe)
	configPath := filepath.Join(baseDir, "config.json")

	cfg, err := loadConfig(configPath)
	if err != nil {
		fmt.Println("找不到或无法解析config.json:", err)
		os.Exit(1)
	}
	cfg.UserToken = strings.TrimSpace(cfg.UserToken)
	if cfg.UserToken == "" {
		fmt.Println("config.json里的 user_token 为空")
		os.Exit(1)
	}

	fmt.Print("请输入图片地址(本地路径或URL): ")
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	pathOrURL := strings.TrimSpace(line)
	if pathOrURL == "" {
		fmt.Println("未输入图片地址")
		os.Exit(1)
	}

	_, raw, err := uploadImage(pathOrURL, cfg)
	if err != nil {
		fmt.Println("上传失败:", err)
		os.Exit(1)
	}

	fmt.Println("上传成功")
	fmt.Println("response_json:")
	pretty, _ := json.MarshalIndent(raw, "", "  ")
	fmt.Println(string(pretty))
}
