<?php

declare(strict_types=1);

const DEFAULT_UPLOAD_HOST = 'upload-z2.qiniup.com';

function fail(string $msg, int $code = 1): void {
    fwrite(STDERR, $msg . PHP_EOL);
    exit($code);
}

function debug_enabled(): bool {
    $v = getenv('IMGUTIL_DEBUG');
    return $v !== false && $v !== '' && $v !== '0';
}

function debug_log(string $msg): void {
    if (debug_enabled()) {
        fwrite(STDERR, "[debug] " . $msg . PHP_EOL);
    }
}

function normalize_input(string $s): string {
    $s = trim($s);
    while ($s !== '' && substr($s, -1) === '+') {
        $s = substr($s, 0, -1);
        $s = rtrim($s);
    }
    if (strlen($s) >= 2) {
        $q1 = $s[0];
        $q2 = $s[strlen($s) - 1];
        if (($q1 === '"' && $q2 === '"') || ($q1 === "'" && $q2 === "'")) {
            $s = substr($s, 1, -1);
        }
    }
    return $s;
}

function is_url(string $s): bool {
    return str_starts_with($s, 'http://') || str_starts_with($s, 'https://');
}

function parse_args(array $argv): array {
    $input = '';
    $config = __DIR__ . DIRECTORY_SEPARATOR . 'config.json';

    $n = count($argv);
    for ($i = 1; $i < $n; $i++) {
        $a = (string)$argv[$i];
        if ($a === '--') {
            if ($i + 1 < $n && $input === '') {
                $input = (string)$argv[$i + 1];
            }
            break;
        }

        if ($a === '-h' || $a === '--help') {
            echo "Usage:\n";
            echo "  php main.php --input <path_or_url> [--config <config.json>]\n";
            echo "  php main.php <path_or_url>\n";
            exit(0);
        }
        if ($a === '--input' || $a === '-i') {
            if ($i + 1 >= $n) fail('missing value for --input');
            $input = (string)$argv[++$i];
            continue;
        }
        if ($a === '--config' || $a === '-c') {
            if ($i + 1 >= $n) fail('missing value for --config');
            $config = (string)$argv[++$i];
            continue;
        }

        if ($input === '' && $a !== '') {
            $input = $a;
        }
    }

    return ['input' => $input, 'config' => $config];
}

function resolve_local_path(string $path): string {
    $path = normalize_input($path);
    if ($path === '') return '';
    if (file_exists($path)) return $path;

    if (PHP_OS_FAMILY !== 'Windows') return $path;

    if (function_exists('iconv')) {
        $candidates = [];
        $candidates[] = @iconv('UTF-8', 'GBK//IGNORE', $path);
        $candidates[] = @iconv('UTF-8', 'CP936//IGNORE', $path);
        $candidates[] = @iconv('GBK', 'UTF-8//IGNORE', $path);
        $candidates[] = @iconv('CP936', 'UTF-8//IGNORE', $path);
        foreach ($candidates as $p) {
            if (is_string($p) && $p !== '' && file_exists($p)) return $p;
        }
    }

    return $path;
}

function load_config(string $path): array {
    if (!file_exists($path)) {
        fail("找不到config.json，请在同目录创建");
    }
    $txt = file_get_contents($path);
    if ($txt === false) {
        fail("读取config.json失败");
    }
    $cfg = json_decode($txt, true);
    if (!is_array($cfg)) {
        fail("config.json 不是合法JSON");
    }

    return [
        'user_token' => (string)($cfg['user_token'] ?? ''),
        'enable_webp' => (bool)($cfg['enable_webp'] ?? false),
        'webp_quality' => (int)($cfg['webp_quality'] ?? 95),
        'bucket' => (string)($cfg['bucket'] ?? 'chat68'),
        'qiniu_token_url' => (string)($cfg['qiniu_token_url'] ?? 'https://chat-go.jwzhd.com/v1/misc/qiniu-token'),
    ];
}

function curl_opt(string $name): int {
    if (!defined($name)) {
        fail("php-curl extension not enabled (missing $name).\n" .
            "请在 php.ini 中启用 curl 扩展，例如取消注释: extension=curl\n" .
            "并确保 ext/curl.dll 存在，然后重启终端再运行。"
        );
    }
    return (int)constant($name);
}

function curl_request(string $url, array $opts = []): array {
    if (!function_exists('curl_init')) {
        fail('php-curl extension not enabled');
    }

    $ch = curl_init();
    if ($ch === false) {
        fail('curl_init failed');
    }

    $defaults = [
        curl_opt('CURLOPT_URL') => $url,
        curl_opt('CURLOPT_RETURNTRANSFER') => true,
        curl_opt('CURLOPT_FOLLOWLOCATION') => true,
        curl_opt('CURLOPT_CONNECTTIMEOUT') => 60,
        curl_opt('CURLOPT_TIMEOUT') => 120,
        curl_opt('CURLOPT_ENCODING') => '',
    ];

    $insecure = getenv('IMGUTIL_INSECURE');
    if ($insecure !== false && $insecure !== '' && $insecure !== '0') {
        $defaults[curl_opt('CURLOPT_SSL_VERIFYPEER')] = false;
        $defaults[curl_opt('CURLOPT_SSL_VERIFYHOST')] = 0;
        debug_log('curl insecure SSL enabled (IMGUTIL_INSECURE=1)');
    }

    $caInfo = getenv('IMGUTIL_CAINFO');
    if ($caInfo !== false && is_string($caInfo) && $caInfo !== '') {
        $defaults[curl_opt('CURLOPT_CAINFO')] = $caInfo;
        debug_log('curl CAINFO=' . $caInfo);
    }

    foreach ($opts as $k => $v) {
        $defaults[$k] = $v;
    }

    debug_log('curl url=' . $url);

    curl_setopt_array($ch, $defaults);
    $body = curl_exec($ch);
    $errno = curl_errno($ch);
    $err = curl_error($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);

    if (defined('PHP_VERSION_ID') && PHP_VERSION_ID < 80500) {
        curl_close($ch);
    }
    $ch = null;

    if ($body === false) {
        debug_log('curl failed: status=' . (string)$status . ' errno=' . (string)$errno . ' err=' . $err);
        return ['ok' => false, 'status' => $status, 'body' => '', 'error' => "curl error($errno): $err"]; 
    }

    debug_log('curl done: status=' . (string)$status . ' bytes=' . (string)strlen((string)$body));

    return ['ok' => true, 'status' => $status, 'body' => (string)$body, 'error' => ''];
}

function download_bytes(string $url): string {
    $r = curl_request($url);
    if (!$r['ok'] || $r['status'] < 200 || $r['status'] >= 300) {
        fail('上传失败: download failed');
    }
    return $r['body'];
}

function run_cwebp_bytes(string $bytes, int $quality): string {
    $q = ($quality <= 0 || $quality > 100) ? 95 : $quality;

    $tmp = sys_get_temp_dir();
    $t = (string)time();
    $in = $tmp . DIRECTORY_SEPARATOR . "imgutil_{$t}.input";
    $out = $tmp . DIRECTORY_SEPARATOR . "imgutil_{$t}.webp";

    if (file_put_contents($in, $bytes) === false) {
        fail('上传失败: cwebp failed (cannot write temp file)');
    }

    $cmd = 'cwebp -q ' . escapeshellarg((string)$q) . ' ' . escapeshellarg($in) . ' -o ' . escapeshellarg($out);
    $output = [];
    $rc = 0;
    @exec($cmd . ' 2>&1', $output, $rc);
    @unlink($in);

    if ($rc !== 0 || !file_exists($out)) {
        @unlink($out);
        fail('上传失败: cwebp failed (install cwebp or set enable_webp=false)');
    }

    $wb = file_get_contents($out);
    @unlink($out);
    if ($wb === false) {
        fail('上传失败: cwebp failed (read output failed)');
    }
    return $wb;
}

function get_qiniu_upload_token(string $userToken, string $tokenUrl): string {
    $headers = [
        'token: ' . $userToken,
        'Content-Type: application/json',
    ];
    $r = curl_request($tokenUrl, [
        curl_opt('CURLOPT_HTTPHEADER') => $headers,
    ]);
    if (!$r['ok'] || $r['status'] < 200 || $r['status'] >= 300) {
        if (debug_enabled()) {
            debug_log("qiniu-token http failed: ok=" . ($r['ok'] ? '1' : '0') . " status=" . (string)$r['status']);
            if (!empty($r['error'])) debug_log("qiniu-token curl error=" . (string)$r['error']);
            if (isset($r['body']) && $r['body'] !== '') debug_log("qiniu-token body=" . (string)$r['body']);
        }
        return '';
    }
    $obj = json_decode($r['body'], true);
    if (!is_array($obj) || (int)($obj['code'] ?? 0) !== 1) {
        if (debug_enabled()) {
            debug_log("qiniu-token bad json/code, body=" . (string)$r['body']);
        }
        return '';
    }
    if (isset($obj['data']) && is_array($obj['data']) && isset($obj['data']['token'])) {
        return (string)$obj['data']['token'];
    }
    return (string)($obj['token'] ?? '');
}

function query_upload_host(string $uploadToken, string $bucket): string {
    $parts = explode(':', $uploadToken, 2);
    $ak = $parts[0] ?? $uploadToken;
    $url = 'https://api.qiniu.com/v4/query?ak=' . rawurlencode($ak) . '&bucket=' . rawurlencode($bucket);

    $r = curl_request($url);
    if (!$r['ok'] || $r['status'] < 200 || $r['status'] >= 300) {
        return DEFAULT_UPLOAD_HOST;
    }
    $obj = json_decode($r['body'], true);
    if (!is_array($obj)) {
        return DEFAULT_UPLOAD_HOST;
    }

    $domains = $obj['domains'] ?? null;
    if (is_array($domains) && count($domains) > 0 && is_string($domains[0])) {
        $h = $domains[0];
        $h = preg_replace('#^https?://#', '', $h);
        $h = preg_replace('#/.*$#', '', $h);
        if (is_string($h) && $h !== '') return $h;
    }

    return DEFAULT_UPLOAD_HOST;
}

function upload_once(string $uploadUrl, string $uploadToken, string $key, string $filePath, string $mimeType): array {
    $post = [
        'token' => $uploadToken,
        'key' => $key,
        'file' => curl_file_create($filePath, $mimeType, $key),
    ];

    $r = curl_request($uploadUrl, [
        curl_opt('CURLOPT_POST') => true,
        curl_opt('CURLOPT_POSTFIELDS') => $post,
        curl_opt('CURLOPT_HTTPHEADER') => [
            'User-Agent: QiniuDart',
        ],
    ]);

    return $r;
}

function pretty_print_json(string $raw): void {
    $obj = json_decode($raw, true);
    if ($obj !== null) {
        echo json_encode($obj, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . PHP_EOL;
    } else {
        echo $raw . PHP_EOL;
    }
}

function main(): void {
    $args = parse_args($GLOBALS['argv']);
    $cfg = load_config((string)$args['config']);
    if ($cfg['user_token'] === '') {
        fail('config.json里的 user_token 为空');
    }

    $input = (string)$args['input'];
    if ($input === '') {
        fwrite(STDOUT, '请输入图片地址(本地路径或URL): ');
        $input = fgets(STDIN);
        if ($input === false) {
            fail('未输入图片地址');
        }
    }
    $input = normalize_input((string)$input);
    if ($input === '') {
        fail('未输入图片地址');
    }

    $origBytes = '';
    $name = '';

    if (is_url($input)) {
        $origBytes = download_bytes($input);
        $name = basename(parse_url($input, PHP_URL_PATH) ?? 'image');
        if ($name === '') $name = 'image';
    } else {
        $localPath = resolve_local_path($input);
        if ($localPath === '' || !file_exists($localPath)) {
            fail("上传失败: could not read file\n请尝试用参数传入（避免控制台编码问题）:\n  php main.php --input \"$input\"");
        }
        $origBytes = file_get_contents($localPath);
        if ($origBytes === false) {
            fail('上传失败: could not read file');
        }
        $name = basename($localPath);
    }

    $uploadBytes = $origBytes;
    $mimeType = 'application/octet-stream';
    $ext = 'bin';

    if ($cfg['enable_webp']) {
        $uploadBytes = run_cwebp_bytes($origBytes, (int)$cfg['webp_quality']);
        $mimeType = 'image/webp';
        $ext = 'webp';
    } else {
        $dot = strrpos($name, '.');
        if ($dot !== false && $dot + 1 < strlen($name)) {
            $ext = substr($name, $dot + 1);
        }
    }

    $md5 = md5($uploadBytes);
    $key = $md5 . '.' . $ext;

    $uploadToken = get_qiniu_upload_token($cfg['user_token'], $cfg['qiniu_token_url']);
    if ($uploadToken === '') {
        fail('上传失败: qiniu-token failed');
    }

    $host = query_upload_host($uploadToken, $cfg['bucket']);
    $uploadUrl = 'https://' . $host;

    $tmpFile = tempnam(sys_get_temp_dir(), 'imgutil_');
    if ($tmpFile === false) {
        fail('上传失败: cannot create temp file');
    }
    file_put_contents($tmpFile, $uploadBytes);

    $r = upload_once($uploadUrl, $uploadToken, $key, $tmpFile, $mimeType);
    if (!$r['ok'] || $r['status'] < 200 || $r['status'] >= 300) {
        if (strpos($r['body'], 'no such domain') !== false) {
            $uploadUrl = 'https://' . DEFAULT_UPLOAD_HOST;
            $r = upload_once($uploadUrl, $uploadToken, $key, $tmpFile, $mimeType);
        }
    }

    @unlink($tmpFile);

    if (!$r['ok'] || $r['status'] < 200 || $r['status'] >= 300) {
        fail('上传失败: qiniu upload failed: ' . $r['status'] . ' ' . ($r['body'] ?? $r['error']));
    }

    echo "上传成功\n";
    echo "response_json:\n";
    pretty_print_json((string)$r['body']);
}

main();
