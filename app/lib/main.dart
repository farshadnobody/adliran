import 'package:flutter/material.dart';
import 'adl_api.dart';
import 'home.dart';
import 'store.dart';

final api = AdlApi();

void main() => runApp(const App());

String errText(Object e) => e is LoginRejected || e is SiteUnavailable ? '$e' : 'خطا: $e';

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

/// اگر اعتبارنامه ذخیره باشد خودکار وارد می‌شود، وگرنه صفحه‌ی لاگین
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  Widget? _page;
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Store.loadKeys();
    final c = await Store.creds();
    if (c == null) return _set(const LoginPage());
    try {
      await api.signIn();
      _set(HomePage(api: api, onLogout: _logout));
    } catch (e) {
      _set(LoginPage(initialNc: c['nc'], error: errText(e)));
    }
  }

  void _set(Widget w) {
    if (mounted) setState(() => _page = w);
  }

  Future<void> _logout() async {
    await Store.clearCreds();
    _set(const LoginPage());
  }

  @override
  Widget build(BuildContext context) {
    if (_page == null) {
      return const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('در حال ورود...'),
          ]),
        ),
      );
    }
    return _page is LoginPage ? LoginPage(initialNc: (_page as LoginPage).initialNc, error: (_page as LoginPage).error, onDone: () => _set(HomePage(api: api, onLogout: _logout))) : _page!;
  }
}

class LoginPage extends StatefulWidget {
  final String? initialNc, error;
  final VoidCallback? onDone;
  const LoginPage({super.key, this.initialNc, this.error, this.onDone});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _nc = TextEditingController(text: widget.initialNc);
  final _pw = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _err = widget.error;
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
    });
    try {
      await api.signIn(nationalCode: nc, password: pw);
      widget.onDone?.call();
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
                  const Icon(Icons.gavel, size: 64),
                  const SizedBox(height: 8),
                  Text('ابلاغیه‌های قضایی', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nc,
                    keyboardType: TextInputType.number,
                    maxLength: 10,
                    decoration: const InputDecoration(labelText: 'نام کاربری (کد ملی)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pw,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(labelText: 'رمز عبور', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const Text('در حال ارسال پیامک و ورود (تا ۴۰ ثانیه)...')
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
