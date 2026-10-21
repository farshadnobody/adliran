import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class Store {
  static const _s = FlutterSecureStorage();
  static final changes = ValueNotifier<int>(0);
  static Set<String> savedKeys = {};

  // ---------- اعتبارنامه و کد پیامک ----------
  static Future<void> saveCreds(String nc, String pw) async {
    await _s.write(key: 'nc', value: nc);
    await _s.write(key: 'pw', value: pw);
  }

  static Future<Map<String, String>?> creds() async {
    final nc = await _s.read(key: 'nc'), pw = await _s.read(key: 'pw');
    return (nc == null || pw == null) ? null : {'nc': nc, 'pw': pw};
  }

  static Future<void> clearCreds() async {
    await _s.delete(key: 'nc');
    await _s.delete(key: 'pw');
    await clearSms();
  }

  static Future<void> saveSms(String code) async {
    await _s.write(key: 'sms', value: code);
    await _s.write(key: 'smsAt', value: DateTime.now().millisecondsSinceEpoch.toString());
  }

  static Future<int?> smsAgeSeconds() async {
    final at = int.tryParse(await _s.read(key: 'smsAt') ?? '');
    if (at == null) return null;
    return (DateTime.now().millisecondsSinceEpoch - at) ~/ 1000;
  }

  /// کد پیامکی که هنوز معتبر است (کمتر از ۲۳ ساعت) یا null
  static Future<String?> smsCode() async {
    final age = await smsAgeSeconds();
    if (age == null || age > 23 * 3600) return null;
    return _s.read(key: 'sms');
  }

  static Future<void> clearSms() async {
    await _s.delete(key: 'sms');
    await _s.delete(key: 'smsAt');
  }

  // ---------- ابلاغیه‌های ذخیره‌شده ----------
  static Future<Directory> _root() async {
    final d = await getApplicationDocumentsDirectory();
    final r = Directory('${d.path}/notices');
    if (!await r.exists()) await r.create(recursive: true);
    return r;
  }

  static String safe(String t) {
    final s = t.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'unknown' : (s.length > 80 ? s.substring(0, 80) : s);
  }

  static String key(Map n) => safe('${n['NoticedDocNo'] ?? n['ObjectId'] ?? ''}');

  static Future<void> loadKeys() async {
    final r = await _root();
    savedKeys = {
      for (final e in r.listSync())
        if (e is Directory && File('${e.path}/abelaghie.pdf').existsSync()) e.path.split(Platform.pathSeparator).last
    };
  }

  static Future<Directory?> savedDir(Map n) async {
    final d = Directory('${(await _root()).path}/${key(n)}');
    return File('${d.path}/abelaghie.pdf').existsSync() ? d : null;
  }

  static Future<Directory> saveNotice(Map n, List<int> pdf, Map<String, List<int>> files) async {
    final d = Directory('${(await _root()).path}/${key(n)}');
    await d.create(recursive: true);
    await File('${d.path}/abelaghie.pdf').writeAsBytes(pdf);
    for (final e in files.entries) {
      await File('${d.path}/${e.key}').writeAsBytes(e.value);
    }
    await File('${d.path}/info.json')
        .writeAsString(jsonEncode({...n, 'savedAt': DateTime.now().toIso8601String()}));
    savedKeys.add(key(n));
    changes.value++;
    return d;
  }

  static Future<List<Map<String, dynamic>>> savedList() async {
    final out = <Map<String, dynamic>>[];
    for (final e in (await _root()).listSync()) {
      final f = File('${e.path}/info.json');
      if (e is Directory && f.existsSync()) {
        try {
          out.add(Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
        } catch (_) {}
      }
    }
    out.sort((a, b) => '${b['WebDateTime'] ?? ''}'.compareTo('${a['WebDateTime'] ?? ''}'));
    return out;
  }

  static List<File> files(Directory d) =>
      d.listSync().whereType<File>().where((f) => !f.path.endsWith('info.json')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  static Future<void> delete(Map n) async {
    final d = await savedDir(n);
    if (d != null) await d.delete(recursive: true);
    savedKeys.remove(key(n));
    changes.value++;
  }
}
