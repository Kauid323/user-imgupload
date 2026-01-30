import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:img_util_dart/uploader.dart';

Future<void> main(List<String> args) async {
  final exePath = Platform.script.toFilePath();
  final exeDir = Directory(p.dirname(exePath));
  File configFile = File(p.join(exeDir.path, 'config.json'));
  if (!await configFile.exists()) {
    final parent = exeDir.parent;
    configFile = File(p.join(parent.path, 'config.json'));
  }

  Config cfg;
  try {
    cfg = await loadConfig(configFile);
  } catch (e) {
    stdout.writeln('找不到或无法解析config.json: $e');
    exit(1);
  }

  if (cfg.userToken.isEmpty) {
    stdout.writeln('config.json里的 user_token 为空');
    exit(1);
  }

  String pathOrUrl;
  if (args.isNotEmpty && args.first.trim().isNotEmpty) {
    pathOrUrl = args.first.trim();
  } else {
    stdout.write('请输入图片地址(本地路径或URL): ');
    final input = stdin.readLineSync(encoding: systemEncoding);
    pathOrUrl = (input ?? '').trim();
  }
  if (pathOrUrl.length >= 2) {
    final first = pathOrUrl[0];
    final last = pathOrUrl[pathOrUrl.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      pathOrUrl = pathOrUrl.substring(1, pathOrUrl.length - 1).trim();
    }
  }
  if (pathOrUrl.isEmpty) {
    stdout.writeln('未输入图片地址');
    exit(1);
  }

  try {
    final respText = await uploadImage(pathOrUrl: pathOrUrl, cfg: cfg);
    stdout.writeln('上传成功');
    stdout.writeln('response_json:');

    try {
      final obj = jsonDecode(respText);
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(obj));
    } catch (_) {
      stdout.writeln(respText);
    }
  } catch (e) {
    stdout.writeln('上传失败: $e');
    exit(1);
  }
}
