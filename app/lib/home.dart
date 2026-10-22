import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'adl_api.dart';
import 'app_log.dart';
import 'log_page.dart';
import 'jalali.dart';
import 'jalali_picker.dart';
import 'notice_page.dart';
import 'store.dart';
import 'web_open.dart';

class HomePage extends StatelessWidget {
  final AdlApi api;
  final VoidCallback onLogout;
  const HomePage({super.key, required this.api, required this.onLogout});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 72,
            title: const Text('ابلاغیه‌ها', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            actions: [
              IconButton(iconSize: 36, icon: const Icon(Icons.logout), tooltip: 'خروج', onPressed: onLogout),
              if (kEnableLog)
                PopupMenuButton<String>(
                  iconSize: 34,
                  tooltip: 'بیشتر',
                  onSelected: (v) {
                    if (v == 'log') Navigator.push(context, MaterialPageRoute(builder: (_) => const LogPage()));
                  },
                  itemBuilder: (_) {
                    final errs = AppLog.entries.value.where((e) => e.level == 'error').length;
                    return [
                      PopupMenuItem(
                        value: 'log',
                        child: Row(children: [
                          const Icon(Icons.bug_report_rounded),
                          const SizedBox(width: 10),
                          Text(errs > 0 ? 'گزارش خطاها (لاگ) — $errs خطا' : 'گزارش خطاها (لاگ)'),
                        ]),
                      ),
                    ];
                  },
                ),
              const SizedBox(width: 4),
            ],
            bottom: const TabBar(
              labelStyle: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
              unselectedLabelStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              indicatorWeight: 5,
              tabs: [
                Tab(height: 60, text: 'جدید'),
                Tab(height: 60, text: 'مشاهده‌شده'),
                Tab(height: 60, text: 'ذخیره‌شده'),
              ],
            ),
          ),
          body: TabBarView(children: [NewTab(api), ViewedTab(api), SavedTab(api)]),
        ),
      );
}

// ---------- باز کردن ابلاغیه ----------
Future<void> openNotice(BuildContext context, AdlApi api, Map<String, dynamic> n) async {
  if (kIsWeb) return _openNoticeWeb(context, api, n); // نسخه‌ی وب مثل قبل
  final saved = await Store.savedDir(n) != null;
  if (!saved && '${n['FirrstViewDateTime'] ?? ''}'.isEmpty) {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ابلاغیه‌ی مشاهده‌نشده', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        content: const Text(
          'باز کردن این ابلاغیه در سامانه «مشاهده» ثبت می‌شود و ممکن است تاریخ ابلاغ قانونی را تثبیت کند. ادامه می‌دهید؟',
          style: TextStyle(fontSize: 20, height: 1.6),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(100, 56)),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('انصراف', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 56)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('ادامه', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => NoticePage(api: api, notice: n)));
}

Future<void> _openNoticeWeb(BuildContext context, AdlApi api, Map<String, dynamic> n) async {
  var dir = await Store.savedDir(n);
  final alreadySaved = kIsWeb ? Store.savedKeys.contains(Store.key(n)) : dir != null;
  if (!alreadySaved) {
    if (!context.mounted) return;
    if ('${n['FirrstViewDateTime'] ?? ''}'.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('ابلاغیه‌ی مشاهده‌نشده'),
          content: const Text('دانلود متن ابلاغیه در سامانه «مشاهده» ثبت می‌کند و ممکن است تاریخ ابلاغ قانونی را تثبیت کند. ادامه می‌دهید؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ادامه')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!context.mounted) return;
    final status = ValueNotifier('در حال دریافت...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: ValueListenableBuilder<String>(valueListenable: status, builder: (_, v, __) => Text(v))),
          ]),
        ),
      ),
    );
    try {
      dir = await api.downloadAndSave(n, (s) => status.value = s);
    } catch (e, st) {
      AppLog.error('دانلود و ذخیره‌ی ابلاغیه ${n['NoticedDocNo']}', e, st: st);
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (context.mounted) Navigator.pop(context);
  }
  if (!context.mounted) return;
  if (kIsWeb) {
    final wf = Store.webFiles(n) ?? {};
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final e in wf.entries)
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(e.key == 'abelaghie.pdf' ? 'متن ابلاغیه' : e.key),
              onTap: () => openBytesWeb(e.key, e.value),
            ),
        ]),
      ),
    );
    return;
  }
  final files = Store.files(dir!);
  if (files.length == 1) {
    await OpenFilex.open(files.first.path);
    return;
  }
  showModalBottomSheet(
    context: context,
    builder: (_) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final f in files)
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(f.path.endsWith('abelaghie.pdf') ? 'متن ابلاغیه' : f.path.split(Platform.pathSeparator).last),
            onTap: () => OpenFilex.open(f.path),
          ),
      ]),
    ),
  );
}

// ---------- لیست مشترک ----------
class NoticeListView extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final AdlApi api;
  final bool deletable;
  final VoidCallback? onChanged; // بعد از برگشت از صفحه‌ی ابلاغیه
  const NoticeListView(this.items, this.api, {super.key, this.deletable = false, this.onChanged});

  Future<void> _confirmDelete(BuildContext c, Map<String, dynamic> n) async {
    final ok = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('حذف از حافظه‌ی گوشی؟', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(100, 56)),
            onPressed: () => Navigator.pop(d, false),
            child: const Text('خیر', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 56), backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('حذف', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok == true) await Store.delete(n);
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 120),
        Center(child: Text('ابلاغیه‌ای نیست', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
      ]);
    }
    return ValueListenableBuilder<int>(
      valueListenable: Store.changes,
      builder: (_, __, ___) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        itemBuilder: (c, i) {
          final n = items[i];
          return NoticeCard(
            n: n,
            saved: Store.savedKeys.contains(Store.key(n)),
            unseen: '${n['FirrstViewDateTime'] ?? ''}'.isEmpty && !deletable,
            onTap: () async {
              await openNotice(c, api, n);
              onChanged?.call();
            },
            onDelete: deletable ? () => _confirmDelete(c, n) : null,
          );
        },
      ),
    );
  }
}

/// «۱۴۰۵/۰۷/۲۹-۱۷:۵۰» ← (تاریخ، ساعت)
(String, String) _splitDt(String s) {
  final m = RegExp(r'(\d{4}/\d{1,2}/\d{1,2})\D+(\d{1,2}:\d{2}(?::\d{2})?)').firstMatch(s);
  return m != null ? (m.group(1)!, m.group(2)!) : (s, '');
}

class NoticeCard extends StatelessWidget {
  final Map<String, dynamic> n;
  final bool saved, unseen;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  const NoticeCard({super.key, required this.n, required this.saved, required this.unseen, required this.onTap, this.onDelete});

  Widget _box(MaterialColor c, Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: c.shade50,
          border: Border.all(color: c.shade700, width: 3),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final (date, time) = _splitDt('${n['WebDateTime'] ?? ''}');
    final iconColor = saved ? Colors.green.shade700 : (unseen ? Colors.orange.shade800 : Colors.indigo.shade700);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(saved ? Icons.download_done_rounded : Icons.description_rounded, size: 40, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${n['SubjectType'] ?? ''}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 1.5)),
              ),
              if (onDelete != null)
                IconButton(
                  iconSize: 36,
                  color: Colors.red.shade700,
                  icon: const Icon(Icons.delete_rounded),
                  tooltip: 'حذف',
                  onPressed: onDelete,
                ),
            ]),
            const SizedBox(height: 6),
            Text('${n['IssuerUnitName'] ?? ''}',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.grey.shade800, height: 1.5)),
            if (unseen)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('● مشاهده‌نشده',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.orange.shade900)),
              ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // ۱) کادر نارنجی: شماره ابلاغیه
                Expanded(
                  flex: 5,
                  child: _box(
                    Colors.deepOrange,
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('${n['NoticedDocNo'] ?? ''}',
                          textDirection: TextDirection.ltr,
                          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.deepOrange.shade900)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // ۲) کادر آبی: تاریخ (خط اول) و ساعت (خط دوم)
                Expanded(
                  flex: 3,
                  child: _box(
                    Colors.blue,
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(date,
                            textDirection: TextDirection.ltr,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.blue.shade900)),
                        if (time.isNotEmpty)
                          Text(time,
                              textDirection: TextDirection.ltr,
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.blue.shade900)),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// بدنه‌ی مشترک: بارگذاری + خطا + کشیدن برای تازه‌سازی
class _Loader extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>>? items;
  final AdlApi api;
  final Future<void> Function() onRefresh;
  final VoidCallback? onChanged;
  const _Loader(this.loading, this.error, this.items, this.api, this.onRefresh, {this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, height: 1.6)),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(200, 60)),
              onPressed: onRefresh,
              child: const Text('تلاش دوباره', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      );
    }
    return RefreshIndicator(onRefresh: onRefresh, child: NoticeListView(items ?? [], api, onChanged: onChanged));
  }
}

// ---------- دکمه‌ی بازه‌ی تاریخ (مشترک) ----------
Widget _rangeButton(BuildContext context, DateTimeRange? r, bool disabled, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 64), side: const BorderSide(width: 3)),
          icon: const Icon(Icons.date_range, size: 32),
          label: Text(r == null ? 'انتخاب بازه‌ی تاریخ' : '${jstr(r.start)}  تا  ${jstr(r.end)}',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          onPressed: disabled ? null : onTap,
        ),
      ),
    );

Future<DateTimeRange?> _pickRange(BuildContext context, DateTimeRange initial) =>
    showJalaliRangePicker(context, initial: initial);

// ---------- تب ۱: ابلاغیه‌های جدید (مشاهده‌نشده) ----------
class NewTab extends StatefulWidget {
  final AdlApi api;
  const NewTab(this.api, {super.key});
  @override
  State<NewTab> createState() => _NewTabState();
}

class _NewTabState extends State<NewTab> with AutomaticKeepAliveClientMixin {
  // مثل سایت: پیش‌فرض ۳ ماه اخیر
  late DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 89)),
    end: DateTime.now(),
  );
  bool _loading = true;
  String? _err, _emptyMsg;
  List<Map<String, dynamic>>? _items;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
      _emptyMsg = null;
    });
    try {
      final r = await widget.api.fetchNew(_range.start, _range.end);
      _items = r.items;
      _emptyMsg = r.emptyMessage;
    } catch (e, st) {
      _err = '$e';
      AppLog.error('بارگذاری ابلاغیه‌های جدید', e, st: st, detail: 'بازه ${jstr(_range.start)} تا ${jstr(_range.end)}');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// مثل دکمه‌های «سه ماه قبل/بعد» سایت: کل بازه ۹۰ روز جابه‌جا می‌شود
  void _shift(int days) {
    final now = DateTime.now();
    var s = _range.start.add(Duration(days: days));
    var e = _range.end.add(Duration(days: days));
    if (e.isAfter(now)) {
      final over = e.difference(now);
      e = now;
      s = s.subtract(over);
    }
    _range = DateTimeRange(start: s, end: e);
    _load();
  }

  Future<void> _pick() async {
    final r = await _pickRange(context, _range);
    if (r == null) return;
    _range = r;
    await _load();
  }

  Widget _shiftButton(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 58)),
          icon: Icon(icon, size: 28),
          label: Text(label, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          onPressed: _loading ? null : onTap,
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final empty = !_loading && _err == null && (_items?.isEmpty ?? true);
    return Column(children: [
      _rangeButton(context, _range, _loading, _pick),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Row(children: [
          _shiftButton(Icons.arrow_back, 'سه ماه قبل', () => _shift(-90)),
          const SizedBox(width: 10),
          _shiftButton(Icons.arrow_forward, 'سه ماه بعد', () => _shift(90)),
        ]),
      ),
      Expanded(
        child: empty
            ? RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  const SizedBox(height: 24),
                  Icon(Icons.mark_email_read_rounded, size: 80, color: Colors.green.shade700),
                  const SizedBox(height: 16),
                  Text(
                    _emptyMsg ?? 'شما ابلاغیه جدید (مشاهده نشده) در این بازه زمانی ندارید.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, height: 1.7),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 64)),
                    icon: const Icon(Icons.visibility_rounded, size: 30),
                    label: const Text('رفتن به مشاهده‌شده‌ها',
                        style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                    onPressed: () => DefaultTabController.of(context).animateTo(1),
                  ),
                ]),
              )
            : _Loader(_loading, _err, _items, widget.api, _load, onChanged: _load),
      ),
    ]);
  }
}

// ---------- تب ۲: ابلاغیه‌های مشاهده‌شده ----------
class ViewedTab extends StatefulWidget {
  final AdlApi api;
  const ViewedTab(this.api, {super.key});
  @override
  State<ViewedTab> createState() => _ViewedTabState();
}

class _ViewedTabState extends State<ViewedTab> with AutomaticKeepAliveClientMixin {
  // پیش‌فرض: از اول ماه شمسی تا امروز
  late DateTimeRange _range = DateTimeRange(start: jalaliMonthStart(DateTime.now()), end: DateTime.now());
  bool _loading = true;
  String? _err;
  List<Map<String, dynamic>>? _items;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _pick() async {
    final r = await _pickRange(context, _range);
    if (r == null) return;
    _range = r;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _items = await widget.api.fetchRange(_range.start, _range.end);
    } catch (e, st) {
      _err = '$e';
      AppLog.error('بارگذاری ابلاغیه‌های مشاهده‌شده', e, st: st, detail: 'بازه ${jstr(_range.start)} تا ${jstr(_range.end)}');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      _rangeButton(context, _range, _loading, _pick),
      Expanded(child: _Loader(_loading, _err, _items, widget.api, _load)),
    ]);
  }
}

// ---------- تب ۳: ذخیره‌شده (آفلاین) ----------
class SavedTab extends StatelessWidget {
  final AdlApi api;
  const SavedTab(this.api, {super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Store.changes,
        builder: (_, __, ___) => FutureBuilder<List<Map<String, dynamic>>>(
          future: Store.savedList(),
          builder: (c, s) => s.hasData
              ? NoticeListView(s.data!, api, deletable: true)
              : const Center(child: CircularProgressIndicator()),
        ),
      );
}
