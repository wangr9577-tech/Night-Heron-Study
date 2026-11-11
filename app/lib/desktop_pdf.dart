import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

Future<List<String>> desktopPdfText(String file) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(file);
  try {
    if (document.pages.length > 300) throw Exception('PDF 超过 300 页');
    final result = <String>[];
    var length = 0;
    for (final page in document.pages) {
      final text = (await page.loadText())?.fullText ?? '';
      length += text.length;
      if (length > 490000) throw Exception('提取文字过长，暂不支持导入');
      result.add(text);
    }
    return result;
  } finally {
    await document.dispose();
  }
}

Future<int> desktopPdfCount(String file) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(file);
  try {
    return document.pages.length;
  } finally {
    await document.dispose();
  }
}

Future<Uint8List?> desktopPdfPage(String file, int index) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(file);
  try {
    if (index < 0 || index >= document.pages.length)
      throw ArgumentError('页码无效');
    final page = document.pages[index];
    final scale = math.min(1600 / page.width, 2200 / page.height);
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
    if (rendered == null) return null;
    try {
      final image = await rendered.createImage();
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.png))?.buffer
            .asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  } finally {
    await document.dispose();
  }
}
