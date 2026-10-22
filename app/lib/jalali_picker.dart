import 'package:flutter/material.dart';
import 'jalali.dart';

const _monthNames = [
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
  'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند',
];
const _weekDays = ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج'];

int _daysIn(int jy, int jm) {
  if (jm <= 6) return 31;
  if (jm <= 11) return 30;
  final g = jalaliToGregorian(jy, 12, 30);
  final b = gregorianToJalali(g[0], g[1], g[2]);
  return (b[0] == jy && b[1] == 12 && b[2] == 30) ? 30 : 29;
}

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

DateTime _fromJ(int jy, int jm, int jd) {
  final g = jalaliToGregorian(jy, jm, jd);
  return DateTime.utc(g[0], g[1], g[2]);
}

String _fmt(DateTime d) => jstr(d);

/// انتخاب بازه‌ی تاریخ شمسی. خروجی: DateTimeRange با تاریخ‌های میلادیِ معادل (UTC).
Future<DateTimeRange?> showJalaliRangePicker(
  BuildContext context, {
  required DateTimeRange initial,
  DateTime? first,
  DateTime? last,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => Directionality(
      textDirection: TextDirection.rtl,
      child: _JalaliRangeDialog(
        initial: DateTimeRange(start: _day(initial.start), end: _day(initial.end)),
        first: _day(first ?? DateTime(2018)),
        last: _day(last ?? DateTime.now()),
      ),
    ),
  );
}

class _JalaliRangeDialog extends StatefulWidget {
  final DateTimeRange initial;
  final DateTime first, last;
  const _JalaliRangeDialog({required this.initial, required this.first, required this.last});
  @override
  State<_JalaliRangeDialog> createState() => _JalaliRangeDialogState();
}

class _JalaliRangeDialogState extends State<_JalaliRangeDialog> {
  late DateTime? _start = widget.initial.start;
  late DateTime? _end = widget.initial.end;
  late int _jy, _jm;

  @override
  void initState() {
    super.initState();
    final j = gregorianToJalali(widget.initial.end.year, widget.initial.end.month, widget.initial.end.day);
    _jy = j[0];
    _jm = j[1];
  }

  List<int> get _firstJ => gregorianToJalali(widget.first.year, widget.first.month, widget.first.day);
  List<int> get _lastJ => gregorianToJalali(widget.last.year, widget.last.month, widget.last.day);

  bool get _canPrev {
    final f = _firstJ;
    return _jy > f[0] || (_jy == f[0] && _jm > f[1]);
  }

  bool get _canNext {
    final l = _lastJ;
    return _jy < l[0] || (_jy == l[0] && _jm < l[1]);
  }

  void _move(int delta) => setState(() {
        var m = _jm + delta, y = _jy;
        if (m > 12) {
          m = 1;
          y++;
        } else if (m < 1) {
          m = 12;
          y--;
        }
        _jy = y;
        _jm = m;
      });

  void _tap(DateTime d) => setState(() {
        if (_start == null || _end != null) {
          _start = d;
          _end = null;
        } else if (d.isBefore(_start!)) {
          _start = d;
        } else {
          _end = d;
        }
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = _daysIn(_jy, _jm);
    final offset = (_fromJ(_jy, _jm, 1).weekday + 1) % 7; // شنبه = 0
    final cells = <Widget>[
      for (var i = 0; i < offset; i++) const SizedBox(),
      for (var d = 1; d <= n; d++) _cell(_fromJ(_jy, _jm, d), d, cs),
    ];
    final summary = _start == null
        ? 'شروع بازه را انتخاب کنید'
        : _end == null
            ? '${_fmt(_start!)}  تا  ...'
            : '${_fmt(_start!)}  تا  ${_fmt(_end!)}';
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('انتخاب بازه', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(summary, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Row(children: [
              IconButton(
                  onPressed: _canPrev ? () => _move(-1) : null, icon: const Icon(Icons.chevron_right)),
              Expanded(
                child: Text('${_monthNames[_jm - 1]} $_jy',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(onPressed: _canNext ? () => _move(1) : null, icon: const Icon(Icons.chevron_left)),
            ]),
            Row(children: [
              for (final w in _weekDays)
                Expanded(
                    child: Center(
                        child: Text(w, style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)))),
            ]),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: cells,
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('لغو')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _start == null
                    ? null
                    : () => Navigator.pop(context, DateTimeRange(start: _start!, end: _end ?? _start!)),
                child: const Text('تأیید'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _cell(DateTime date, int label, ColorScheme cs) {
    final enabled = !date.isBefore(widget.first) && !date.isAfter(widget.last);
    final isStart = _start != null && date == _start;
    final isEnd = _end != null && date == _end;
    final inRange = _start != null && _end != null && date.isAfter(_start!) && date.isBefore(_end!);
    final selected = isStart || isEnd;
    return GestureDetector(
      onTap: enabled ? () => _tap(date) : null,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 3, horizontal: inRange ? 0 : 2),
        decoration: BoxDecoration(
          color: selected ? cs.primary : (inRange ? cs.primaryContainer : null),
          borderRadius: BorderRadius.circular(selected ? 24 : (inRange ? 0 : 24)),
        ),
        alignment: Alignment.center,
        child: Text(
          '$label',
          style: TextStyle(
            color: selected ? cs.onPrimary : (enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.3)),
            fontWeight: selected ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }
}
