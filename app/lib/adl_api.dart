import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'app_log.dart';
import 'jalali.dart';
import 'store.dart';

class LoginRejected implements Exception {
  final String message;
  LoginRejected(this.message);
  @override
  String toString() => message;
}

/// کد ملی یا رمز عبور اشتباه است (پاسخ صریح سرور در مرحله‌ی ۱)
class WrongCredentials extends LoginRejected {
  WrongCredentials(super.message);
}

class SiteUnavailable implements Exception {
  final String message;
  SiteUnavailable(this.message);
  @override
  String toString() => 'سایت در دسترس نیست ($message)';
}

class SessionExpired implements Exception {}

/// در حالت دستی: کد پیامک لازم است (ندارد، منقضی یا اشتباه است)
class NeedSmsCode implements Exception {
  final String message;
  NeedSmsCode([this.message = 'کد پیامک لازم است']);
  @override
  String toString() => message;
}

typedef Json = Map<String, dynamic>;

class AdlApi {
  /// روی وب (Chrome) مرورگر اجازه‌ی ارتباط مستقیم با سایت عدل‌ایران را نمی‌دهد (CORS/کوکی)؛
  /// درخواست‌ها از طریق adl_proxy.py که روی همین کامپیوتر اجرا می‌شود رد می‌شوند.
  static const proxy = 'http://localhost:8787';

  static const system = 'ENoticeServices';
  static const smsNumber = '500049';

  /// کد ۵ رقمی ثابتِ پیامک ورود
  static const smsFixedCode = '12345';

  /// TODO: در اسکریپت نمونه 1 است (سرور خودش پیامک می‌فرستد).
  /// برای حالت «ارسال پیامک توسط کاربر» مقدار واقعی را از درخواست مرورگر بردارید.
  static const otpType = 1;

  static const hostSets = [
    ['https://iehraz.adliran.ir', 'https://eblagh1.adliran.ir', '/ENotice/Index'],
    ['https://iehraz2.adliran.ir', 'https://eblagh2.adliran.ir', '/Dashboard/NoticeIndex'],
  ];
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  late Dio _dio;
  String _login = '', _app = '', _ret = '';
  bool _ready = false;

  AdlApi() {
    _reset();
  }

  void _reset() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      validateStatus: (s) => s != null && s < 500,
      headers: {
        if (!kIsWeb) 'User-Agent': _ua,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    ));
    if (kIsWeb) {
      _dio.interceptors.add(InterceptorsWrapper(
        onRequest: (o, h) {
          final target = o.uri.toString();
          final origin = o.headers.remove('Origin');
          final referer = o.headers.remove('Referer');
          o.headers.remove('User-Agent');
          if (origin != null) o.headers['X-Fwd-Origin'] = origin;
          if (referer != null) o.headers['X-Fwd-Referer'] = referer;
          o.baseUrl = '';
          o.path = '$proxy/proxy';
          o.queryParameters = {'url': target};
          h.next(o);
        },
        onResponse: (r, h) {
          // پراکسی ریدایرکت‌ها را به 200 تبدیل می‌کند تا مرورگر خودش دنبالشان نرود
          final real = int.tryParse(r.headers.value('x-real-status') ?? '');
          if (real != null) r.statusCode = real;
          final loc = r.headers.value('x-real-location');
          if (loc != null) r.headers.set('location', loc);
          h.next(r);
        },
      ));
    } else {
      _dio.interceptors.add(CookieManager(CookieJar()));
      // گواهی سرورهای عدل‌ایران توسط اندروید معتبر شناخته نمی‌شود؛
      // فقط برای دامنه‌ی adliran.ir خطای گواهی نادیده گرفته می‌شود.
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.badCertificateCallback = (X509Certificate cert, String host, int port) =>
              host == 'adliran.ir' || host.endsWith('.adliran.ir');
          return c;
        },
      );
    }
    // ثبت پاسخ‌های غیرعادی سرور در لاگ (بدنه‌ی درخواست‌ها هرگز ثبت نمی‌شود)
    _dio.interceptors.add(InterceptorsWrapper(
      onResponse: (r, h) {
        _logResponse(r);
        h.next(r);
      },
      onError: (e, h) {
        if (e.requestOptions.extra['quiet'] != true || e.response == null) {
          final r = e.response;
          AppLog.add(
            'error',
            _tag(e.requestOptions),
            r != null ? 'HTTP ${r.statusCode}' : '${e.type.name}: ${e.error ?? e.message}',
            detail: r != null ? _snip(r.data) : null,
          );
        }
        h.next(e);
      },
    ));
  }

  static String _tag(RequestOptions o) {
    final target = '${o.queryParameters['url'] ?? o.uri}';
    final u = Uri.tryParse(target);
    return '${o.method} ${u == null ? target : '${u.host}${u.path}'}';
  }

  /// خلاصه‌ی بدنه‌ی پاسخ (بدون تگ HTML و فایل باینری)
  static String? _snip(Object? data, {int max = 600}) {
    if (data == null) return null;
    String t;
    if (data is List<int>) {
      if (data.length > 4 && data[0] == 0x25 && data[1] == 0x50) return '[PDF ${data.length} bytes]';
      t = utf8.decode(data, allowMalformed: true);
    } else {
      t = '$data';
    }
    t = t
        .replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.isEmpty) return '[بدنه‌ی خالی]';
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  void _logResponse(Response r) {
    if (r.requestOptions.extra['quiet'] == true) return;
    final code = r.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      // پاسخ موفق ولی با خطای کسب‌وکاری داخل بدنه
      final d = r.data;
      if (d is String && d.contains('"errorCode"')) {
        AppLog.add('warn', _tag(r.requestOptions), 'HTTP $code ولی بدنه حاوی errorCode است', detail: _snip(d));
      }
      return;
    }
    final loc = r.headers.value('location');
    AppLog.add(
      code >= 400 ? 'error' : 'warn',
      _tag(r.requestOptions),
      'HTTP $code${loc != null ? '  →  $loc' : ''}${code == 302 ? '  (احتمالاً نشست منقضی)' : ''}',
      detail: _snip(r.data),
    );
  }

  /// نشست (کوکی‌های) پراکسی را پاک می‌کند — فقط وب
  Future<void> _resetProxy() async {
    try {
      await Dio().get('$proxy/reset');
    } on DioException {
      throw SiteUnavailable('پراکسی در دسترس نیست؛ adl_proxy.py را اجرا کنید');
    }
  }

  // ---------- ابزارهای HTTP ----------

  /// معادل json.dumps پایتون: جداکننده‌ی «, » و «: » و (در صورت ascii) escape به \\uXXXX
  static String _pyJson(Object? v, {required bool ascii}) {
    final sb = StringBuffer();
    void str(String t) {
      sb.write('"');
      for (final u in t.codeUnits) {
        if (u == 0x22) {
          sb.write('\\"');
        } else if (u == 0x5C) {
          sb.write('\\\\');
        } else if (u == 0x0A) {
          sb.write('\\n');
        } else if (u == 0x0D) {
          sb.write('\\r');
        } else if (u == 0x09) {
          sb.write('\\t');
        } else if (u < 0x20 || (ascii && u > 0x7F)) {
          sb.write('\\u${u.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(u);
        }
      }
      sb.write('"');
    }

    void w(Object? x) {
      if (x is Map) {
        sb.write('{');
        var first = true;
        x.forEach((k, val) {
          if (!first) sb.write(', ');
          first = false;
          str('$k');
          sb.write(': ');
          w(val);
        });
        sb.write('}');
      } else if (x is List) {
        sb.write('[');
        for (var i = 0; i < x.length; i++) {
          if (i > 0) sb.write(', ');
          w(x[i]);
        }
        sb.write(']');
      } else if (x is String) {
        str(x);
      } else if (x == null) {
        sb.write('null');
      } else {
        sb.write('$x');
      }
    }

    w(v);
    return sb.toString();
  }
  String _origin(String u) {
    final p = u.split('/');
    return '${p[0]}//${p[2]}';
  }

  Future<Response<String>> _postJson(String url, Object body,
          {String? referer, bool anyStatus = false, bool quiet = false}) =>
      _dio.post<String>(url,
          data: _pyJson(body, ascii: true),
          options: Options(
            contentType: 'application/json;charset=UTF-8',
            responseType: ResponseType.plain,
            validateStatus: anyStatus ? (_) => true : null,
            extra: quiet ? {'quiet': true} : null,
            headers: {
              'X-Requested-With': 'XMLHttpRequest',
              'Origin': _origin(url),
              if (referer != null) 'Referer': referer,
            },
          ));

  Future<Response<List<int>>> _form(String url, Map<String, dynamic> data, String referer) {
    final d = <String, String>{
      for (final e in data.entries)
        if (e.value != null) e.key: '${e.value}'
    };
    return _dio.post<List<int>>(url,
        data: d,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.bytes,
          headers: {
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Origin': _app,
            'Referer': referer,
          },
        ));
  }

  String _text(Response<List<int>> r) => utf8.decode(r.data ?? [], allowMalformed: true);

  bool _isPdf(List<int> b) =>
      b.length >= 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46;

  bool _looksLikeFile(Response<List<int>> r) {
    final ct = (r.headers.value('content-type') ?? '').toLowerCase();
    return r.statusCode == 200 &&
        (_isPdf(r.data ?? []) || ct.contains('pdf') || ct.contains('image') || ct.contains('octet-stream'));
  }

  String _ext(Response<List<int>> r, String def) {
    final cd = r.headers.value('content-disposition') ?? '';
    final m = RegExp('filename\\*?=(?:UTF-8\'\')?"?([^";]+)').firstMatch(cd);
    if (m != null && m.group(1)!.contains('.')) return m.group(1)!.split('.').last.toLowerCase();
    final ct = (r.headers.value('content-type') ?? '').toLowerCase();
    if (ct.contains('pdf') || _isPdf(r.data ?? [])) return 'pdf';
    if (ct.contains('jpeg') || ct.contains('jpg')) return 'jpg';
    if (ct.contains('png')) return 'png';
    return def;
  }

  List<int>? _tryB64(String s) {
    try {
      final b = base64Decode(s.trim().replaceAll('"', ''));
      return _isPdf(b) ? b : null;
    } catch (_) {
      return null;
    }
  }

  // ---------- ورود ----------
  Future<String> _step1(String login, String ret, String nc, String pw) async {
    final msg = {
      'NationalityCode': nc,
      'PersonPassword': pw,
      'SystemName': system,
      'returnUrl': ret,
      'systemName': system,
      'personLoginType': '1',
      'loginTitle': 'سامانه ابلاغ الكترونيك قضايي',
      'OtpType': otpType,
    };
    Json d;
    try {
      final r = await _postJson(
          '$login/Login/CheckPersonLogin',
          {'requestMessage': _pyJson(msg, ascii: false), 'captchaValue': '', 'captchaId': ''},
          referer: '$login/');
      if (r.statusCode != 200) {
        // سرور خطای ورود (مثل رمز اشتباه) را با HTTP 409 و بدنه‌ی JSON برمی‌گرداند
        Json? j;
        try {
          final x = jsonDecode(r.data ?? '');
          if (x is Map) j = Json.from(x);
        } catch (_) {}
        if (j != null && (r.statusCode ?? 0) < 500 && '${j['message'] ?? ''}'.isNotEmpty) {
          throw _rejection('${j['message']}');
        }
        var body = (r.data ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (body.length > 300) body = body.substring(0, 300);
        throw SiteUnavailable('HTTP ${r.statusCode} $body');
      }
      d = Json.from(jsonDecode(r.data ?? ''));
    } on DioException catch (e) {
      throw SiteUnavailable('${e.type.name}: ${e.error ?? e.message ?? e}');
    } on FormatException catch (e) {
      throw SiteUnavailable('پاسخ JSON نیست: ${e.message}');
    }
    final tok = d['token'];
    if (d['errorCode'] != 200 || tok == null || tok == '') {
      throw _rejection('${d['message'] ?? 'ورود رد شد'}');
    }
    return tok as String;
  }

  /// پیام سرور درباره‌ی کد ملی/رمز ← WrongCredentials، بقیه ← LoginRejected
  static LoginRejected _rejection(String m) {
    final wrong = m.contains('رمز') || m.contains('شماره ملی') || m.contains('نام کاربری') || m.contains('کد ملی');
    return wrong
        ? WrongCredentials('کد ملی یا رمز عبور اشتباه است.\nلطفاً با دقت دوباره وارد کنید.')
        : LoginRejected(m);
  }

  Future<(String, String)> _step2(String nc, String pw, String otp, String token) async {
    final msg = {
      'NationalityCode': nc,
      'PersonPassword': pw,
      'OTPPassword': otp,
      'SystemName': system,
      'ReturnUrl': _ret,
      'OtpType': otpType,
    };
    final r = await _postJson('$_login/Login/CheckPersonOtpLogin',
        {'requestMessage': _pyJson(msg, ascii: false), 'token': token},
        referer: '$_login/');
    Json d;
    try {
      d = Json.from(jsonDecode(r.data ?? ''));
    } catch (_) {
      throw LoginRejected('پاسخ نامعتبر از سرور');
    }
    final tok = d['token'];
    if (d['errorCode'] != 200 || tok == null || tok == '') {
      throw LoginRejected('${d['message'] ?? 'کد پیامک رد شد'}');
    }
    return (tok as String, (d['returnUrl'] ?? _ret) as String);
  }

  Future<void> _step3(String secToken, String ret) async {
    var r = await _dio.post<String>(ret,
        data: {'tokenId': secToken, 'systemName': system},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'text/html,application/xhtml+xml,*/*',
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': _login,
            'Referer': '$_login/',
          },
        ));
    for (var hops = 0; hops < 5 && (r.statusCode ?? 0) >= 300 && (r.statusCode ?? 0) < 400; hops++) {
      final loc = r.headers.value('location');
      if (loc == null) break;
      final next = r.requestOptions.uri.resolve(loc).toString();
      r = await _dio.get<String>(next, options: Options(responseType: ResponseType.plain));
    }
    final t = await _dio.get<String>('$_app/Notice/Home/GetNewEnoticeCount',
        options: Options(
            responseType: ResponseType.plain,
            headers: {'Referer': ret, 'X-Requested-With': 'XMLHttpRequest'}));
    if (t.statusCode == 200) {
      try {
        final j = jsonDecode(t.data ?? '');
        if (j is Map && j.containsKey('NewNoticeCount')) return;
        if (j is int) return;
      } catch (_) {}
    }
    throw LoginRejected('نشست برقرار نشد (HTTP ${t.statusCode})');
  }

  /// آخرین مجموعه‌ی سروری که جواب داد؛ دفعه‌ی بعد اول همان امتحان می‌شود (از انتظار timeout جلوگیری می‌کند)
  static int _preferredHost = 0;

  Future<String> _step1Any(String nc, String pw) async {
    final errs = <String>[];
    final order = [_preferredHost, for (var i = 0; i < hostSets.length; i++) if (i != _preferredHost) i];
    for (final i in order) {
      final h = hostSets[i];
      final sw = Stopwatch()..start();
      try {
        final tok = await _step1(h[0], h[1] + h[2], nc, pw);
        _login = h[0];
        _app = h[1];
        _ret = h[1] + h[2];
        _preferredHost = i;
        AppLog.add('info', 'ورود', 'مرحله ۱ (کد ملی و رمز) روی ${h[0]}: ${sw.elapsedMilliseconds} میلی‌ثانیه');
        return tok;
      } on SiteUnavailable catch (e) {
        errs.add('${h[0]} ← ${e.message}');
        AppLog.add('warn', 'ورود', 'مرحله ۱ روی ${h[0]} ناموفق بعد از ${sw.elapsedMilliseconds} میلی‌ثانیه', detail: e.message);
      } on LoginRejected {
        rethrow;
      } catch (e, st) {
        // هر خطای غیرمنتظره (مثلاً خطای کد/تبدیل نوع) هم دیده شود
        errs.add('${h[0]} ← ${e.runtimeType}: $e');
        AppLog.error('ورود مرحله ۱ (${h[0]})', e, st: st);
      }
    }
    throw SiteUnavailable('هیچ‌کدام از سرورها جواب ندادند\n${errs.join('\n')}');
  }

  /// ارسال پیامک `5#کدملی#کد` به 500049 در پس‌زمینه (فقط اندروید)
  static const _ch = MethodChannel('adl/sms');

  /// فهرست سیم‌کارت‌های فعال [{id, name}] (خالی اگر مجوز/سیم‌کارت نباشد)
  static Future<List<Map<String, dynamic>>> listSims() async {
    if (kIsWeb) return [];
    try {
      if (await _ch.invokeMethod<bool>('requestPermission') != true) return [];
      final l = await _ch.invokeMethod<List>('sims') ?? [];
      return [for (final e in l) Map<String, dynamic>.from(e as Map)];
    } catch (e, st) {
      AppLog.error('فهرست سیم‌کارت‌ها', e, st: st);
      return [];
    }
  }

  Future<String> _sendSms(String nc) async {
    if (await _ch.invokeMethod<bool>('requestPermission') != true) {
      AppLog.add('error', 'پیامک', 'مجوز SEND_SMS داده نشد');
      throw LoginRejected('مجوز ارسال پیامک داده نشد');
    }
    const code = smsFixedCode;
    AppLog.add('info', 'پیامک', 'ارسال «5#کدملی#$code» به $smsNumber (سیم‌کارت انتخابی: ${Store.simId ?? 'پیش‌فرض'})');
    Map? res;
    try {
      res = await _ch.invokeMethod<Map>('send', {'to': smsNumber, 'text': '5#$nc#$code', 'subId': Store.simId});
    } catch (e, st) {
      AppLog.error('ارسال پیامک', e, st: st, detail: 'به $smsNumber');
      rethrow;
    }
    final ok = res?['ok'] == true;
    final log = ((res?['log'] as List?) ?? const []).join('\n');
    AppLog.add(ok ? 'info' : 'error', 'پیامک',
        ok ? 'پیامک به سیستم‌عامل تحویل شد و ارسال تأیید شد' : 'ارسال پیامک ناموفق بود', detail: log);
    if (!ok) {
      throw LoginRejected('ارسال پیامک ناموفق بود.\n$log\nتا رفع مشکل می‌توانید حالت «دستی» را بزنید.');
    }
    // عمداً اینجا ذخیره نمی‌شود؛ فقط بعد از ورود موفق ذخیره می‌شود (_signInCore)
    return code;
  }

  String? _pendingToken;

  /// دقیقاً مثل اسکریپت پایتون: مرحله ۱ (سرور پیامک می‌فرستد) ← کاربر کد را وارد می‌کند ← مراحل ۲ و ۳
  Future<void> _signInManual(String nc, String pw, String? code) async {
    if (code == null || _pendingToken == null) {
      _reset();
      if (kIsWeb) await _resetProxy();
      _pendingToken = await _step1Any(nc, pw);
      throw NeedSmsCode(code == null
          ? 'پیامک حاوی کد به گوشی شما ارسال شد؛ کد را وارد کنید'
          : 'پیامک جدید ارسال شد؛ کد جدید را وارد کنید');
    }
    try {
      final r = await _step2(nc, pw, code, _pendingToken!);
      await _step3(r.$1, r.$2);
      _pendingToken = null;
      _ready = true;
    } on LoginRejected catch (e) {
      throw NeedSmsCode('کد رد شد (${e.message})');
    }
  }

  /// ورود کامل. حالت خودکار: اگر کد پیامک نداریم/منقضی شده، پیامک جدید می‌فرستد.
  /// حالت دستی: پیامک نمی‌فرستد؛ اگر کد لازم باشد NeedSmsCode پرتاب می‌شود.
  Future<void>? _signing;

  /// اگر همزمان چند درخواست ورود بیاید (مثلاً دو تب) فقط یک ورود (و یک پیامک) انجام می‌شود
  Future<void> signIn({String? nationalCode, String? password, String? manualCode}) {
    final cur = _signing;
    if (cur != null && nationalCode == null && manualCode == null) {
      AppLog.add('info', 'ورود', 'ورود در جریان است؛ منتظر همان می‌مانیم');
      return cur;
    }
    late final Future<void> f;
    f = _signInImpl(nationalCode: nationalCode, password: password, manualCode: manualCode).whenComplete(() {
      if (identical(_signing, f)) _signing = null;
    });
    _signing = f;
    return f;
  }

  Future<void> _signInImpl({String? nationalCode, String? password, String? manualCode}) async {
    try {
      await _signInCore(nationalCode: nationalCode, password: password, manualCode: manualCode);
    } on WrongCredentials catch (e) {
      AppLog.add('warn', 'ورود', 'کد ملی/رمز اشتباه: ${e.message}');
      await Store.clearCreds(); // رمز غلط نباید ذخیره بماند / دوباره امتحان شود
      rethrow;
    } catch (e) {
      if (e is! NeedSmsCode) AppLog.add('error', 'ورود', '${e.runtimeType}: $e');
      rethrow;
    }
  }

  Future<void> _signInCore({String? nationalCode, String? password, String? manualCode}) async {
    if (nationalCode != null) await Store.saveCreds(nationalCode, password ?? '');
    final c = await Store.creds();
    if (c == null) throw LoginRejected('ابتدا وارد شوید');
    final nc = c['nc']!.trim(), pw = c['pw']!.trim();
    _ready = false;
    if (Store.manual) return _signInManual(nc, pw, manualCode);
    final total = Stopwatch()..start();
    for (var attempt = 0; attempt < 4; attempt++) {
      _reset();
      final token = await _step1Any(nc, pw);
      var code = await Store.smsCode();
      var fresh = false;
      DateTime? sentAt;
      if (code == null) {
        if (Store.manual) throw NeedSmsCode();
        sentAt = DateTime.now();
        code = await _sendSms(nc);
        fresh = true;
      } else {
        AppLog.add('info', 'پیامک', 'از کد ذخیره‌شده استفاده شد؛ پیامک جدید ارسال نمی‌شود');
      }
      try {
        final sw = Stopwatch()..start();
        final r = fresh ? await _step2Poll(nc, pw, code, token) : await _step2(nc, pw, code, token);
        AppLog.add('info', 'ورود', 'مرحله ۲ (کد پیامک) ${sw.elapsedMilliseconds} میلی‌ثانیه');
        sw.reset();
        await _step3(r.$1, r.$2);
        AppLog.add('info', 'ورود', 'مرحله ۳ (برقراری نشست) ${sw.elapsedMilliseconds} میلی‌ثانیه');
        // فقط پس از ورود موفق، کدِ تازه‌ارسال‌شده برای ۲۲ ساعت ذخیره می‌شود
        // (کد قدیمیِ ذخیره‌شده دوباره ذخیره نمی‌شود تا زمان انقضایش تمدید نشود)
        if (fresh) await Store.saveSms(code, sentAt: sentAt);
        AppLog.add('info', 'ورود', 'ورود کامل شد؛ مجموع ${total.elapsed.inSeconds} ثانیه، تلاش ${attempt + 1}');
        _ready = true;
        return;
      } on LoginRejected catch (e) {
        AppLog.add('warn', 'ورود', 'کد پیامک رد شد (تلاش ${attempt + 1}): ${e.message}');
        if (Store.manual) {
          await Store.clearSms();
          throw NeedSmsCode('کد اشتباه یا منقضی است (${e.message})');
        }
        await Store.clearSms();
        if (fresh) {
          // پیامک همین الان فرستاده شد و تا ~۴۰ ثانیه پذیرفته نشد؛ تکرار بی‌فایده است
          throw LoginRejected('کد پیامک توسط سرور تأیید نشد (${e.message}).\nاحتمالاً پیامک به ۵۰۰۰۴۹ نرسیده؛ وضعیت آن را در اپ پیامک ببینید.');
        }
        if (attempt == 3) rethrow;
        // کد ذخیره‌شده منقضی بود → دور بعد پیامک تازه می‌فرستیم
      }
    }
  }

  /// بعد از ارسال پیامک: به‌جای ۱۰ ثانیه انتظار ثابت، هر چند ثانیه کد را امتحان می‌کند (تا ~۴۰ ثانیه)
  Future<(String, String)> _step2Poll(String nc, String pw, String code, String token) async {
    final sw = Stopwatch()..start();
    var wait = 3;
    while (true) {
      await Future.delayed(Duration(seconds: wait));
      try {
        return await _step2(nc, pw, code, token);
      } on LoginRejected catch (e) {
        AppLog.add('info', 'ورود', 'کد هنوز پذیرفته نشد (${sw.elapsed.inSeconds} ثانیه بعد از ارسال): ${e.message}');
        if (sw.elapsed.inSeconds >= 40) rethrow;
        wait = 4;
      }
    }
  }

  /// اجرای یک درخواست؛ اگر نشست پریده بود یک بار دوباره وارد می‌شود
  Future<T> run<T>(Future<T> Function() f) async {
    if (!_ready) {
      AppLog.add('info', 'نشست', 'نشست آماده نبود؛ ورود خودکار');
      await signIn();
    }
    try {
      return await f();
    } on SessionExpired {
      AppLog.add('warn', 'نشست', 'نشست منقضی شد؛ ورود دوباره و تکرار درخواست');
      await signIn();
      return await f();
    }
  }

  void _check(Response r) {
    final c = r.statusCode ?? 0;
    if (c == 200) return;
    if (c == 302 || c == 401 || c == 403) throw SessionExpired();
    throw Exception('HTTP $c');
  }

  // ---------- لیست ----------
  Future<List<Json>> _fetchWindow(String from, String to) async {
    final items = <Json>[];
    var page = 1;
    int? total;
    while (true) {
      final r = await _postJson(
          '$_app/Notice/Home/GetAllENotice',
          {
            'pageNumber': page,
            'pageSize': '10',
            'eNotifySearchCriteria': {
              'NoticedDocNo': '', 'NoticedDocCaseNo': '', 'SubjectType': '',
              'IssuerUnitName': '', 'WebDateFrom': '', 'WebDateTo': '',
              'ViewDateFrom': from, 'ViewDateTo': to,
              'FirstViewDateFrom': '', 'FirstViewDateTo': '',
              'CategoryIdToBeFilter': '', 'ShowOnlyNoticeViewByMe': false,
              'DoNotShowNoticeViewByMe': false, 'HasHintNote': false,
            },
          },
          referer: _ret);
      if (r.statusCode == 409) {
        String? m;
        try {
          m = '${(jsonDecode(r.data ?? '') as Map)['message']}';
        } catch (_) {}
        if (m != null && m.contains('ندارید')) {
          AppLog.add('info', 'GetAllENotice', 'HTTP 409: بدون ابلاغیه در بازه $from تا $to', detail: m);
          break;
        }
      }
      _check(r);
      Json data;
      try {
        data = Json.from(jsonDecode(r.data ?? ''));
      } catch (_) {
        AppLog.add('warn', 'GetAllENotice', 'پاسخ JSON نبود (احتمالاً نشست منقضی)', detail: _snip(r.data));
        throw SessionExpired();
      }
      final docs = (data['DocumentList'] as List?) ?? [];
      total ??= (data['TotalCount'] as num?)?.toInt();
      items.addAll(docs.map((e) => Json.from(e as Map)));
      if (docs.isEmpty || (total != null && items.length >= total)) break;
      page++;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return items;
  }

  /// ابلاغیه‌های یک بازه (میلادی)؛ داخلی در تکه‌های ۳۰ روزه
  Future<List<Json>> fetchRange(DateTime start, DateTime end) => run(() async {
        final all = <Json>[];
        final seen = <dynamic>{};
        final last = DateTime.utc(end.year, end.month, end.day);
        var s = DateTime.utc(start.year, start.month, start.day);
        while (!s.isAfter(last)) {
          var e = s.add(const Duration(days: 29));
          if (e.isAfter(last)) e = last;
          for (final n in await _fetchWindow(jstr(s), jstr(e))) {
            if (seen.add(n['ObjectId'])) all.add(n);
          }
          s = e.add(const Duration(days: 1));
        }
        all.sort((a, b) => '${b['WebDateTime'] ?? ''}'.compareTo('${a['WebDateTime'] ?? ''}'));
        return all;
      });

  // ---------- دانلود ----------
  Future<Json> _viewNotice(Json n) async {
    final r = await _postJson('$_app/Notice/Home/SetENoticeToViewStateAndGetEnotice', {
      'objectId': n['ObjectId'],
      'noticedObjectId': n['NoticedDocId'],
      'NoticeSignedData': n['NoticeSignedData'],
    }, referer: _ret);
    _check(r);
    final j = jsonDecode(r.data ?? '');
    if (j is! Map || j['NoticedDocId'] == null) {
      AppLog.add('warn', 'SetENoticeToViewState', 'پاسخ بدون NoticedDocId', detail: _snip(r.data));
      throw Exception('ثبت مشاهده ناموفق');
    }
    return Json.from(j);
  }

  Future<List<int>> _downloadPdf(Json n, void Function(String) status) async {
    final form = {
      'enotifyDocumentId': n['ObjectId'],
      'DocumentId': n['NoticedDocId'],
      'NoticeSignedData': n['NoticeSignedData'],
      'NoticedDocNo': n['NoticedDocNo'],
    };
    const maxRetries = 8;
    var err1 = '';
    String? lastBody;
    for (var i = 0; i <= maxRetries; i++) {
      final r = await _form('$_app/Notice/Home/DownloadENoticeAsPDF', form, _ret);
      if (r.statusCode == 302 || r.statusCode == 401) throw SessionExpired();
      if (_isPdf(r.data ?? [])) return r.data!;
      final t = _text(r);
      err1 = 'HTTP ${r.statusCode}';
      lastBody = _snip(t);
      if ((t.contains('استخراج') || t.contains('دو دقیقه')) && i < maxRetries) {
        AppLog.add('warn', 'DownloadENoticeAsPDF', 'سرور هنوز ابلاغیه را آماده نکرده (تلاش ${i + 1}/$maxRetries)', detail: lastBody);
        status('سرور در حال آماده‌سازی ابلاغیه است (${i + 1}/$maxRetries)...');
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }
      break;
    }
    // روش جایگزین
    final r = await _postJson('$_app/Notice/Home/GetENoticeDocumentAsPDF', form, referer: _ret);
    final b = _tryB64(r.data ?? '');
    if (b != null) return b;
    AppLog.add('error', 'DownloadENoticeAsPDF', 'دانلود ابلاغیه ${n['NoticedDocNo']} ناموفق ($err1)', detail: lastBody);
    throw Exception('دانلود ابلاغیه ناموفق ($err1)');
  }

  Future<({List<int> bytes, String ext})> _downloadAttachment(Json att, String no) async {
    var def = '${att['ContentType'] ?? '.pdf'}'.replaceAll('.', '').toLowerCase();
    if (def.isEmpty) def = 'pdf';
    var r = await _form('$_app/Notice/Home/DownloadAttachmentENoticeAsPDF', {
      'AttachmentItem': jsonEncode(att),
      'ContentType': att['ContentType'] ?? '',
      'RowNum': att['RowNum'] ?? '',
      'NoticedDocNo': no,
    }, _ret);
    if (_looksLikeFile(r)) return (bytes: r.data!, ext: _ext(r, def));
    if (att['AttachmentType'] == 2) {
      r = await _dio.get<List<int>>('$_app/Report/AttachmentPrint.aspx',
          queryParameters: {
            'eblagh': 'true',
            'attachmentId': '${att['AttachmentId']}@${att['AttachmentBatchId']}',
            'attachmentTitle': att['AttachmentTitle'] ?? '',
            'dateTime': '',
          },
          options: Options(responseType: ResponseType.bytes, headers: {'Referer': _ret}));
      if (_looksLikeFile(r)) return (bytes: r.data!, ext: _ext(r, 'pdf'));
    }
    final j = await _postJson('$_app/Notice/Home/GetENoticeAttachmentDataFile',
        {'attachmentInputDataString': jsonEncode(att)}, referer: _ret);
    try {
      final d = jsonDecode(j.data ?? '');
      if (d is Map && d['result'] != null) {
        final typ = '${d['type'] ?? ''}'.toLowerCase();
        if (typ == 'pdf' || typ == 'jpg') return (bytes: base64Decode('${d['result']}'.trim()), ext: typ);
        return (bytes: utf8.encode('${d['result']}'), ext: 'html');
      }
    } catch (_) {}
    AppLog.add('error', 'DownloadAttachment',
        'دانلود پیوست ناموفق — ابلاغیه $no',
        detail: 'AttachmentType=${att['AttachmentType']}  ContentType=${att['ContentType']}  RowNum=${att['RowNum']}  عنوان=${att['AttachmentTitle']}');
    throw Exception('دانلود پیوست ناموفق');
  }

  /// مشاهده + دانلود ابلاغیه و پیوست‌ها + ذخیره در حافظه‌ی گوشی
  Future<Directory?> downloadAndSave(Json n, void Function(String) status) => run(() async {
        status('ثبت مشاهده...');
        try {
          n = {...n, ...await _viewNotice(n)};
        } on SessionExpired {
          rethrow;
        } catch (_) {} // با همان اطلاعات ادامه می‌دهیم
        status('دریافت متن ابلاغیه...');
        final pdf = await _downloadPdf(n, status);
        final files = <String, List<int>>{};
        final atts = (n['AttachmentList'] as List?) ?? [];
        for (var i = 0; i < atts.length; i++) {
          status('دریافت پیوست ${i + 1} از ${atts.length}...');
          final a = Json.from(atts[i] as Map);
          try {
            final r = await _downloadAttachment(a, '${n['NoticedDocNo']}');
            files['${i + 1}_${Store.safe('${a['AttachmentTitle'] ?? 'attachment'}')}.${r.ext}'] = r.bytes;
          } on SessionExpired {
            rethrow;
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (kIsWeb) {
          await Store.saveWebNotice(n, pdf, files);
          return null;
        }
        return Store.saveNotice(n, pdf, files);
      });

  // ---------- صفحه‌ی فایل‌های ابلاغیه ----------
  /// ثبت مشاهده و گرفتن فهرست پیوست‌ها
  Future<Json> openNoticeMeta(Json n) => run(() async {
        try {
          return {...n, ...await _viewNotice(n)};
        } on SessionExpired {
          rethrow;
        } catch (e, st) {
          AppLog.error('ثبت مشاهده ابلاغیه ${n['NoticedDocNo']}', e, st: st);
          return n; // با همان اطلاعات ادامه می‌دهیم
        }
      });

  /// دانلود یک فایل: index = ‎-1‎ متن ابلاغیه، وگرنه شماره‌ی پیوست (از صفر)
  Future<({List<int> bytes, String ext})> downloadPart(Json n, int index, void Function(String) status) =>
      run(() async {
        if (index < 0) return (bytes: await _downloadPdf(n, status), ext: 'pdf');
        final atts = (n['AttachmentList'] as List?) ?? [];
        final a = Json.from(atts[index] as Map);
        return _downloadAttachment(a, '${n['NoticedDocNo']}');
      });

  // ---------- ابلاغیه‌های جدید (مشاهده‌نشده) ----------
  /// سایت: «ابلاغیه‌های جدید» = GetNewENoticeWithoutNoticeText (بر اساس تاریخ ابلاغ).
  /// اگر ابلاغیه‌ی جدیدی نباشد سرور HTTP 500 با پیام «شما ابلاغیه جدید ... ندارید» می‌دهد؛ این خطا نیست.
  Future<({List<Json> items, String? emptyMessage})> fetchNew(DateTime start, DateTime end) => run(() async {
        final all = <Json>[];
        final seen = <dynamic>{};
        String? msg;
        final last = DateTime.utc(end.year, end.month, end.day);
        var s = DateTime.utc(start.year, start.month, start.day);
        while (!s.isAfter(last)) {
          var e = s.add(const Duration(days: 89)); // سایت پیش‌فرض را ۳ ماه می‌گذارد
          if (e.isAfter(last)) e = last;
          final (items, m) = await _fetchNewWindow(jstr(s), jstr(e));
          msg ??= m;
          for (final n in items) {
            if (seen.add(n['ObjectId'] ?? n['NoticedDocNo'])) all.add(n);
          }
          s = e.add(const Duration(days: 1));
        }
        all.sort((a, b) => '${b['WebDateTime'] ?? ''}'.compareTo('${a['WebDateTime'] ?? ''}'));
        return (items: all, emptyMessage: all.isEmpty ? msg : null);
      });

  Future<(List<Json>, String?)> _fetchNewWindow(String from, String to) async {
    const where = 'GetNewENoticeWithoutNoticeText';
    final items = <Json>[];
    var page = 1;
    int? total;
    while (true) {
      final r = await _postJson(
        '$_app/Notice/Home/$where',
        {
          'pageNumber': page,
          'pageSize': '5',
          'eNotifySearchCriteria': {'WebDateFrom': from, 'WebDateTo': to, 'LtrUnitTypeCode': '-'},
        },
        referer: _ret,
        anyStatus: true,
        quiet: true, // خطاها را خودمان با جزئیات ثبت می‌کنیم
      );
      final code = r.statusCode ?? 0;
      if (code == 302 || code == 401 || code == 403) {
        AppLog.add('warn', where, 'HTTP $code (احتمالاً نشست منقضی)', detail: _snip(r.data));
        throw SessionExpired();
      }
      Json? j;
      try {
        final x = jsonDecode(r.data ?? '');
        if (x is Map) j = Json.from(x);
      } catch (_) {}
      if (code != 200) {
        // سرور قبلاً HTTP 500 با کلید result می‌داد؛ حالا HTTP 409 با errorCode=BUSINESS_ERROR و کلید message
        final m = j?['result'] ?? j?['message'];
        if ((code == 500 || code == 409) && m is String && m.contains('ابلاغیه جدید')) {
          AppLog.add('info', where, 'HTTP $code: بدون ابلاغیه‌ی جدید  بازه $from تا $to', detail: m);
          return (items, items.isEmpty ? m : null); // «ابلاغیه‌ی جدیدی ندارید»
        }
        AppLog.add('error', where, 'HTTP $code  بازه $from تا $to', detail: _snip(r.data));
        throw Exception('خطای سرور (HTTP $code)${m is String ? ': $m' : ''}');
      }
      if (j == null) {
        AppLog.add('warn', where, 'پاسخ JSON نبود (احتمالاً نشست منقضی)', detail: _snip(r.data));
        throw SessionExpired();
      }
      var docs = j['DocumentList'] as List?;
      docs ??= j.values.whereType<List>().firstOrNull;
      if (docs == null) {
        AppLog.add('warn', where, 'ساختار ناشناخته‌ی پاسخ؛ کلیدها: ${j.keys.join(', ')}', detail: _snip(r.data));
        docs = [];
      }
      total ??= (j['TotalCount'] as num?)?.toInt();
      items.addAll(docs.whereType<Map>().map((e) => Json.from(e)));
      if (docs.isEmpty || (total != null && items.length >= total)) break;
      page++;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return (items, null);
  }
}
