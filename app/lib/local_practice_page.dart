import 'package:flutter/material.dart';

import 'local_courses.dart';
import 'readable_text.dart';
import 'local_review.dart';
import 'local_review_page.dart';
import 'local_exam_page.dart';

class LocalPracticePage extends StatefulWidget {
  const LocalPracticePage({super.key, required this.courseId});
  final int courseId;
  @override
  State<LocalPracticePage> createState() => _LocalPracticePageState();
}

class _LocalPracticePageState extends State<LocalPracticePage> {
  LocalCourses? store;
  List<Map<String, Object?>> items = [];
  bool mistakesOnly = false;
  int loadVersion = 0;
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
      await _reload();
    } catch (e) {
      if (mounted) setState(() => error = '读取练习失败：$e');
    }
  }

  Future<void> _reload() async {
    final version = ++loadVersion;
    final rows = mistakesOnly
        ? await store!.incorrectQuestions(widget.courseId)
        : await store!.questions(widget.courseId);
    if (mounted && version == loadVersion) setState(() => items = rows);
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地练习')),
    body: store == null
        ? Center(child: Text(error ?? '正在读取…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('创建简答题进行自测。判分按文字完全匹配（忽略首尾空格和英文字母大小写），请自行核对等价答案。'),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LocalQuestionEditor(
                        store: store!,
                        courseId: widget.courseId,
                      ),
                    ),
                  );
                  if (mounted) await _reload();
                },
                icon: const Icon(Icons.add),
                label: const Text('新建题目'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalReviewPage(courseId: widget.courseId),
                  ),
                ),
                icon: const Icon(Icons.event_repeat),
                label: const Text('间隔复习'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        LocalExamListPage(courseId: widget.courseId),
                  ),
                ),
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('本地自测试卷'),
              ),
              SwitchListTile(
                value: mistakesOnly,
                title: const Text('只看最近答错的题'),
                subtitle: const Text('重新答对后移出列表，所有作答仍保留在本机'),
                onChanged: (value) {
                  setState(() => mistakesOnly = value);
                  _reload();
                },
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(mistakesOnly ? '目前没有最近答错的题。' : '还没有题目。'),
                ),
              ...items.map(
                (q) => Card(
                  child: ListTile(
                    title: Text(
                      q['prompt'] as String,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: q['last_response'] == null
                        ? null
                        : Text(
                            '上次作答：${q['last_response']}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LocalQuestionPage(
                            store: store!,
                            courseId: widget.courseId,
                            question: q,
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

class LocalQuestionEditor extends StatefulWidget {
  const LocalQuestionEditor({
    super.key,
    required this.store,
    required this.courseId,
  });
  final LocalCourses store;
  final int courseId;
  @override
  State<LocalQuestionEditor> createState() => _LocalQuestionEditorState();
}

class _LocalQuestionEditorState extends State<LocalQuestionEditor> {
  final prompt = TextEditingController(),
      answer = TextEditingController(),
      explanation = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    prompt.dispose();
    answer.dispose();
    explanation.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.store.addQuestion(
        widget.courseId,
        prompt.text,
        answer.text,
        explanation.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请填写题目与参考答案，检查内容长度')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新建自测题')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: prompt,
          maxLines: 4,
          maxLength: 5000,
          decoration: const InputDecoration(labelText: '题目'),
        ),
        TextField(
          controller: answer,
          maxLines: 2,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: '参考答案'),
        ),
        TextField(
          controller: explanation,
          maxLines: 3,
          maxLength: 5000,
          decoration: const InputDecoration(labelText: '解析（可选）'),
        ),
        FilledButton(onPressed: busy ? null : save, child: const Text('保存题目')),
      ],
    ),
  );
}

class LocalQuestionPage extends StatefulWidget {
  const LocalQuestionPage({
    super.key,
    required this.store,
    required this.courseId,
    required this.question,
  });
  final LocalCourses store;
  final int courseId;
  final Map<String, Object?> question;
  @override
  State<LocalQuestionPage> createState() => _LocalQuestionPageState();
}

class _LocalQuestionPageState extends State<LocalQuestionPage> {
  final response = TextEditingController();
  bool busy = false;
  bool? result;
  @override
  void dispose() {
    response.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || response.text.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      final value = await widget.store.attempt(
        widget.courseId,
        widget.question['id'] as int,
        response.text,
      );
      if (mounted) setState(() => result = value);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('提交失败，请检查答案')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('自测')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ReadingText(widget.question['prompt'] as String, selectable: true),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await LocalReview(
                      widget.store.db,
                      widget.courseId,
                    ).schedule(widget.question['id'] as int);
                    if (mounted)
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已加入或已存在于复习计划')),
                      );
                  } catch (_) {
                    if (mounted)
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('无法加入复习计划')));
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          icon: const Icon(Icons.event_repeat),
          label: const Text('加入复习计划'),
        ),
        TextField(
          controller: response,
          maxLines: 3,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: '你的答案'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: const Text('提交答案'),
        ),
        if (result != null) ...[
          Text(result! ? '与参考答案一致' : '与参考答案不一致，请自行核对等价答案'),
          ReadingText('参考答案：${widget.question['answer']}', selectable: true),
          if ((widget.question['explanation'] as String).isNotEmpty)
            ReadingText(
              '解析：${widget.question['explanation']}',
              selectable: true,
            ),
        ],
      ],
    ),
  );
}
