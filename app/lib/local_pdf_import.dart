import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:read_pdf_text/read_pdf_text.dart';

import 'local_courses.dart';
import 'desktop_pdf.dart';
import 'local_platform.dart';

/// Stores an app-private copy and a page-labelled extraction, without OCR.
Future<void> importLocalPdf(
  LocalCourses store,
  int courseId,
  String name,
  File input,
) async {
  if (await input.length() > 20000000) throw Exception('PDF 超过 20 MB');
  final pages = Platform.isWindows
      ? await desktopPdfText(input.path)
      : await ReadPdfText.getPDFtextPaginated(input.path);
  if (pages.length > 300) throw Exception('PDF 超过 300 页');
  final body = pages.indexed
      .map((p) => '第 ${p.$1 + 1} 页\n${p.$2.trim()}')
      .join('\n\n');
  if (body.length > 500000) throw Exception('提取文字过长，暂不支持导入');
  final parent = await localSourceDirectory();
  await parent.create(recursive: true);
  final dir = await parent.createTemp('pdf_');
  final saved = File(path.join(dir.path, 'source.pdf'));
  var committed = false;
  try {
    await input.copy(saved.path);
    final noText = pages.every((page) => page.trim().isEmpty);
    await store.addNote(
      courseId,
      name,
      noText ? '此 PDF 未提取到文字，原文件已保存。请打开原 PDF，逐页识别并核对文字。' : body,
      localFile: saved.path,
    );
    committed = true;
  } finally {
    if (!committed) {
      if (await saved.exists()) await saved.delete();
      if (await dir.exists()) await dir.delete();
    }
  }
}
