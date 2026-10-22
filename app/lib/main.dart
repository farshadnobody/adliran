import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'adl_api.dart';
import 'app_log.dart';
import 'home.dart';
import 'store.dart';

final api = AdlApi();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.init();
  // خطاهای پیش‌بینی‌نشده‌ی برنامه هم در لاگ ثبت شوند
  FlutterError.onError = (d) {
    AppLog.error('Flutter', d.exception, st: d.stack);
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.error('خطای اجرا', e, st: st);
    debugPrint('$e\n$st');
    return true;
  };
  runApp(const App());
}

String errText(Object e) =>
    e is LoginRejected || e is SiteUnavailable || e is NeedSmsCode ? '$e' : 'خطا: $e';

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ابلاغیه‌ها',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const Gate(),
      );
}

enum _S { loading, login, code, home }

/// اگر اعتبارنامه ذخیره باشد خودکار وارد می‌شود، وگرنه صفحه‌ی لاگین
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  _S _s = _S.loading;
  String? _nc, _err;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  void _go(_S s, {String? nc, String? err}) {
    if (mounted) {
      setState(() {
        _s = s;
        _nc = nc;
        _err = err;
      });
    }
  }

  Future<void> _boot() async {
    Map<String, String>? c;
    try {
      await Store.loadMode();
      await Store.loadKeys();
      c = await Store.creds();
    } catch (e, st) {
      AppLog.error('راه‌اندازی (خواندن اعتبارنامه)', e, st: st);
    }
    if (c == null) return _go(_S.login);
    try {
      await api.signIn();
      _go(_S.home);
    } on NeedSmsCode catch (e) {
      AppLog.add('info', 'ورود', 'نیاز به کد پیامک: ${e.message}');
      _go(_S.code, nc: c['nc'], err: e.message);
    } catch (e) {
      _go(_S.login, nc: c['nc'], err: errText(e));
    }
  }

  Future<void> _logout() async {
    await Store.clearCreds();
    _go(_S.login);
  }

  @override
  Widget build(BuildContext context) {
    switch (_s) {
      case _S.loading:
        return const Scaffold(
          body: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('در حال ورود...'),
            ]),
          ),
        );
      case _S.login:
        return LoginPage(initialNc: _nc, error: _err, onDone: () => _go(_S.home));
      case _S.code:
        return CodePage(nc: _nc ?? '', message: _err, onDone: () => _go(_S.home), onCancel: _logout);
      case _S.home:
        return HomePage(api: api, onLogout: _logout);
    }
  }
}

class LoginPage extends StatefulWidget {
  final String? initialNc, error;
  final VoidCallback onDone;
  const LoginPage({super.key, this.initialNc, this.error, required this.onDone});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _nc = TextEditingController(text: widget.initialNc);
  final _pw = TextEditingController();
  bool _busy = false;
  late bool _manual = Store.manual;
  String? _err;
  bool _credErr = false; // کد ملی/رمز اشتباه
  bool _showPw = false;

  @override
  void initState() {
    super.initState();
    _err = widget.error;
    _credErr = (widget.error ?? '').startsWith('کد ملی یا رمز');
  }

  Future<void> _submit() async {
    final nc = _nc.text.trim(), pw = _pw.text;
    if (!RegExp(r'^\d{10}$').hasMatch(nc) || pw.isEmpty) {
      setState(() => _err = 'کد ملی ۱۰ رقمی و رمز را وارد کنید');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
      _credErr = false;
    });
    try {
      await api.signIn(nationalCode: nc, password: pw);
      widget.onDone();
    } on NeedSmsCode catch (e) {
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) => CodePage(
              nc: nc,
              message: e.message,
              onDone: () {
                Navigator.pop(ctx);
                widget.onDone();
              },
              onCancel: () => Navigator.pop(ctx),
            ),
          ),
        );
      }
    } on WrongCredentials catch (e) {
      if (mounted) {
        setState(() {
          _err = e.message;
          _credErr = true;
          _pw.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (!kIsWeb) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, icon: Icon(Icons.bolt), label: Text('خودکار')),
                      ButtonSegment(value: true, icon: Icon(Icons.edit), label: Text('دستی')),
                    ],
                    selected: {_manual},
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: Colors.green,
                      selectedForegroundColor: Colors.white,
                    ),
                    onSelectionChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _manual = v.first);
                            Store.setManual(v.first);
                          },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _manual ? 'پیامک را خودتان می‌فرستید و کد را وارد می‌کنید' : 'پیامک توسط خود اپ ارسال می‌شود',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  ],
                  const SizedBox(height: 24),
                  const Icon(Icons.gavel, size: 64),
                  const SizedBox(height: 8),
                  Text('ابلاغیه‌های قضایی', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nc,
                    keyboardType: TextInputType.number,
                    maxLength: 10,
                    onChanged: (_) {
                      if (_credErr) setState(() => _credErr = false);
                    },
                    decoration: InputDecoration(
                      labelText: 'نام کاربری (کد ملی)',
                      border: const OutlineInputBorder(),
                      errorText: _credErr ? '' : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pw,
                    obscureText: !_showPw,
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_credErr) setState(() => _credErr = false);
                    },
                    decoration: InputDecoration(
                      labelText: 'رمز عبور',
                      border: const OutlineInputBorder(),
                      errorText: _credErr ? '' : null,
                      suffixIcon: IconButton(
                        icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPw = !_showPw),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_err != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(_credErr ? Icons.lock_outline : Icons.error_outline,
                            color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_err!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                                  fontWeight: _credErr ? FontWeight.bold : FontWeight.normal,
                                  fontSize: _credErr ? 17 : null)),
                        ),
                      ]),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? Text(_manual ? 'در حال ورود...' : 'در حال ارسال پیامک و ورود (تا ۴۰ ثانیه)...')
                          : const Text('ورود'),
                    ),
                  ),
                  if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// صفحه‌ی ورود کد پیامک (حالت دستی)
class CodePage extends StatefulWidget {
  final String nc;
  final String? message;
  final VoidCallback onDone, onCancel;
  const CodePage({super.key, required this.nc, this.message, required this.onDone, required this.onCancel});
  @override
  State<CodePage> createState() => _CodePageState();
}

class _CodePageState extends State<CodePage> {
  final _code = TextEditingController();
  bool _busy = false;
  late String? _err = widget.message;

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _err = 'کد را وارد کنید');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await api.signIn(manualCode: code);
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('کد پیامک'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onCancel),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('کدی را که عدل‌ایران به گوشی شما پیامک کرده اینجا وارد کنید:'),
                const SizedBox(height: 8),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: 'کد پیامک', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                if (_err != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'در حال ورود...' : 'ورود')),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
