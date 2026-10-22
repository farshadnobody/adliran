import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'jalali.dart';

/// برای نسخه‌ی ریلیز این را false کنید:
/// منوی «لاگ» مخفی می‌شود و هیچ چیزی ثبت یا ذخیره نمی‌شود.
const bool kEnableLog = true;

class LogEntry {
  final DateTime time;
  final String level; // error | warn | info
  final String where, message;
  final String? detail;
  LogEntry(this.time, this.level, this.where, this.message, this.detail);

  String get timeStr {
    String t(int v) => v.toString().padLeft(2, '0');
    return '${jstr(time)}  ${t(time.hour)}:${t(time.minute)}:${t(time.second)}';
  }

  Map<String, dynamic> toJson() =>
      {'t': time.toIso8601String(), 'l': level, 'w': where, 'm': message, 'd': detail};

  static LogEntry fromJson(Map<String, dynamic> j) => LogEntry(
        DateTime.tryParse('${j['t']}') ?? DateTime.now(),
        '${j['l'] ?? 'info'}',
        '${j['w'] ?? ''}',
        '${j['m'] ?? ''}',
        j['d'] as String?,
      );
}

/// لاگ داخل برنامه (برای بررسی خطاهای سرور، انقضای نشست و ...)
class AppLog {
  /// جدیدترین اول
  static final entries = ValueNotifier<List<LogEntry>>(const []);
  static const _max = 300;
  static File? _file;
  static Timer? _timer;

  static Future<void> init() async {
    if (!kEnableLog || kIsWeb) return;
    try {
      final d = await getApplicationDocumentsDirectory();
      _file = File('${d.path}/app_log.json');
      if (_file!.existsSync()) {
        final l = jsonDecode(await _file!.readAsString()) as List;
        entries.value = [for (final e in l) LogEntry.fromJson(Map<String, dynamic>.from(e as Map))];
      }
    } catch (_) {}
  }

  /// رمز، توکن و امضا هرگز در لاگ نمی‌مانند
  static String _redact(String s) => s.replaceAllMapped(
        RegExp(r'("(?:token|tokenId|PersonPassword|OTPPassword|NoticeSignedData|password)"\s*:\s*")[^"]*',
            caseSensitive: false),
        (m) => '${m[1]}***',
      );

  static void add(String level, String where, String message, {String? detail}) {
    if (!kEnableLog) return;
    final e = LogEntry(DateTime.now(), level, where, _redact(message), detail == null ? null : _redact(detail));
    final l = [e, ...entries.value];
    if (l.length > _max) l.removeRange(_max, l.length);
    entries.value = l;
    _save();
  }

  static void error(String where, Object err, {StackTrace? st, String? detail}) {
    if (!kEnableLog) return;
    final stack = st == null ? null : st.toString().split('\n').take(10).join('\n');
    final d = [if (detail != null) detail, if (stack != null) stack].join('\n');
    add('error', where, '${err.runtimeType}: $err', detail: d.isEmpty ? null : d);
  }

  static void _save() {
    final f = _file;
    if (f == null) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () async {
      try {
        await f.writeAsString(jsonEncode([for (final e in entries.value) e.toJson()]));
      } catch (_) {}
    });
  }

  static Future<void> clear() async {
    entries.value = const [];
    try {
      if (_file != null && _file!.existsSync()) await _file!.delete();
    } catch (_) {}
  }

  /// متن کامل لاگ برای کپی
  static String dump() => entries.value
      .map((e) => '[${e.timeStr}] ${e.level.toUpperCase()} | ${e.where}\n${e.message}${e.detail == null ? '' : '\n${e.detail}'}')
      .join('\n--------------------\n');
}
