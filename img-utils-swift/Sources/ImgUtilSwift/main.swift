import Foundation

struct Config: Decodable {
    let user_token: String
    let enable_webp: Bool
    let webp_quality: Int
    let bucket: String
    let qiniu_token_url: String
}

struct HttpResponse {
    let statusCode: Int
    let body: Data
}

func normalizeInput(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasSuffix("+") { t.removeLast() }
    if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
        t = String(t.dropFirst().dropLast())
    }
    return t
}

func md5Hex(_ data: Data) -> String {
    var hash = [UInt8](repeating: 0, count: 16)
    data.withUnsafeBytes { buf in
        _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

func readConfig() throws -> Config {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Config.self, from: data)
}

func httpGet(url: URL, headers: [String: String] = [:]) async throws -> HttpResponse {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    return HttpResponse(statusCode: http.statusCode, body: data)
}

func httpPostMultipart(url: URL, fields: [String: String], fileFieldName: String, fileName: String, mimeType: String, fileData: Data) async throws -> HttpResponse {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.setValue("QiniuDart", forHTTPHeaderField: "User-Agent")

    var body = Data()

    for (k, v) in fields {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
        body.append(v.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(fileData)
    body.append("\r\n".data(using: .utf8)!)

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    req.httpBody = body

    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    return HttpResponse(statusCode: http.statusCode, body: data)
}

func runCwebp(input: Data, quality: Int) throws -> Data {
    let tmp = FileManager.default.temporaryDirectory
    let t = UInt64(Date().timeIntervalSince1970)
    let inUrl = tmp.appendingPathComponent("imgutil_\(t).input")
    let outUrl = tmp.appendingPathComponent("imgutil_\(t).webp")

    try input.write(to: inUrl)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["cwebp", "-q", String(quality), inUrl.path, "-o", outUrl.path]

    let pipe = Pipe()
    proc.standardError = pipe
    proc.standardOutput = pipe

    try proc.run()
    proc.waitUntilExit()

    try? FileManager.default.removeItem(at: inUrl)

    if proc.terminationStatus != 0 {
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "cwebp", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
    }

    let out = try Data(contentsOf: outUrl)
    try? FileManager.default.removeItem(at: outUrl)
    return out
}

func getQiniuUploadToken(userToken: String, qiniuTokenUrl: String) async throws -> String {
    let url = URL(string: qiniuTokenUrl)!
    let resp = try await httpGet(url: url, headers: [
        "token": userToken,
        "Content-Type": "application/json"
    ])
    guard (200..<300).contains(resp.statusCode) else { return "" }

    let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
    guard let code = obj?["code"] as? Int, code == 1 else { return "" }
    return obj?["token"] as? String ?? ""
}

func queryUploadHost(uploadToken: String, bucket: String) async -> String {
    let ak = uploadToken.split(separator: ":").first.map(String.init) ?? uploadToken
    guard let url = URL(string: "https://api.qiniu.com/v4/query?ak=\(ak)&bucket=\(bucket)") else {
        return "upload-z2.qiniup.com"
    }

    do {
        let resp = try await httpGet(url: url)
        guard (200..<300).contains(resp.statusCode) else { return "upload-z2.qiniup.com" }
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        if let domains = obj?["domains"] as? [String], let first = domains.first {
            var h = first
            if h.hasPrefix("http://") { h.removeFirst("http://".count) }
            if h.hasPrefix("https://") { h.removeFirst("https://".count) }
            if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
            if !h.isEmpty { return h }
        }
        return "upload-z2.qiniup.com"
    } catch {
        return "upload-z2.qiniup.com"
    }
}

func isUrl(_ s: String) -> Bool {
    return s.hasPrefix("http://") || s.hasPrefix("https://")
}

func downloadBytes(url: String) async throws -> Data {
    let resp = try await httpGet(url: URL(string: url)!)
    guard (200..<300).contains(resp.statusCode) else {
        throw NSError(domain: "download", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: "download failed"])
    }
    return resp.body
}

func guessExt(fromName name: String) -> String {
    if let dot = name.lastIndex(of: "."), dot < name.endIndex {
        let ext = name[name.index(after: dot)...]
        if !ext.isEmpty { return String(ext) }
    }
    return "bin"
}

func prettyPrintJson(_ data: Data) {
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
       let s = String(data: pretty, encoding: .utf8) {
        print(s)
    } else {
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

@main
struct Main {
    static func main() async {
        do {
            let cfg = try readConfig()
            if cfg.user_token.isEmpty {
                print("config.json里的 user_token 为空")
                return
            }

            let input: String
            if CommandLine.arguments.count >= 2 {
                input = CommandLine.arguments[1]
            } else {
                print("请输入图片地址(本地路径或URL): ", terminator: "")
                input = readLine() ?? ""
            }

            let source = normalizeInput(input)
            if source.isEmpty {
                print("未输入图片地址")
                return
            }

            var origData: Data
            var name: String

            if isUrl(source) {
                origData = try await downloadBytes(url: source)
                name = URL(string: source)?.lastPathComponent ?? "image"
            } else {
                let url = URL(fileURLWithPath: source)
                origData = try Data(contentsOf: url)
                name = url.lastPathComponent
            }

            var uploadData = origData
            var mimeType = "application/octet-stream"
            var ext = guessExt(fromName: name)

            if cfg.enable_webp {
                let q = (cfg.webp_quality <= 0 || cfg.webp_quality > 100) ? 95 : cfg.webp_quality
                uploadData = try runCwebp(input: origData, quality: q)
                mimeType = "image/webp"
                ext = "webp"
            }

            let key = "\(md5Hex(uploadData)).\(ext)"

            let token = try await getQiniuUploadToken(userToken: cfg.user_token, qiniuTokenUrl: cfg.qiniu_token_url)
            if token.isEmpty {
                print("上传失败: qiniu-token failed")
                return
            }

            let host = await queryUploadHost(uploadToken: token, bucket: cfg.bucket)
            var uploadUrl = URL(string: "https://\(host)")!

            func doUpload(_ url: URL) async throws -> HttpResponse {
                return try await httpPostMultipart(
                    url: url,
                    fields: ["token": token, "key": key],
                    fileFieldName: "file",
                    fileName: key,
                    mimeType: mimeType,
                    fileData: uploadData
                )
            }

            var resp = try await doUpload(uploadUrl)
            if !(200..<300).contains(resp.statusCode) {
                let bodyStr = String(data: resp.body, encoding: .utf8) ?? ""
                if bodyStr.contains("no such domain") {
                    uploadUrl = URL(string: "https://upload-z2.qiniup.com")!
                    resp = try await doUpload(uploadUrl)
                }
            }

            if !(200..<300).contains(resp.statusCode) {
                let bodyStr = String(data: resp.body, encoding: .utf8) ?? ""
                print("上传失败: qiniu upload failed: \(resp.statusCode) \(bodyStr)")
                return
            }

            print("上传成功")
            print("response_json:")
            prettyPrintJson(resp.body)
        } catch {
            print("上传失败: \(error)")
        }
    }
}

// CommonCrypto MD5
import CommonCrypto
