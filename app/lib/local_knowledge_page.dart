import 'package:flutter/material.dart';

import 'local_courses.dart';
import 'local_knowledge.dart';

class LocalKnowledgePage extends StatefulWidget {
  const LocalKnowledgePage({super.key, required this.courseId});
  final int courseId;
  @override
  State<LocalKnowledgePage> createState() => _LocalKnowledgePageState();
}

class _LocalKnowledgePageState extends State<LocalKnowledgePage> {
  LocalCourses? store;
  LocalKnowledge? graph;
  List<Map<String, Object?>> nodes = [], edges = [], notes = [];
  String? error;
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
      graph = LocalKnowledge(opened.db, widget.courseId);
      await _reload();
    } catch (e) {
      if (mounted) setState(() => error = '无法读取知识点：$e');
    }
  }

  Future<void> _reload() async {
    final values = await Future.wait([
      graph!.concepts(),
      graph!.edges(),
      store!.notes(widget.courseId),
    ]);
    if (mounted)
      setState(() {
        nodes = values[0];
        edges = values[1];
        notes = values[2];
      });
  }

  Future<void> _addConcept() async {
    var title = '';
    int? source;
    final result = await showDialog<(String, int?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('新建知识点'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (value) => title = value,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '知识点名称'),
              ),
              DropdownButtonFormField<int>(
                initialValue: source,
                decoration: const InputDecoration(labelText: '关联资料（可选）'),
                items: notes
                    .map(
                      (n) => DropdownMenuItem<int>(
                        value: n['id'] as int,
                        child: Text(
                          n['title'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => update(() => source = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (title, source)),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await graph!.addConcept(result.$1, noteId: result.$2);
      await _reload();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法创建：名称为空、重复或来源无效')));
    }
  }

  Future<void> _addEdge() async {
    if (nodes.length < 2) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先创建至少两个知识点')));
      return;
    }
    int source = nodes[0]['id'] as int, target = nodes[1]['id'] as int;
    String kind = 'prerequisite';
    final result = await showDialog<(int, int, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('建立知识关系'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: source,
                decoration: const InputDecoration(labelText: '起点'),
                items: nodes
                    .map(
                      (n) => DropdownMenuItem<int>(
                        value: n['id'] as int,
                        child: Text(
                          n['title'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) update(() => source = v);
                },
              ),
              DropdownButtonFormField<int>(
                initialValue: target,
                decoration: const InputDecoration(labelText: '终点'),
                items: nodes
                    .map(
                      (n) => DropdownMenuItem<int>(
                        value: n['id'] as int,
                        child: Text(
                          n['title'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) update(() => target = v);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: '关系'),
                items: const [
                  DropdownMenuItem(
                    value: 'prerequisite',
                    child: Text('起点是终点的前置'),
                  ),
                  DropdownMenuItem(value: 'related', child: Text('相关')),
                ],
                onChanged: (v) {
                  if (v != null) update(() => kind = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (source, target, kind)),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await graph!.addEdge(result.$1, result.$2, result.$3);
      await _reload();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().contains('循环') ? '前置关系不能形成循环' : '关系无效或已存在',
            ),
          ),
        );
    }
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地知识点')),
    body: store == null
        ? Center(child: Text(error ?? '正在读取…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('手动维护知识点和关联资料；前置关系从基础指向后续知识。'),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _addConcept,
                    icon: const Icon(Icons.add),
                    label: const Text('新建知识点'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addEdge,
                    icon: const Icon(Icons.hub_outlined),
                    label: const Text('建立关系'),
                  ),
                ],
              ),
              Text('知识点', style: Theme.of(context).textTheme.titleLarge),
              if (nodes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('还没有知识点。'),
                ),
              ...nodes.map(
                (n) => ListTile(
                  title: Text(n['title'] as String),
                  subtitle: Text(
                    n['source_title'] == null
                        ? '未关联资料'
                        : '来源：${n['source_title']}',
                  ),
                ),
              ),
              const Divider(),
              Text('知识关系', style: Theme.of(context).textTheme.titleLarge),
              if (edges.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('还没有关系。'),
                ),
              ...edges.map(
                (e) => ListTile(
                  leading: const Icon(Icons.arrow_forward),
                  title: Text('${e['source_title']} → ${e['target_title']}'),
                  subtitle: Text(e['kind'] == 'prerequisite' ? '前置关系' : '相关'),
                ),
              ),
            ],
          ),
  );
}
