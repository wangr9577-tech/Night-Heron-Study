import 'package:flutter/material.dart';

import 'ai_exam.dart';
import 'ai_settings.dart';
import 'local_courses.dart';
import 'local_exam.dart';

class AiExamPage extends StatefulWidget {
  const AiExamPage({
    super.key,
    required this.courseId,
    required this.store,
    required this.exams,
  });
  final int courseId;
  final LocalCourses store;
  final LocalExam exams;
  @override
  State<AiExamPage> createState() => _AiExamPageState();
}

class _AiExamPageState extends State<AiExamPage> {
  final title = TextEditingController(text: 'AI 资料自测卷');
  final requirements = TextEditingController();
  List<Map<String, Object?>> notes = [];
  List<AiExamQuestion> questions = [];
  int? selected;
  int count = 3;
  bool busy = false;
  String? generatedModel;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.store.notes(widget.courseId);
    if (mounted)
      setState(() {
        notes = result;
        if (notes.isNotEmpty) selected = notes.first['id'] as int;
      });
  }

  @override
  void dispose() {
    title.dispose();
    requirements.dispose();
    super.dispose();
  }

  void message(String value) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> generate() async {
    if (selected == null || busy) return;
    setState(() {
      busy = true;
      questions = [];
      generatedModel = null;
    });
    try {
      final settings = await AiSettings.load();
      if (settings == null) throw StateError('请先在 AI 模型设置中填写服务地址和模型');
      final source =
          notes.firstWhere((n) => n['id'] == selected)['body'] as String;
      final result = await generateAiExam(
        settings,
        source,
        count,
        requirements.text,
      );
      if (mounted)
        setState(() {
          questions = result;
          generatedModel = settings.model;
        });
    } catch (e) {
      message('生成失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || selected == null || generatedModel == null) return;
    setState(() => busy = true);
    try {
      await widget.exams.createFromAi(
        title.text,
        selected!,
        generatedModel!,
        questions,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      message('保存失败，请检查题目、答案和资料：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 根据资料出题')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '生成时会将所选资料的前 12000 个字符和你的要求发送给你配置的 AI 服务。模型可能出错，请逐题核对、修改后再保存。',
        ),
        if (notes.isEmpty)
          const Text('请先导入课程资料。')
        else
          DropdownButtonFormField<int>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: '选择资料'),
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
            onChanged: busy
                ? null
                : (v) => setState(() {
                    selected = v;
                    questions = [];
                    generatedModel = null;
                  }),
          ),
        TextField(
          controller: title,
          maxLength: 120,
          decoration: const InputDecoration(labelText: '试卷名称'),
        ),
        TextField(
          controller: requirements,
          maxLength: 1000,
          maxLines: 2,
          decoration: const InputDecoration(labelText: '命题范围或要求（可选）'),
        ),
        DropdownButtonFormField<int>(
          initialValue: count,
          decoration: const InputDecoration(labelText: '题数'),
          items: List.generate(
            10,
            (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1} 题')),
          ),
          onChanged: busy
              ? null
              : (v) => setState(() {
                  count = v!;
                  questions = [];
                  generatedModel = null;
                }),
        ),
        FilledButton(
          onPressed: busy || selected == null ? null : generate,
          child: Text(busy ? '处理中…' : '发送资料并生成'),
        ),
        if (questions.isNotEmpty)
          const Text('候选题目：请检查题目、答案和原文。提交后按文字匹配判分，等价答案需自行核对。'),
        ...questions.asMap().entries.map((entry) {
          final q = entry.value;
          return Card(
            key: ObjectKey(q),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('第 ${entry.key + 1} 题'),
                  TextFormField(
                    key: ObjectKey(q),
                    initialValue: q.prompt,
                    maxLines: null,
                    decoration: const InputDecoration(labelText: '题目'),
                    onChanged: (v) => q.prompt = v,
                  ),
                  TextFormField(
                    initialValue: q.answer,
                    maxLines: null,
                    decoration: const InputDecoration(labelText: '参考答案'),
                    onChanged: (v) => q.answer = v,
                  ),
                  TextFormField(
                    initialValue: q.explanation,
                    maxLines: null,
                    decoration: const InputDecoration(labelText: '解析'),
                    onChanged: (v) => q.explanation = v,
                  ),
                  SelectableText('引用原文：${q.quote}'),
                ],
              ),
            ),
          );
        }),
        if (questions.isNotEmpty)
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('确认并保存试卷'),
          ),
      ],
    ),
  );
}
