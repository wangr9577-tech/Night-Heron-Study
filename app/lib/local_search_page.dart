import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'local_courses.dart';
import 'local_search.dart';
import 'readable_text.dart';

class LocalSearchPage extends StatefulWidget {
  const LocalSearchPage({super.key, required this.courseId});
  final int courseId;
  @override
  State<LocalSearchPage> createState() => _LocalSearchPageState();
}

class _LocalSearchPageState extends State<LocalSearchPage> {
  final query = TextEditingController();
  List<LocalSearchHit> hits = [];
  bool searched = false;
  bool busy = false;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    final terms = query.text;
    if (busy || terms.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      final store = await LocalCourses.open();
      try {
        final notes = await store.notes(widget.courseId);
        final found = await compute(searchLocalRequest, (notes, terms));
        if (mounted)
          setState(() {
            hits = found;
            searched = true;
          });
      } finally {
        await store.close();
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('读取本地资料失败')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地资料检索')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('按关键词查找当前课程已保存的原文，不会联网或生成答案。'),
        TextField(
          controller: query,
          maxLength: 500,
          decoration: const InputDecoration(labelText: '输入关键词或问题'),
          onSubmitted: (_) => search(),
        ),
        FilledButton(
          onPressed: busy ? null : search,
          child: Text(busy ? '查找中…' : '查找资料'),
        ),
        if (searched && hits.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('没有找到匹配片段，请换关键词或先导入资料。'),
          ),
        ...hits.map(
          (hit) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '来源：${hit.title}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ReadingText(hit.text, selectable: true),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
