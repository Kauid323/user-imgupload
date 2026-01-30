import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const String defaultUploadHost = 'upload-z2.qiniup.com';

class Config {
  final String userToken;
  final bool enableWebp;
  final int webpQuality;
  final String bucket;
  final String qiniuTokenUrl;

  Config({
    required this.userToken,
    required this.enableWebp,
    required this.webpQuality,
    required this.bucket,
    required this.qiniuTokenUrl,
  });

  static Config fromJson(Map<String, dynamic> json) {
    return Config(
      userToken: (json['user_token'] ?? '').toString().trim(),
      enableWebp: json['enable_webp'] == true,
      webpQuality: int.tryParse((json['webp_quality'] ?? 95).toString()) ?? 95,
      bucket: (json['bucket'] ?? 'chat68').toString(),
      qiniuTokenUrl: (json['qiniu_token_url'] ?? 'https://chat-go.jwzhd.com/v1/misc/qiniu-token').toString(),
    );
  }
}

class InputData {
  final List<int> bytes;
  final String name;
  final String? contentType;

  InputData({required this.bytes, required this.name, required this.contentType});
}

bool isUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

String md5Hex(List<int> bytes) {
  return crypto.md5.convert(bytes).toString();
}

Future<Config> loadConfig(File configFile) async {
  final txt = await configFile.readAsString();
  final obj = jsonDecode(txt) as Map<String, dynamic>;
  return Config.fromJson(obj);
}

Future<InputData> readInputBytes(String pathOrUrl) async {
  if (isUrl(pathOrUrl)) {
    final uri = Uri.parse(pathOrUrl);
    final resp = await http.get(uri);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('download failed: ${resp.statusCode} ${resp.body}');
    }
    final contentType = resp.headers['content-type']?.split(';').first.trim();
    final name = (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'image');
    return InputData(bytes: resp.bodyBytes, name: name, contentType: contentType);
  }

  final file = File(pathOrUrl);
  final bytes = await file.readAsBytes();
  final name = p.basename(pathOrUrl);
  final contentType = lookupMimeType(name);
  return InputData(bytes: bytes, name: name, contentType: contentType);
}

String normalizeHost(String domainOrUrl) {
  var s = domainOrUrl.trim();
  if (s.isEmpty) return defaultUploadHost;

  if (s.startsWith('http://') || s.startsWith('https://')) {
    try {
      final u = Uri.parse(s);
      if (u.host.isNotEmpty) return u.host;
    } catch (_) {}
  }

  if (s.contains('/')) {
    s = s.split('/').first;
  }
  return s.isEmpty ? defaultUploadHost : s;
}

Future<List<int>> toWebpViaCwebp(List<int> inputBytes, int quality) async {
  var q = quality;
  if (q <= 0 || q > 100) q = 95;

  final tmpDir = Directory.systemTemp;
  final inFile = File(p.join(tmpDir.path, 'imgutil_${DateTime.now().millisecondsSinceEpoch}_${pid}.input'));
  final outFile = File(p.join(tmpDir.path, 'imgutil_${DateTime.now().millisecondsSinceEpoch}_${pid}.webp'));

  await inFile.writeAsBytes(inputBytes, flush: true);

  final result = await Process.run('cwebp', ['-q', '$q', inFile.path, '-o', outFile.path]);
  try {
    await inFile.delete();
  } catch (_) {}

  if (result.exitCode != 0) {
    try {
      await outFile.delete();
    } catch (_) {}
    throw Exception('cwebp failed: ${result.stdout}\n${result.stderr}');
  }

  final webp = await outFile.readAsBytes();
  try {
    await outFile.delete();
  } catch (_) {}
  return webp;
}

Future<String> getQiniuUploadToken(String userToken, String qiniuTokenUrl) async {
  final resp = await http.get(
    Uri.parse(qiniuTokenUrl),
    headers: {
      'token': userToken,
      'Content-Type': 'application/json',
    },
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('qiniu-token http error: ${resp.statusCode} ${resp.body}');
  }
  final payload = jsonDecode(resp.body) as Map<String, dynamic>;
  if ((payload['code'] as num?)?.toInt() != 1) {
    throw Exception('qiniu-token api error: ${resp.body}');
  }
  final data = payload['data'] as Map<String, dynamic>?;
  final token = data?['token']?.toString();
  if (token == null || token.isEmpty) {
    throw Exception('qiniu-token missing token: ${resp.body}');
  }
  return token;
}

Future<String> queryUploadHost(String uploadToken, String bucket) async {
  final ak = uploadToken.split(':').first;
  final url = Uri.parse('https://api.qiniu.com/v4/query?ak=${Uri.encodeQueryComponent(ak)}&bucket=${Uri.encodeQueryComponent(bucket)}');
  try {
    final resp = await http.get(url);
    if (resp.statusCode < 200 || resp.statusCode >= 300) return defaultUploadHost;
    final payload = jsonDecode(resp.body) as Map<String, dynamic>;
    final hosts = payload['hosts'];
    if (hosts is! List || hosts.isEmpty) return defaultUploadHost;
    final up = (hosts.first as Map?)?['up'] as Map?;
    final domains = up?['domains'];
    if (domains is! List || domains.isEmpty) return defaultUploadHost;
    final domain = domains.first?.toString();
    if (domain == null || domain.isEmpty) return defaultUploadHost;
    return normalizeHost(domain);
  } catch (_) {
    return defaultUploadHost;
  }
}

Future<String> uploadOnce({
  required String uploadUrl,
  required String uploadToken,
  required String key,
  required List<int> bytes,
  required String mimeType,
}) async {
  final req = http.MultipartRequest('POST', Uri.parse(uploadUrl));
  req.headers['user-agent'] = 'QiniuDart';
  req.headers['accept-encoding'] = 'gzip';

  req.fields['token'] = uploadToken;
  req.fields['key'] = key;
  req.files.add(http.MultipartFile.fromBytes(
    'file',
    bytes,
    filename: key,
    contentType: http_parser.MediaType.parse(mimeType),
  ));

  final streamed = await req.send();
  final resp = await http.Response.fromStream(streamed);

  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw Exception('qiniu upload failed: ${resp.statusCode} ${resp.body} (uploadUrl=$uploadUrl)');
  }
  return resp.body;
}

Future<String> uploadImage({
  required String pathOrUrl,
  required Config cfg,
}) async {
  final inData = await readInputBytes(pathOrUrl);

  List<int> uploadBytes;
  String mimeType;
  String extension;

  if (cfg.enableWebp) {
    uploadBytes = await toWebpViaCwebp(inData.bytes, cfg.webpQuality);
    mimeType = 'image/webp';
    extension = 'webp';
  } else {
    uploadBytes = inData.bytes;
    mimeType = inData.contentType ?? 'application/octet-stream';
    extension = p.extension(inData.name).replaceFirst('.', '');
    if (extension.isEmpty) {
      extension = extensionFromMime(mimeType) ?? 'bin';
    }
  }

  final key = '${md5Hex(uploadBytes)}.$extension';
  final utoken = await getQiniuUploadToken(cfg.userToken, cfg.qiniuTokenUrl);
  final host = await queryUploadHost(utoken, cfg.bucket);
  final uploadUrl = 'https://$host';

  try {
    return await uploadOnce(
      uploadUrl: uploadUrl,
      uploadToken: utoken,
      key: key,
      bytes: uploadBytes,
      mimeType: mimeType,
    );
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('no such domain')) {
      return await uploadOnce(
        uploadUrl: 'https://$defaultUploadHost',
        uploadToken: utoken,
        key: key,
        bytes: uploadBytes,
        mimeType: mimeType,
      );
    }
    rethrow;
  }
}

String? extensionFromMime(String mimeType) {
  final ext = extensionFromMimeType(mimeType);
  return ext;
}

String? extensionFromMimeType(String mimeType) {
  // `mime` package provides lookupMimeType, but not reverse mapping reliably.
  // Keep it minimal.
  final mt = mimeType.toLowerCase();
  if (mt.contains('png')) return 'png';
  if (mt.contains('jpeg') || mt.contains('jpg')) return 'jpg';
  if (mt.contains('gif')) return 'gif';
  if (mt.contains('webp')) return 'webp';
  return null;
}
