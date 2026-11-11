import 'package:flutter/material.dart';

import 'local_courses.dart';
import 'ai_exam_page.dart';
import 'local_exam.dart';
import 'readable_text.dart';

class LocalExamListPage extends StatefulWidget {
  const LocalExamListPage({super.key, required this.courseId});
  final int courseId;
  @override
  State<LocalExamListPage> createState() => _LocalExamListPageState();
}

class _LocalExamListPageState extends State<LocalExamListPage> {
  LocalCourses? store;
  LocalExam? exams;
  List<Map<String, Object?>> papers = [], questions = [];
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
      exams = LocalExam(opened.db, widget.courseId);
      await _reload();
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本地试卷');
    }
  }

  Future<void> _reload() async {
    final values = await Future.wait([
      exams!.list(),
      store!.questions(widget.courseId),
    ]);
    if (mounted)
      setState(() {
        papers = values[0];
        questions = values[1];
      });
  }

  Future<void> _create() async {
    if (questions.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在本地练习中创建题目')));
      return;
    }
    var title = '本地自测卷';
    final selected = <int>{};
    final result = await showDialog<(String, List<int>)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('从自建题目组卷'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  onChanged: (value) => title = value,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: '试卷名称',
                    hintText: '本地自测卷',
                  ),
                ),
                const Text('选择 1–50 道题；本版不计时。'),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: questions
                          .map(
                            (q) => CheckboxListTile(
                              value: selected.contains(q['id']),
                              title: Text(
                                q['prompt'] as String,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: (checked) => update(() {
                                if (checked == true) {
                                  selected.add(q['id'] as int);
                                } else {
                                  selected.remove(q['id']);
                                }
                              }),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                title,
                questions
                    .where((q) => selected.contains(q['id']))
                    .map((q) => q['id'] as int)
                    .toList(),
              )),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await exams!.create(result.$1, result.$2);
      await _reload();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('创建失败，请检查名称和所选题目')));
    }
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地自测试卷')),
    body: store == null
        ? Center(child: Text(error ?? '正在读取…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('可根据本地资料让 AI 出题，或手动选择题目。答案按文字匹配判分；可保存草稿。'),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AiExamPage(
                        courseId: widget.courseId,
                        store: store!,
                        exams: exams!,
                      ),
                    ),
                  );
                  if (mounted) await _reload();
                },
                icon: const Icon(Icons.auto_awesome),
                label: const Text('AI 根据资料出题'),
              ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('手动组合已有题目'),
              ),
              if (papers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('还没有试卷。'),
                ),
              ...papers.map(
                (paper) => Card(
                  child: ListTile(
                    title: Text(paper['title'] as String),
                    subtitle: Text(
                      paper['status'] == 'draft'
                          ? '未提交'
                          : '已提交 · 答对 ${paper['correct_count']} 题',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LocalExamTakePage(
                            exams: exams!,
                            id: paper['id'] as int,
                          ),
                        ),
                      );
                      if (mounted) await _reload();
                    },
                  ),
                ),
              ),
            ],
          ),
  );
}

class LocalExamTakePage extends StatefulWidget {
  const LocalExamTakePage({super.key, required this.exams, required this.id});
  final LocalExam exams;
  final int id;
  @override
  State<LocalExamTakePage> createState() => _LocalExamTakePageState();
}

class _LocalExamTakePageState extends State<LocalExamTakePage> {
  Map<String, Object?>? paper;
  final controllers = <int, TextEditingController>{};
  bool dirty = false, busy = false, allowPop = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.exams.load(widget.id);
      if (!mounted) return;
      final items = loaded['items'] as List;
      for (final item in items) {
        controllers.putIfAbsent(
          item['question_id'] as int,
          () => TextEditingController(text: item['response'] as String),
        );
      }
      setState(() {
        paper = loaded;
        dirty = false;
      });
    } catch (_) {
      if (mounted) setState(() => error = '无法读取试卷');
    }
  }

  Future<void> _save() async {
    for (final item in (paper!['items'] as List)) {
      final qid = item['question_id'] as int;
      await widget.exams.saveAnswer(widget.id, qid, controllers[qid]!.text);
    }
    if (mounted) setState(() => dirty = false);
  }

  Future<void> _saveAction() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await _save();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('草稿已保存')));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败，请检查答案长度')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _submit() async {
    if (busy) return;
    final blank = controllers.values.where((c) => c.text.trim().isEmpty).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提交试卷'),
        content: Text(blank > 0 ? '有 $blank 题未作答，提交后按错误处理。' : '提交后不能再修改答案。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续作答'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await _save();
      await widget.exams.submit(widget.id);
      await _load();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('提交失败，请重试')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _back() async {
    if (busy) return;
    if (dirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('答案尚未保存'),
          content: const Text('离开会丢失未保存的修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续作答'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final submitted = paper?['status'] == 'submitted';
    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(paper?['title'] as String? ?? '试卷')),
        body: paper == null
            ? Center(child: Text(error ?? '正在读取…'))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (!submitted) const Text('本自测试卷不计时。答案修改后请保存草稿，提交后不能修改。'),
                  if (submitted)
                    Text(
                      '答对 ${paper!['correct_count']} / ${(paper!['items'] as List).length} 题，按文字匹配判定，请自行核对等价答案。',
                    ),
                  ...(paper!['items'] as List).map(
                    (item) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ReadingText(
                              '${(item['position'] as int) + 1}. ${item['prompt']}',
                              selectable: true,
                            ),
                            TextField(
                              controller:
                                  controllers[item['question_id'] as int],
                              enabled: !busy || submitted,
                              readOnly: submitted,
                              maxLines: 2,
                              maxLength: 1000,
                              onChanged: (_) {
                                if (!dirty) setState(() => dirty = true);
                              },
                              decoration: const InputDecoration(
                                labelText: '你的答案',
                              ),
                            ),
                            if (submitted) ...[
                              if (item['quote'] != null)
                                SelectableText(
                                  '资料 ${item['source_title']}：${item['quote']}',
                                ),
                              Text(
                                item['correct'] == 1 ? '与参考答案一致' : '与参考答案不一致',
                              ),
                              ReadingText(
                                '参考答案：${item['answer']}',
                                selectable: true,
                              ),
                              if ((item['explanation'] as String).isNotEmpty)
                                ReadingText(
                                  '解析：${item['explanation']}',
                                  selectable: true,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!submitted)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: busy ? null : _saveAction,
                          child: const Text('保存草稿'),
                        ),
                        FilledButton(
                          onPressed: busy ? null : _submit,
                          child: const Text('提交试卷'),
                        ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}
