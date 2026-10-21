import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

String _mime(String name) {
  final e = name.split('.').last.toLowerCase();
  switch (e) {
    case 'pdf':
      return 'application/pdf';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'html':
      return 'text/html;charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}

/// فایل را در تب جدید Chrome باز می‌کند (PDF/تصویر) یا دانلود می‌کند
void openBytesWeb(String name, List<int> bytes) {
  final blob = web.Blob(
    <JSAny>[Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: _mime(name)),
  );
  final url = web.URL.createObjectURL(blob);
  final ok = _mime(name) != 'application/octet-stream';
  if (ok) {
    web.window.open(url, '_blank');
  } else {
    final a = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = name;
    a.click();
  }
}
