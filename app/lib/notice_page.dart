import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdfx/pdfx.dart';

import 'adl_api.dart';
import 'app_log.dart';
import 'store.dart';

const _green = Color(0xFF2E7D32);
const _imgExt = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

bool _isPdf(Uint8List b) => b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46;

bool _looksImage(Uint8List b) =>
    b.length > 4 &&
    ((b[0] == 0xFF && b[1] == 0xD8) || // jpeg
        (b[0] == 0x89 && b[1] == 0x50) || // png
        (b[0] == 0x47 && b[1] == 0x49) || // gif
        (b[0] == 0x52 && b[1] == 0x49)); // RIFF/webp

String _base(File f) => f.path.split(Platform.pathSeparator).last;

/// تبدیل به webp؛ اگر دستگاه پشتیبانی نکند همان PNG/JPEG می‌ماند
Future<(Uint8List, String)> _toWebp(Uint8List src, String fallbackExt) async {
  try {
    final out = await FlutterImageCompress.compressWithList(
      src,
      minWidth: 3000,
      minHeight: 3000,
      quality: 90,
      format: CompressFormat.webp,
    );
    if (out.isNotEmpty) return (out, 'webp');
    AppLog.add('warn', 'تبدیل به webp', 'خروجی خالی بود؛ فرمت اصلی نگه داشته شد');
  } catch (e, st) {
    AppLog.error('تبدیل به webp', e, st: st);
  }
  return (src, fallbackExt);
}

class _Part {
  final String id, title;
  final int index; // ‎-1‎ = متن ابلاغیه
  List<File> pages = [];
  File? raw; // فایل غیرقابل تبدیل به تصویر (مثلاً html)
  File? legacy; // فایل خام ذخیره‌شده با نسخه‌ی قبلی اپ
  bool busy = false;
  double progress = 0;
  String status = '';
  String? error;
  _Part(this.id, this.title, this.index);
}

class NoticePage extends StatefulWidget {
  final AdlApi api;
  final Map<String, dynamic> notice;
  const NoticePage({super.key, required this.api, required this.notice});
  @override
  State<NoticePage> createState() => _NoticePageState();
}

class _NoticePageState extends State<NoticePage> {
  late Map<String, dynamic> _n = widget.notice;
  List<_Part> _parts = [];
  bool _loading = true, _select = false, _saving = false;
  String? _err;
  final _sel = <String>{};
  Future<void> _queue = Future.value();

  String get _key => Store.key(_n);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = await Store.savedDir(widget.notice);
      if (d != null) {
        _n = {...widget.notice, ...await Store.readInfo(d)};
      } else {
        _n = await widget.api.openNoticeMeta(widget.notice);
      }
      final atts = (_n['AttachmentList'] as List?) ?? [];
      _parts = [
        _Part('main', 'متن ابلاغیه', -1),
        for (var i = 0; i < atts.length; i++)
          _Part('att$i', _attTitle(atts[i], i), i),
      ];
      await _scan();
      for (final p in _parts) {
        if (p.legacy != null) _enqueue(p, legacy: p.legacy); // تبدیل خودکار فایل‌های قدیمی
      }
    } catch (e, st) {
      _err = '$e';
      AppLog.error('باز کردن ابلاغیه ${widget.notice['NoticedDocNo']}', e, st: st);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _attTitle(dynamic a, int i) {
    final t = a is Map ? '${a['AttachmentTitle'] ?? ''}'.trim() : '';
    return t.isEmpty ? 'پیوست ${i + 1}' : t;
  }

  Future<void> _scan() async {
    final d = await Store.dirFor(_n);
    if (!d.existsSync()) return;
    final files = d.listSync().whereType<File>().toList();
    for (final p in _parts) {
      final pre = '${_key}_${p.id}_p';
      final pages = files.where((f) {
        final b = _base(f);
        return b.startsWith(pre) && (b.endsWith('.webp') || b.endsWith('.png') || b.endsWith('.jpg'));
      }).toList()
        ..sort((a, b) => _pageNo(a, pre).compareTo(_pageNo(b, pre)));
      p.pages = pages;
      final raws = files.where((f) => _base(f).startsWith('${_key}_${p.id}_raw'));
      p.raw = raws.isEmpty ? null : raws.first;
      p.legacy = null;
      if (p.pages.isEmpty && p.raw == null) {
        final cand = files.where((f) {
          final b = _base(f);
          if (b == 'info.json' || b.startsWith('${_key}_')) return false;
          return p.index < 0 ? b == 'abelaghie.pdf' : b.startsWith('${p.index + 1}_');
        });
        if (cand.isNotEmpty) p.legacy = cand.first;
      }
    }
  }

  int _pageNo(File f, String pre) =>
      int.tryParse(_base(f).substring(pre.length).split('.').first) ?? 0;

  // ---------- دانلود و تبدیل ----------
  void _tap(_Part p) {
    if (p.busy) return;
    if (_select) {
      if (p.pages.isEmpty) return;
      setState(() => _sel.contains(p.id) ? _sel.remove(p.id) : _sel.add(p.id));
      return;
    }
    if (p.pages.isNotEmpty) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => NoticeViewer(title: p.title, files: p.pages)));
      return;
    }
    if (p.raw != null) {
      OpenFilex.open(p.raw!.path);
      return;
    }
    _enqueue(p, legacy: p.legacy);
  }

  void _enqueue(_Part p, {File? legacy}) {
    setState(() {
      p.busy = true;
      p.error = null;
      p.progress = 0;
      p.status = 'در صف...';
    });
    _queue = _queue.then((_) => _work(p, legacy)); // دانلودها پشت‌سرهم (فشار کمتر روی سرور)
  }

  Future<void> _work(_Part p, File? legacy) async {
    if (!mounted) return;
    final stale = p.legacy; // فایل خام نسخه‌ی قبلی (در دریافت مجدد حذف می‌شود)
    final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted && p.progress < 0.85) setState(() => p.progress += (0.85 - p.progress) * 0.03);
    });
    try {
      setState(() => p.status = legacy != null ? 'آماده‌سازی...' : 'در حال دانلود...');
      Uint8List bytes;
      String ext;
      if (legacy != null) {
        bytes = await legacy.readAsBytes();
        ext = legacy.path.split('.').last;
      } else {
        final r = await widget.api.downloadPart(_n, p.index, (s) {
          if (mounted) setState(() => p.status = s);
        });
        bytes = Uint8List.fromList(r.bytes);
        ext = r.ext;
      }
      timer.cancel();
      if (mounted) {
        setState(() {
          p.progress = 0.88;
          p.status = 'تبدیل به تصویر...';
        });
      }
      final dir = await Store.noticeDir(_n);
      await _convertAndStore(p, dir, bytes, ext);
      final old = legacy ?? stale;
      if (old != null) {
        try {
          old.deleteSync();
        } catch (e) {
          AppLog.add('warn', 'حذف فایل قدیمی', '$e');
        }
      }
      await Store.writeInfo(_n);
      await _scan();
      if (mounted) {
        setState(() {
          p.progress = 1;
          p.status = 'انجام شد';
        });
      }
      await Future.delayed(const Duration(milliseconds: 400));
    } catch (e, st) {
      p.error = '$e'.replaceFirst('Exception: ', '');
      AppLog.error('دانلود «${p.title}»', e, st: st, detail: 'ابلاغیه ${_n['NoticedDocNo']}  /  ${p.id}');
    } finally {
      timer.cancel();
      if (mounted) setState(() => p.busy = false);
    }
  }

  Future<void> _convertAndStore(_Part p, Directory dir, Uint8List bytes, String ext) async {
    final pre = '${_key}_${p.id}';
    for (final f in dir.listSync().whereType<File>()) {
      final b = _base(f);
      if (b.startsWith('${pre}_p') || b.startsWith('${pre}_raw')) f.deleteSync();
    }
    final e = ext.toLowerCase();
    if (e == 'pdf' || _isPdf(bytes)) {
      final doc = await PdfDocument.openData(bytes);
      try {
        final total = doc.pagesCount;
        for (var i = 1; i <= total; i++) {
          final page = await doc.getPage(i);
          Uint8List? png;
          try {
            const w = 1600.0;
            final img = await page.render(
              width: w,
              height: page.height * w / page.width,
              format: PdfPageImageFormat.png,
              backgroundColor: '#FFFFFF',
            );
            png = img?.bytes;
          } finally {
            await page.close();
          }
          if (png == null) throw Exception('نمایش صفحه‌ی $i ممکن نشد');
          final (out, oext) = await _toWebp(png, 'png');
          await File('${dir.path}/${pre}_p$i.$oext').writeAsBytes(out);
          if (mounted) setState(() => p.progress = 0.88 + 0.11 * i / total);
        }
      } finally {
        await doc.close();
      }
    } else if (_imgExt.contains(e) || _looksImage(bytes)) {
      final (out, oext) = await _toWebp(bytes, e == 'png' ? 'png' : 'jpg');
      await File('${dir.path}/${pre}_p1.$oext').writeAsBytes(out);
    } else {
      await File('${dir.path}/${pre}_raw.$e').writeAsBytes(bytes);
    }
  }

  // ---------- دریافت مجدد همه‌ی اطلاعات ----------
  Future<void> _redownloadAll() async {
    if (_parts.any((p) => p.busy)) {
      _snack('تا پایان دانلودهای در حال انجام صبر کنید');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('دریافت مجدد', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        content: const Text(
          'اطلاعات ابلاغیه، متن آن و همه‌ی پیوست‌ها دوباره از سامانه دریافت می‌شود و جای فایل‌های فعلی را می‌گیرد. ادامه می‌دهید؟',
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
            child: const Text('دریافت', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _loading = true;
      _err = null;
      _select = false;
      _sel.clear();
    });
    try {
      final fresh = await widget.api.openNoticeMeta(widget.notice); // اطلاعات تازه + فهرست پیوست‌ها
      final freshAtts = fresh['AttachmentList'] as List?;
      _n = {
        ..._n,
        ...fresh,
        // اگر سرور فهرست پیوست را نداد، فهرست قبلی را نگه می‌داریم
        if (freshAtts == null || freshAtts.isEmpty) 'AttachmentList': _n['AttachmentList'],
      };
      final atts = (_n['AttachmentList'] as List?) ?? [];
      _parts = [
        _Part('main', 'متن ابلاغیه', -1),
        for (var i = 0; i < atts.length; i++) _Part('att$i', _attTitle(atts[i], i), i),
      ];
      await _scan();
      for (final p in _parts) {
        _enqueue(p); // بدون legacy ← همیشه دانلود تازه
      }
    } catch (e, st) {
      _err = '$e';
      AppLog.error('دریافت مجدد ابلاغیه ${widget.notice['NoticedDocNo']}', e, st: st);
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---------- ذخیره در گالری ----------
  Future<void> _saveGallery() async {
    final files = [
      for (final p in _parts)
        if (_sel.contains(p.id)) ...p.pages
    ];
    if (files.isEmpty) return;
    setState(() => _saving = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) {
        throw Exception('مجوز دسترسی به گالری داده نشد');
      }
      for (final f in files) {
        var path = f.path;
        if (Platform.isIOS && f.path.endsWith('.webp')) {
          // گالری آیفون webp را نمی‌پذیرد
          final tmp = '${Directory.systemTemp.path}/${_base(f)}.jpg';
          final out = await FlutterImageCompress.compressWithFile(f.path, quality: 92, format: CompressFormat.jpeg);
          if (out != null) {
            await File(tmp).writeAsBytes(out);
            path = tmp;
          }
        }
        await Gal.putImage(path, album: 'Eblaghiye');
      }
      if (mounted) {
        _snack('${files.length} تصویر در گالری ذخیره شد ✓', ok: true);
        setState(() {
          _select = false;
          _sel.clear();
        });
      }
    } catch (e, st) {
      AppLog.error('ذخیره در گالری', e, st: st);
      if (mounted) _snack('ذخیره نشد: ${'$e'.replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String t, {bool ok = false}) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: ok ? _green : Colors.red.shade800,
        duration: const Duration(seconds: 4),
        content: Text(t, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
      ));

  // ---------- رابط کاربری ----------
  @override
  Widget build(BuildContext context) {
    final downloaded = _parts.where((p) => p.pages.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        titleSpacing: 0,
        leading: IconButton(
          iconSize: 36,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('فایل‌ها', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        actions: [
          if (!_loading && _err == null)
            IconButton.filledTonal(
              iconSize: 34,
              tooltip: 'دریافت مجدد همه‌ی اطلاعات',
              icon: const Icon(Icons.sync_rounded),
              onPressed: _parts.any((p) => p.busy) ? null : _redownloadAll,
            ),
          if (!_loading && _err == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                icon: Icon(_select ? Icons.close : Icons.save_alt_rounded, size: 28),
                label: Text(_select ? 'انصراف' : 'ذخیره در گالری',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                onPressed: () => setState(() {
                  _select = !_select;
                  _sel.clear();
                  if (_select && downloaded.isEmpty) {
                    _select = false;
                    _snack('ابتدا روی کادرها بزنید تا دانلود شوند');
                  }
                }),
              ),
            ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _select
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 68), side: const BorderSide(width: 3)),
                      onPressed: () => setState(() {
                        _sel
                          ..clear()
                          ..addAll(downloaded.map((p) => p.id));
                      }),
                      child: const Text('همه', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 68), backgroundColor: _green),
                      icon: _saving
                          ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 4))
                          : const Icon(Icons.save_alt_rounded, size: 34),
                      label: Text(_sel.isEmpty ? 'ذخیره در گالری' : 'ذخیره در گالری (${_sel.length})',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      onPressed: (_sel.isEmpty || _saving) ? null : _saveGallery,
                    ),
                  ),
                ]),
              ),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 7)),
          SizedBox(height: 20),
          Text('در حال دریافت اطلاعات ابلاغیه...', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ]),
      );
    }
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_err!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(220, 64)),
              icon: const Icon(Icons.refresh, size: 32),
              label: const Text('تلاش دوباره', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              onPressed: _init,
            ),
          ]),
        ),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_n['SubjectType'] ?? ''}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.5)),
          const SizedBox(height: 6),
          Text(
            _select ? 'کادرهای دلخواه را انتخاب کنید' : 'روی هر کادر بزنید تا دانلود شود',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Colors.indigo.shade700),
          ),
        ]),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.72,
          ),
          itemCount: _parts.length,
          itemBuilder: (_, i) => _tile(_parts[i]),
        ),
      ),
    ]);
  }

  Widget _tile(_Part p) {
    final done = p.pages.isNotEmpty;
    final sel = _sel.contains(p.id);
    final Widget content;
    if (p.busy) {
      content = _busyTile(p);
    } else if (done) {
      content = _doneTile(p);
    } else if (p.raw != null) {
      content = _iconTile(Icons.insert_drive_file_rounded, p.title, 'برای باز کردن لمس کنید');
    } else {
      content = _iconTile(
        p.error != null ? Icons.refresh_rounded : Icons.download_for_offline_rounded,
        p.title,
        p.error ?? 'برای دانلود لمس کنید',
        error: p.error != null,
      );
    }
    final borderColor = sel ? _green : (p.error != null ? Colors.red.shade700 : Colors.grey.shade700);
    return Opacity(
      opacity: (_select && !done) ? 0.4 : 1,
      child: Stack(children: [
        Positioned.fill(
          child: Material(
            color: Colors.white,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: borderColor, width: sel ? 6 : 3),
            ),
            child: InkWell(onTap: () => _tap(p), child: content),
          ),
        ),
        if (_select && done)
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 48, color: sel ? _green : Colors.grey.shade700),
            ),
          ),
      ]),
    );
  }

  Widget _iconTile(IconData icon, String title, String hint, {bool error = false}) {
    final c = error ? Colors.red.shade800 : Colors.indigo.shade800;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 72, color: c),
        const SizedBox(height: 10),
        Text(title, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, height: 1.4)),
        const SizedBox(height: 8),
        Text(hint, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c, height: 1.4)),
      ]),
    );
  }

  /// کادر در حال دانلود: از بالا به پایین سبز می‌شود
  Widget _busyTile(_Part p) {
    final pr = p.progress.clamp(0.0, 1.0);
    final fg = pr > 0.5 ? Colors.white : Colors.black87;
    return Stack(fit: StackFit.expand, children: [
      Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          widthFactor: 1,
          heightFactor: pr,
          child: const ColoredBox(color: _green),
        ),
      ),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${(pr * 100).round()}%', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: fg)),
            const SizedBox(height: 8),
            Text(p.status, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: fg, height: 1.4)),
          ]),
        ),
      ),
    ]);
  }

  /// کادر دانلودشده: تصویر webp جای کادر را می‌گیرد
  Widget _doneTile(_Part p) => Stack(fit: StackFit.expand, children: [
        Image.file(
          p.pages.first,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          cacheWidth: 700,
          errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, size: 64)),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(p.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
          ),
        ),
        if (p.pages.length > 1)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.indigo.shade800, borderRadius: BorderRadius.circular(20)),
              child: Text('${p.pages.length} صفحه',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
      ]);
}

// ---------------------------------------------------------------------------
// نمایش تصویر با زوم
// ---------------------------------------------------------------------------
class NoticeViewer extends StatefulWidget {
  final String title;
  final List<File> files;
  const NoticeViewer({super.key, required this.title, required this.files});
  @override
  State<NoticeViewer> createState() => _NoticeViewerState();
}

class _NoticeViewerState extends State<NoticeViewer> {
  final _pc = PageController();
  int _i = 0;
  bool _zoomed = false;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int d) => _pc.animateToPage(_i + d, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final n = widget.files.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        toolbarHeight: 76,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(iconSize: 38, icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        title: Text(n > 1 ? '${widget.title} — صفحه ${_i + 1} از $n' : widget.title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      ),
      body: PageView.builder(
        controller: _pc,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
        itemCount: n,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) => _ZoomPage(
          key: ValueKey(widget.files[i].path),
          file: widget.files[i],
          onZoom: (z) {
            if (z != _zoomed) setState(() => _zoomed = z);
          },
        ),
      ),
      bottomNavigationBar: n > 1
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 64)),
                      icon: const Icon(Icons.arrow_back, size: 32),
                      label: const Text('قبلی', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      onPressed: _i > 0 ? () => _go(-1) : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 64)),
                      icon: const Icon(Icons.arrow_forward, size: 32),
                      label: const Text('بعدی', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      onPressed: _i < n - 1 ? () => _go(1) : null,
                    ),
                  ),
                ]),
              ),
            )
          : null,
    );
  }
}

class _ZoomPage extends StatefulWidget {
  final File file;
  final ValueChanged<bool> onZoom;
  const _ZoomPage({super.key, required this.file, required this.onZoom});
  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> {
  final _tc = TransformationController();
  Offset _tap = Offset.zero;

  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.02;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() => widget.onZoom(_zoomed));
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onDoubleTapDown: (d) => _tap = d.localPosition,
        onDoubleTap: () {
          if (_zoomed) {
            _tc.value = Matrix4.identity();
          } else {
            const s = 2.5;
            _tc.value = Matrix4.identity()
              ..setEntry(0, 0, s)
              ..setEntry(1, 1, s)
              ..setEntry(0, 3, -_tap.dx * (s - 1))
              ..setEntry(1, 3, -_tap.dy * (s - 1));
          }
        },
        child: InteractiveViewer(
          transformationController: _tc,
          minScale: 1,
          maxScale: 8,
          child: Center(child: Image.file(widget.file, fit: BoxFit.contain, filterQuality: FilterQuality.high)),
        ),
      );
}
