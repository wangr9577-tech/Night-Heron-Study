part of 'main.dart';

class CourseMembersPage extends StatelessWidget {
  final String courseId;
  const CourseMembersPage({super.key, required this.courseId});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('课程成员')),
    body: RemoteView(
      load: () async => {
        'user': await api.get('/users/me'),
        'members': await api.get('/courses/$courseId/members'),
      },
      builder: (data, reload) {
        final userId = val(data['user']['user_id']);
        final members = items(data['members']);
        final owner = members.any(
          (m) => m['user_id'] == userId && m['role'] == 'owner',
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('添加成员不会自动授予审核权限；审核权限由服务端管理员配置。'),
            if (owner)
              FilledButton.icon(
                icon: const Icon(Icons.person_add_alt),
                label: const Text('按用户 ID 添加成员'),
                onPressed: () async {
                  final id = await inputDialog(context, '添加课程成员', '对方的用户 ID');
                  if (id == null || id.trim().isEmpty) return;
                  try {
                    await api.post('/courses/$courseId/members', {
                      'user_id': id.trim(),
                    });
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            for (final member in members)
              ListTile(
                title: SelectableText(val(member['user_id'])),
                subtitle: Text(member['role'] == 'owner' ? '课程创建者' : '课程成员'),
                trailing: owner && member['user_id'] != userId
                    ? IconButton(
                        tooltip: '移除成员',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('移除课程成员？'),
                              content: const Text('该成员将失去课程访问权及本课程审核授权。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('移除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true) return;
                          try {
                            await api.request(
                              'DELETE',
                              '/courses/$courseId/members/${val(member['user_id'])}',
                            );
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      )
                    : null,
              ),
          ],
        );
      },
    ),
  );
}

/// Review is available only after the server grants the role for this course.
class ReviewQueuePage extends StatefulWidget {
  final String courseId;
  const ReviewQueuePage({super.key, required this.courseId});

  @override
  State<ReviewQueuePage> createState() => _ReviewQueuePageState();
}

class _ReviewQueuePageState extends State<ReviewQueuePage> {
  int tab = 0;
  int revision = 0;

  @override
  Widget build(BuildContext context) {
    final prefix = '/courses/${widget.courseId}';
    final path = tab == 0
        ? '$prefix/mistakes/review-queue'
        : '$prefix/assessment/review-queue';
    return Scaffold(
      appBar: AppBar(title: const Text('课程审核')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('错题校对')),
                ButtonSegment(value: 1, label: Text('主观题评分')),
              ],
              selected: {tab},
              onSelectionChanged: (selected) =>
                  setState(() => tab = selected.first),
            ),
          ),
          Expanded(
            child: FutureBuilder<dynamic>(
              key: ValueKey('$tab-$revision'),
              future: api.get(path),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('无法读取审核队列：${snapshot.error}\n请检查网络及本课程审核权限。'),
                          TextButton(
                            onPressed: () => setState(() => revision++),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final entries = items(snapshot.data);
                if (entries.isEmpty)
                  return const Center(child: Text('暂无待审核项目（自己的记录不会显示）'));
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final text = tab == 0
                        ? val(
                            entry['corrected_question'] ??
                                entry['recognized_text'],
                          )
                        : val(entry['question']?['prompt']);
                    return Card(
                      child: ListTile(
                        title: Text(
                          text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('学习者：${val(entry['user_id'])}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final saved = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => tab == 0
                                  ? MistakeReviewPage(
                                      courseId: widget.courseId,
                                      entry: entry,
                                    )
                                  : AttemptReviewPage(
                                      courseId: widget.courseId,
                                      entry: entry,
                                    ),
                            ),
                          );
                          if (saved == true && mounted)
                            setState(() => revision++);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class MistakeReviewPage extends StatefulWidget {
  final String courseId;
  final dynamic entry;
  const MistakeReviewPage({
    super.key,
    required this.courseId,
    required this.entry,
  });

  @override
  State<MistakeReviewPage> createState() => _MistakeReviewPageState();
}

class _MistakeReviewPageState extends State<MistakeReviewPage> {
  late final TextEditingController prompt;
  final answer = TextEditingController();
  final explanation = TextEditingController();
  final cause = TextEditingController();
  String kind = 'cloze';
  String? concept;
  bool busy = false;
  final selectedRefs = <int>{};
  late final Future<http.Response> original;

  @override
  void initState() {
    super.initState();
    prompt = TextEditingController(
      text: val(
        widget.entry['corrected_question'] ?? widget.entry['recognized_text'],
      ),
    );
    final concepts = items(widget.entry, 'available_concepts');
    if (concepts.isNotEmpty) concept = val(concepts.first['id']);
    original = api.client
        .get(
          api.uri(
            '/courses/${widget.courseId}/mistakes/${val(widget.entry['id'])}/review-original',
          ),
          headers: {'Authorization': 'Bearer ${api.token}'},
        )
        .timeout(const Duration(seconds: 30));
  }

  @override
  void dispose() {
    prompt.dispose();
    answer.dispose();
    explanation.dispose();
    cause.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final refs = items(widget.entry, 'source_refs');
    if (prompt.text.trim().isEmpty ||
        answer.text.trim().isEmpty ||
        explanation.text.trim().isEmpty ||
        concept == null ||
        selectedRefs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写题目、标准答案、解析，选择知识点及 1–20 个相关来源。')),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await api.post(
        '/courses/${widget.courseId}/mistakes/${val(widget.entry['id'])}/confirm',
        {
          'question': {
            'kind': kind,
            'prompt': prompt.text.trim(),
            'answer': answer.text.trim(),
            'explanation': explanation.text.trim(),
            'concept_ids': [concept],
            'source_refs': [for (final i in selectedRefs) refs[i]],
            if (kind == 'short_answer') 'rubric': [explanation.text.trim()],
          },
          'error_cause': cause.text.trim().isEmpty ? '待诊断' : cause.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final concepts = items(widget.entry, 'available_concepts');
    final refs = items(widget.entry, 'source_refs');
    return Scaffold(
      appBar: AppBar(title: const Text('校对错题')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ReadingText(
            '学习者原始作答：${val(widget.entry['original_answer'])}',
            selectable: true,
          ),
          const Text('请对照原资料核对题目、答案和解析；确认后不能覆盖原题。'),
          FutureBuilder<http.Response>(
            future: original,
            builder: (context, snapshot) {
              if (snapshot.hasError ||
                  (snapshot.hasData && snapshot.data!.statusCode != 200)) {
                return const Text('无法加载原图，请检查网络和审核权限后重新打开。');
              }
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              return SizedBox(
                height: 260,
                child: InteractiveViewer(
                  child: Image.memory(
                    snapshot.data!.bodyBytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Text('原文件不是可直接显示的图片，请通过管理员查看原件。'),
                  ),
                ),
              );
            },
          ),
          TextField(
            controller: prompt,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '完整题目'),
          ),
          DropdownButtonFormField<String>(
            initialValue: concept,
            decoration: const InputDecoration(labelText: '知识点'),
            items: concepts
                .map<DropdownMenuItem<String>>(
                  (c) => DropdownMenuItem(
                    value: val(c['id']),
                    child: Text(
                      val(c['title']),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => concept = value),
          ),
          if (concepts.isEmpty) const Text('学习者需要先从资料提取知识点。'),
          const SizedBox(height: 12),
          const Text('选择与本题有关的来源片段（1–20 项）：'),
          if (refs.isEmpty) const Text('原资料没有可引用文字，请学习者更换清晰原图或校对资料后重新上传。'),
          for (var i = 0; i < refs.length; i++)
            CheckboxListTile(
              value: selectedRefs.contains(i),
              title: Text(
                '第 ${val(refs[i]['page'])} 页 · ${val(refs[i]['quote'])}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              onChanged: (value) => setState(() {
                if (value == true && selectedRefs.length < 20)
                  selectedRefs.add(i);
                if (value == false) selectedRefs.remove(i);
              }),
            ),
          DropdownButtonFormField<String>(
            initialValue: kind,
            decoration: const InputDecoration(labelText: '题型'),
            items: const [
              DropdownMenuItem(value: 'cloze', child: Text('填空题')),
              DropdownMenuItem(value: 'numeric', child: Text('数值题')),
              DropdownMenuItem(value: 'short_answer', child: Text('简答题')),
            ],
            onChanged: (value) => setState(() => kind = value ?? 'cloze'),
          ),
          TextField(
            controller: answer,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '标准答案'),
          ),
          TextField(
            controller: explanation,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '解析与评分要点'),
          ),
          TextField(
            controller: cause,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '错因（可选）'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? '提交中…' : '确认校对'),
          ),
        ],
      ),
    );
  }
}

class AttemptReviewPage extends StatefulWidget {
  final String courseId;
  final dynamic entry;
  const AttemptReviewPage({
    super.key,
    required this.courseId,
    required this.entry,
  });
  @override
  State<AttemptReviewPage> createState() => _AttemptReviewPageState();
}

class _AttemptReviewPageState extends State<AttemptReviewPage> {
  final score = TextEditingController();
  final rationale = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    score.dispose();
    rationale.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final number = double.tryParse(score.text.trim());
    if (number == null ||
        !number.isFinite ||
        number < 0 ||
        number > 1 ||
        rationale.text.trim().length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分数应在 0 到 1 之间，评分理由至少 10 个字。')),
      );
      return;
    }
    setState(() => busy = true);
    try {
      await api.post(
        '/courses/${widget.courseId}/attempts/${val(widget.entry['id'])}/grade',
        {'score': number, 'rationale': rationale.text.trim()},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.entry['question'];
    return Scaffold(
      appBar: AppBar(title: const Text('审核主观作答')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ReadingText('题目：${val(question?['prompt'])}', selectable: true),
          ReadingText(
            '学习者作答：${val(widget.entry['submitted_answer'])}',
            selectable: true,
          ),
          ReadingText('参考答案：${val(question?['answer'])}', selectable: true),
          ReadingText(
            '评分要点：${(question?['rubric'] as List? ?? []).join('；')}',
            selectable: true,
          ),
          TextField(
            controller: score,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '得分（0–1）'),
          ),
          TextField(
            controller: rationale,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '评分理由（至少 10 个字）'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? '提交中…' : '确认评分'),
          ),
        ],
      ),
    );
  }
}
