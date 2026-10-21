import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'adl_api.dart';
import 'jalali.dart';
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
            title: const Text('ابلاغیه‌ها'),
            actions: [IconButton(icon: const Icon(Icons.logout), tooltip: 'خروج', onPressed: onLogout)],
            bottom: const TabBar(tabs: [Tab(text: 'اخیر'), Tab(text: 'گذشته'), Tab(text: 'ذخیره‌شده')]),
          ),
          body: TabBarView(children: [RecentTab(api), PastTab(api), SavedTab(api)]),
        ),
      );
}

// ---------- باز کردن ابلاغیه ----------
Future<void> openNotice(BuildContext context, AdlApi api, Map<String, dynamic> n) async {
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
    } catch (e) {
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
  const NoticeListView(this.items, this.api, {super.key, this.deletable = false});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return ListView(children: const [SizedBox(height: 120), Center(child: Text('ابلاغیه‌ای نیست'))]);
    return ValueListenableBuilder<int>(
      valueListenable: Store.changes,
      builder: (_, __, ___) => ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final n = items[i];
          final saved = Store.savedKeys.contains(Store.key(n));
          final unseen = '${n['FirrstViewDateTime'] ?? ''}'.isEmpty;
          return ListTile(
            isThreeLine: true,
            leading: Icon(saved ? Icons.download_done : Icons.description_outlined,
                color: saved ? Colors.green : (unseen && !deletable ? Colors.orange : null)),
            title: Text('${n['SubjectType'] ?? ''}'),
            subtitle: Text('${n['IssuerUnitName'] ?? ''}\n${n['WebDateTime'] ?? ''}  •  ${n['NoticedDocNo'] ?? ''}'),
            onTap: () => openNotice(c, api, n),
            onLongPress: !deletable
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: c,
                      builder: (d) => AlertDialog(
                        title: const Text('حذف از حافظه‌ی گوشی؟'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('خیر')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('حذف')),
                        ],
                      ),
                    );
                    if (ok == true) await Store.delete(n);
                  },
          );
        },
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
  const _Loader(this.loading, this.error, this.items, this.api, this.onRefresh);

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRefresh, child: const Text('تلاش دوباره')),
          ]),
        ),
      );
    }
    return RefreshIndicator(onRefresh: onRefresh, child: NoticeListView(items ?? [], api));
  }
}

// ---------- تب ۱: ابلاغیه‌های این ماه ----------
class RecentTab extends StatefulWidget {
  final AdlApi api;
  const RecentTab(this.api, {super.key});
  @override
  State<RecentTab> createState() => _RecentTabState();
}

class _RecentTabState extends State<RecentTab> with AutomaticKeepAliveClientMixin {
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final now = DateTime.now();
      _items = await widget.api.fetchRange(jalaliMonthStart(now), now);
    } catch (e) {
      _err = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _Loader(_loading, _err, _items, widget.api, _load);
  }
}

// ---------- تب ۲: بازه‌ی دلخواه ----------
class PastTab extends StatefulWidget {
  final AdlApi api;
  const PastTab(this.api, {super.key});
  @override
  State<PastTab> createState() => _PastTabState();
}

class _PastTabState extends State<PastTab> with AutomaticKeepAliveClientMixin {
  DateTimeRange? _range;
  bool _loading = false;
  String? _err;
  List<Map<String, dynamic>>? _items;
  @override
  bool get wantKeepAlive => true;

  Future<void> _pick() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2018),
      lastDate: now,
      initialDateRange: _range ?? DateTimeRange(start: now.subtract(const Duration(days: 60)), end: now),
      helpText: 'انتخاب بازه',
    );
    if (r == null) return;
    _range = r;
    await _load();
  }

  Future<void> _load() async {
    if (_range == null) return;
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _items = await widget.api.fetchRange(_range!.start, _range!.end);
    } catch (e) {
      _err = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.date_range),
            label: Text(_range == null ? 'انتخاب بازه‌ی تاریخ' : '${jstr(_range!.start)}  تا  ${jstr(_range!.end)}'),
            onPressed: _loading ? null : _pick,
          ),
        ),
      ),
      Expanded(
        child: _range == null
            ? const Center(child: Text('یک بازه انتخاب کنید'))
            : _Loader(_loading, _err, _items, widget.api, _load),
      ),
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
