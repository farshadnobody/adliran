List<int> gregorianToJalali(int gy, int gm, int gd) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days = 355666 + 365 * gy + ((gy2 + 3) ~/ 4) - ((gy2 + 99) ~/ 100) +
      ((gy2 + 399) ~/ 400) + gd + gdm[gm - 1];
  var jy = -1595 + 33 * (days ~/ 12053);
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  int jm, jd;
  if (days < 186) {
    jm = 1 + days ~/ 31;
    jd = 1 + days % 31;
  } else {
    jm = 7 + (days - 186) ~/ 30;
    jd = 1 + (days - 186) % 30;
  }
  return [jy, jm, jd];
}

List<int> jalaliToGregorian(int jy, int jm, int jd) {
  jy += 1595;
  var days = -355668 + 365 * jy + (jy ~/ 33) * 8 + (((jy % 33) + 3) ~/ 4) + jd;
  days += jm < 7 ? (jm - 1) * 31 : (jm - 7) * 30 + 186;
  var gy = 400 * (days ~/ 146097);
  days %= 146097;
  if (days > 36524) {
    days -= 1;
    gy += 100 * (days ~/ 36524);
    days %= 36524;
    if (days >= 365) days += 1;
  }
  gy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    gy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  var gd = days + 1;
  final leap = (gy % 4 == 0 && gy % 100 != 0) || gy % 400 == 0;
  final sal = [0, 31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  var gm = 1;
  while (gm < 13 && gd > sal[gm]) {
    gd -= sal[gm];
    gm++;
  }
  return [gy, gm, gd];
}

String jstr(DateTime d) {
  final j = gregorianToJalali(d.year, d.month, d.day);
  return '${j[0].toString().padLeft(4, '0')}/${j[1].toString().padLeft(2, '0')}/${j[2].toString().padLeft(2, '0')}';
}

/// اول ماه شمسیِ تاریخ داده‌شده
DateTime jalaliMonthStart(DateTime d) {
  final j = gregorianToJalali(d.year, d.month, d.day);
  final g = jalaliToGregorian(j[0], j[1], 1);
  return DateTime.utc(g[0], g[1], g[2]);
}
