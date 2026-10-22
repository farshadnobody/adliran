import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

class LogPage extends StatelessWidget {
  const LogPage({super.key});

  Color _color(String l) => switch (l) {
        'error' => Colors.red.shade700,
        'warn' => Colors.orange.shade800,
        _ => Colors.blueGrey,
      };

  IconData _icon(String l) => switch (l) {
        'error' => Icons.error_rounded,
        'warn' => Icons.warning_amber_rounded,
        _ => Icons.info_rounded,
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('گزارش خطاها (لاگ)', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              tooltip: 'کپی همه',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: AppLog.dump()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لاگ کپی شد')));
                }
              },
            ),
            IconButton(
              tooltip: 'پاک کردن',
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('همه‌ی لاگ‌ها پاک شود؟'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('خیر')),
                      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('پاک کن')),
                    ],
                  ),
                );
                if (ok == true) await AppLog.clear();
              },
            ),
          ],
        ),
        body: ValueListenableBuilder<List<LogEntry>>(
          valueListenable: AppLog.entries,
          builder: (_, list, __) {
            if (list.isEmpty) {
              return const Center(child: Text('لاگی ثبت نشده', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)));
            }
            return ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final e = list[i];
                final c = _color(e.level);
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: c.withOpacity(.5), width: 1.5),
                  ),
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    leading: Icon(_icon(e.level), color: c, size: 30),
                    title: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(e.where, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e.timeStr, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                      Text(e.message, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 14)),
                    ]),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(e.message, style: const TextStyle(fontSize: 14)),
                      if (e.detail != null) ...[
                        const Divider(),
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: SelectableText(e.detail!, style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
}
