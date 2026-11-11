import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_courses.dart';
import 'readable_text.dart';
import 'local_pdf_import.dart';
import 'local_pdf_view.dart';
import 'local_ocr_page.dart';
import 'local_practice_page.dart';
import 'local_search_page.dart';
import 'local_knowledge_page.dart';
import 'local_home.dart' show LocalAsk;

class LocalCoursePage extends StatefulWidget {
  const LocalCoursePage({super.key, required this.id, required this.title});
  final int id;
  final String title;
  @override
  State<LocalCoursePage> createState() => _LocalCoursePageState();
}

class _LocalCoursePageState extends State<LocalCoursePage> {
  LocalCourses? store;
  List<Map<String, Object?>> notes = [];
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final opened = await LocalCourses.open();
      if (!mounted) {
        await opened.close();
        return;
      }
      store = opened;
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) setState(() => error = '无法读取资料：$e');
    }
  }

  Future<void> _refresh() async {
    final rows = await store!.notes(widget.id);
    if (mounted) setState(() => notes = rows);
  }

  Future<void> _import() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'pdf', 'png', 'jpg', 'jpeg'],
        withData: false,
      );
      if (selected == null) return;
      final picked = selected.files.single;
      if (picked.path == null) throw Exception('无法读取文件');
      final file = File(picked.path!);
      final lowerName = picked.name.toLowerCase();
      if (lowerName.endsWith('.pdf')) {
        await importLocalPdf(store!, widget.id, picked.name, file);
      } else if (lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg')) {
        if (await file.length() > 10000000) throw Exception('图片超过 10 MB');
        final bytes = await file.readAsBytes();
        final extension = lowerName.substring(lowerName.lastIndexOf('.') + 1);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LocalOcrPage(
              image: bytes,
              courseId: widget.id,
              title: picked.name,
              sourceExtension: extension,
            ),
          ),
        );
      } else {
        if (await file.length() > 1000000) throw Exception('文字文件超过 1 MB');
        final body = utf8.decode(await file.readAsBytes());
        await store!.addNote(
          widget.id,
          picked.name,
          body,
          markdown: lowerName.endsWith('.md'),
        );
      }
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: store == null
        ? Center(child: Text(error ?? '正在读取…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                '资料保存在此设备。支持 UTF-8 TXT、Markdown、图片和 PDF；图片或 PDF 可识别文字，结果请对照原文核对。',
              ),
              FilledButton.icon(
                onPressed: busy ? null : _import,
                icon: const Icon(Icons.upload_file),
                label: Text(busy ? '正在导入…' : '导入资料'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalPracticePage(courseId: widget.id),
                  ),
                ),
                icon: const Icon(Icons.quiz_outlined),
                label: const Text('本地自测题'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalSearchPage(courseId: widget.id),
                  ),
                ),
                icon: const Icon(Icons.search),
                label: const Text('本地资料检索'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalKnowledgePage(courseId: widget.id),
                  ),
                ),
                icon: const Icon(Icons.hub_outlined),
                label: const Text('本地知识点与关系'),
              ),
              if (notes.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('还没有文字资料。'),
                ),
              ...notes.map(
                (note) => Card(
                  child: ListTile(
                    title: Text(note['title'] as String),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LocalNotePage(note: note),
                        ),
                      );
                      if (mounted) await _refresh();
                    },
                  ),
                ),
              ),
            ],
          ),
  );
}

class LocalNotePage extends StatefulWidget {
  const LocalNotePage({super.key, required this.note});
  final Map<String, Object?> note;
  @override
  State<LocalNotePage> createState() => _LocalNotePageState();
}

class _LocalNotePageState extends State<LocalNotePage> {
  final scroll = ScrollController();
  final tts = FlutterTts();
  SharedPreferences? preferences;
  Timer? saveTimer;
  bool speaking = false;
  int playbackVersion = 0;
  String get positionKey => 'local_note_position_${widget.note['id']}';

  @override
  void initState() {
    super.initState();
    scroll.addListener(_savePositionLater);
    _restorePosition();
  }

  Future<void> _restorePosition() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    preferences = prefs;
    final saved = prefs.getDouble(positionKey) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients && saved > 0) {
        scroll.jumpTo(saved.clamp(0.0, scroll.position.maxScrollExtent));
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _savePositionLater() {
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 500), () {
      if (scroll.hasClients && preferences != null) {
        unawaited(preferences!.setDouble(positionKey, scroll.offset));
      }
    });
  }

  Future<void> _stop() async {
    playbackVersion++;
    try {
      await tts.stop();
    } catch (_) {}
    if (mounted) setState(() => speaking = false);
  }

  Future<void> _disposeSpeech() async {
    try {
      await tts.stop();
    } catch (_) {}
  }

  Future<void> _speak() async {
    if (speaking) {
      await _stop();
      return;
    }
    final version = ++playbackVersion;
    setState(() => speaking = true);
    try {
      await tts.setSpeechRate(.45);
      await tts.awaitSpeakCompletion(true);
      final points = (widget.note['body'] as String).runes.toList();
      for (
        var start = 0;
        start < points.length && mounted && version == playbackVersion;
        start += 1500
      ) {
        final end = (start + 1500 < points.length)
            ? start + 1500
            : points.length;
        await tts.speak(String.fromCharCodes(points.sublist(start, end)));
      }
    } catch (_) {
      if (mounted && version == playbackVersion)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设备语音引擎不可用')));
    } finally {
      if (mounted && version == playbackVersion)
        setState(() => speaking = false);
    }
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    if (scroll.hasClients && preferences != null)
      unawaited(preferences!.setDouble(positionKey, scroll.offset));
    playbackVersion++;
    if (speaking) unawaited(_disposeSpeech());
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return Scaffold(
      appBar: AppBar(
        title: Text(note['title'] as String),
        actions: [
          if (note['local_path'] is String)
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      (note['local_path'] as String).toLowerCase().endsWith(
                        '.pdf',
                      )
                      ? LocalPdfView(
                          filePath: note['local_path'] as String,
                          title: note['title'] as String,
                          courseId: note['course_id'] as int,
                        )
                      : Scaffold(
                          appBar: AppBar(title: Text(note['title'] as String)),
                          body: Center(
                            child: InteractiveViewer(
                              child: Image.file(
                                File(note['local_path'] as String),
                                errorBuilder: (_, __, ___) =>
                                    const Text('无法读取原图'),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              child: Text(
                (note['local_path'] as String).toLowerCase().endsWith('.pdf')
                    ? '查看原 PDF'
                    : '查看原图',
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('local-note-scroll'),
        controller: scroll,
        padding: const EdgeInsets.all(20),
        child: ReadingText(
          note['body'] as String,
          rich: note['is_markdown'] == 1,
          selectable: true,
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('朗读使用设备语音引擎，联网情况取决于设备设置。'),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _speak,
                    icon: Icon(
                      speaking ? Icons.stop : Icons.volume_up_outlined,
                    ),
                    label: Text(speaking ? '停止朗读' : '朗读文字'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocalAsk(
                          sourceText: note['body'] as String,
                          sourceTitle: note['title'] as String,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.question_answer_outlined),
                    label: const Text('针对这份资料提问'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
