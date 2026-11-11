import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'local_courses.dart';
import 'local_platform.dart';

class LocalOcrPage extends StatefulWidget {
  const LocalOcrPage({
    super.key,
    required this.image,
    required this.courseId,
    required this.title,
    this.sourceExtension,
  });
  final Uint8List image;
  final int courseId;
  final String title;

  /// Set only for an imported image that must also be retained locally.
  final String? sourceExtension;
  @override
  State<LocalOcrPage> createState() => _LocalOcrPageState();
}

class _LocalOcrPageState extends State<LocalOcrPage> {
  final text = TextEditingController();
  TextRecognitionScript script = TextRecognitionScript.chinese;
  bool busy = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> recognize() async {
    if (busy) return;
    setState(() => busy = true);
    File? temporary;
    final recognizer = Platform.isWindows
        ? null
        : TextRecognizer(script: script);
    try {
      final dir = await getTemporaryDirectory();
      temporary = File(
        path.join(
          dir.path,
          'ocr_${DateTime.now().microsecondsSinceEpoch}.${widget.sourceExtension ?? 'png'}',
        ),
      );
      await temporary.writeAsBytes(widget.image, flush: true);
      final recognized = Platform.isWindows
          ? await const MethodChannel('zhi/local_ocr')
                    .invokeMethod<String>('recognize', {
                      'path': temporary.path,
                      'language': script == TextRecognitionScript.latin
                          ? 'en-US'
                          : 'zh-Hans',
                    }) ??
                ''
          : (await recognizer!.processImage(
              InputImage.fromFilePath(temporary.path),
            )).text;
      if (mounted) setState(() => text.text = recognized);
      if (recognized.trim().isEmpty && mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未识别到文字，请尝试另一种语言或更清晰的页面。')),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Platform.isWindows
                  ? '识别失败：请检查图片或 Windows OCR 语言包。$error'
                  : '识别失败，请重试。',
            ),
          ),
        );
    } finally {
      try {
        await recognizer?.close();
      } catch (_) {}
      try {
        if (temporary != null && await temporary.exists())
          await temporary.delete();
      } catch (_) {}
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || (text.text.trim().isEmpty && widget.sourceExtension == null))
      return;
    setState(() => busy = true);
    try {
      final store = await LocalCourses.open();
      Directory? sourceDirectory;
      File? saved;
      var committed = false;
      try {
        final extension = widget.sourceExtension;
        if (extension != null) {
          if (!const {'jpg', 'jpeg', 'png'}.contains(extension))
            throw ArgumentError('不支持的图片格式');
          final parent = await localSourceDirectory();
          await parent.create(recursive: true);
          sourceDirectory = await parent.createTemp('image_');
          saved = File(path.join(sourceDirectory.path, 'source.$extension'));
          await saved.writeAsBytes(widget.image, flush: true);
        }
        await store.addNote(
          widget.courseId,
          widget.title,
          text.text.trim().isEmpty ? '未保存识别文字，请打开原图查看。' : text.text,
          localFile: saved?.path,
        );
        committed = true;
      } finally {
        if (!committed) {
          try {
            if (saved != null && await saved.exists()) await saved.delete();
          } catch (_) {}
          try {
            if (sourceDirectory != null && await sourceDirectory.exists())
              await sourceDirectory.delete();
          } catch (_) {}
        }
        await store.close();
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.sourceExtension == null ? '识别本页文字' : '识别图片文字'),
    ),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text('识别在设备上进行。结果可能有错误，请核对公式、表格并修改后保存。'),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('中文与英文'),
                selected: script == TextRecognitionScript.chinese,
                onSelected: busy
                    ? null
                    : (_) => setState(
                        () => script = TextRecognitionScript.chinese,
                      ),
              ),
              ChoiceChip(
                label: const Text('英文'),
                selected: script == TextRecognitionScript.latin,
                onSelected: busy
                    ? null
                    : (_) =>
                          setState(() => script = TextRecognitionScript.latin),
              ),
            ],
          ),
          FilledButton.tonal(
            onPressed: busy ? null : recognize,
            child: Text(busy ? '处理中…' : '开始识别'),
          ),
          Expanded(
            child: TextField(
              controller: text,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: '识别结果，可编辑',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: FilledButton(
              onPressed: busy ? null : save,
              child: const Text('保存为课程资料'),
            ),
          ),
        ],
      ),
    ),
  );
}
