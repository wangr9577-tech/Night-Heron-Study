import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import 'desktop_pdf.dart';

import 'local_ocr_page.dart';

class LocalPdfView extends StatefulWidget {
  const LocalPdfView({
    super.key,
    required this.filePath,
    required this.title,
    this.courseId,
  });
  final String filePath;
  final String title;
  final int? courseId;
  @override
  State<LocalPdfView> createState() => _LocalPdfViewState();
}

class _LocalPdfViewState extends State<LocalPdfView> {
  static const channel = MethodChannel('zhi/local_pdf');
  int? count;
  int index = 0;
  String? error;
  Future<Uint8List?>? image;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final pages = Platform.isWindows
          ? await desktopPdfCount(widget.filePath)
          : await channel.invokeMethod<int>('pageCount', {
              'path': widget.filePath,
            });
      if (pages == null || pages < 1) throw Exception('PDF 没有页面');
      if (!mounted) return;
      setState(() {
        count = pages;
        image = _render(0);
      });
    } catch (_) {
      if (mounted) setState(() => error = '无法打开 PDF，请检查文件是否完整。');
    }
  }

  Future<Uint8List?> _render(int page) => Platform.isWindows
      ? desktopPdfPage(widget.filePath, page)
      : channel.invokeMethod<Uint8List>('renderPage', {
          'path': widget.filePath,
          'page': page,
        });
  void _go(int page) {
    if (count == null || page < 0 || page >= count!) return;
    setState(() {
      index = page;
      image = _render(page);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        if (widget.courseId != null && image != null)
          TextButton(
            onPressed: () async {
              try {
                final pageNumber = index + 1;
                final bytes = await image;
                if (bytes == null || !context.mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalOcrPage(
                      image: bytes,
                      courseId: widget.courseId!,
                      title:
                          '${widget.title.length > 90 ? widget.title.substring(0, 90) : widget.title} · 第 $pageNumber 页识别',
                    ),
                  ),
                );
              } catch (_) {
                if (context.mounted)
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('页面暂不可识别')));
              }
            },
            child: const Text('识别本页'),
          ),
      ],
    ),
    body: error != null
        ? Center(child: Text(error!))
        : count == null
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: FutureBuilder<Uint8List?>(
                  future: image,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError ||
                        (snapshot.connectionState == ConnectionState.done &&
                            snapshot.data == null))
                      return const Center(child: Text('页面加载失败'));
                    if (!snapshot.hasData)
                      return const Center(child: CircularProgressIndicator());
                    return InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: SingleChildScrollView(
                          child: Image.memory(
                            snapshot.data!,
                            semanticLabel: 'PDF 第 ${index + 1} 页',
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: index > 0 ? () => _go(index - 1) : null,
                      child: const Text('上一页'),
                    ),
                    Text('${index + 1} / $count'),
                    TextButton(
                      onPressed: index + 1 < count!
                          ? () => _go(index + 1)
                          : null,
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ),
            ],
          ),
  );
}
