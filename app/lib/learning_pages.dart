part of 'main.dart';

Future<dynamic> waitJob(String id) async {
  for (var i = 0; i < 240; i++) {
    final job = await api.get('/jobs/$id');
    if (job['status'] == 'succeeded') return job['result_ref'];
    if (job['status'] == 'failed')
      throw Exception(job['error_message'] ?? '处理失败，请查看任务并重试');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw Exception('处理仍在进行，可在处理进度页面继续查看');
}

Future<int> syncLearning(String courseId) async {
  var points = 0;
  for (var i = 0; i < 100; i++) {
    final page = await api.post('/rewards/consume-events', {
      'course_id': courseId,
    });
    for (final award in items(page, 'awarded')) {
      points += (award['points'] as num).toInt();
    }
    if (page['has_more'] != true) return points;
  }
  throw Exception('成果较多，请稍后继续同步');
}

class PracticePage extends StatefulWidget {
  final String courseId, questionId;
  final String? taskId, reviewId, examId;
  const PracticePage({
    super.key,
    required this.courseId,
    required this.questionId,
    this.taskId,
    this.reviewId,
    this.examId,
  });
  @override
  State<PracticePage> createState() => _PracticeState();
}

class _PracticeState extends State<PracticePage> {
  final answer = TextEditingController();
  dynamic question, session, result;
  String? error, hint;
  bool busy = false;
  int hintLevel = 0, earned = 0;
  bool reviewRated = false;
  late final String submissionKey = api.commandKey();
  String get prefix => '/courses/${widget.courseId}';
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final q = await api.get('$prefix/questions/${widget.questionId}');
      final s = await api.post(
        '$prefix/questions/${widget.questionId}/sessions',
      );
      if (mounted)
        setState(() {
          question = q;
          session = s;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> submit() async {
    if (answer.text.trim().isEmpty || busy) return;
    setState(() => busy = true);
    try {
      final value = await api.request('POST', '$prefix/attempts', {
        'question_id': widget.questionId,
        'answer': answer.text,
        'practice_session_id': session['id'],
        if (widget.taskId != null) 'source_task_id': widget.taskId,
        if (widget.reviewId != null) 'review_id': widget.reviewId,
        if (widget.examId != null) 'exam_id': widget.examId,
      }, submissionKey);
      if (mounted) setState(() => result = value);
      await finishReview(value);
      final points = await syncLearning(widget.courseId);
      if (mounted) setState(() => earned = points);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finishReview(dynamic value) async {
    if (!reviewRated &&
        widget.reviewId != null &&
        value['status'] == 'graded') {
      final quality =
          value['score'] == 1 &&
              value['solution_viewed'] != true &&
              value['recent_repeat'] != true
          ? (hintLevel > 0 ? 3 : 5)
          : 2;
      await api.post('$prefix/reviews/${widget.reviewId}/rate', {
        'attempt_id': value['attempt_id'],
        'quality': quality,
      });
      reviewRated = true;
    }
  }

  Future<void> requestHint(bool solution) async {
    setState(() => busy = true);
    try {
      final next = hintLevel < 3 ? hintLevel + 1 : 3;
      final r = await api.post('$prefix/tutoring/ask', {
        'question': '请给出本题的${solution ? '完整解析' : '提示'}',
        'mode': solution ? 'solution' : 'hint',
        'question_id': widget.questionId,
        'practice_session_id': session['id'],
        'hint_level': next,
      });
      if (mounted)
        setState(() {
          hint = val(r['answer']);
          hintLevel = next;
        });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.reviewId == null ? '独立练习' : '间隔复习')),
    body: error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: load, child: const Text('重试')),
              ],
            ),
          )
        : question == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ReadingText(
                val(question['prompt']),
                key: const Key('practice-prompt'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if ((question['options'] as Map?)?.isNotEmpty == true)
                ...(question['options'] as Map).entries.map(
                  (e) => ListTile(title: Text('${e.key}. ${e.value}')),
                ),
              const SizedBox(height: 20),
              TextField(
                key: const Key('practice-answer'),
                controller: answer,
                enabled: !busy && result == null,
                decoration: const InputDecoration(
                  labelText: '你的答案',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 16),
              if (result == null)
                FilledButton(
                  key: const Key('submit-practice'),
                  onPressed: busy ? null : submit,
                  child: Text(busy ? '正在判分…' : '提交答案'),
                ),
              if (result == null)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => requestHint(false),
                      child: const Text('逐级提示'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              final yes = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('查看完整解析'),
                                  content: const Text(
                                    '本次及短期重复作答将不计独立掌握证据或练习积分。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: const Text('继续思考'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('查看解析'),
                                    ),
                                  ],
                                ),
                              );
                              if (yes == true && mounted)
                                await requestHint(true);
                            },
                      child: const Text('完整解析'),
                    ),
                  ],
                ),
              if (hint != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(hint!),
                  ),
                ),
              if (result != null)
                Card(
                  key: const Key('practice-result'),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result['status'] == 'pending_review'
                              ? '待人工审核'
                              : '得分：${((result['score'] as num? ?? 0) * 100).round()} / 100',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(val(result['grading_rationale'])),
                        Text('本次同步获得 $earned 积分'),
                        if (result['evidence_weight'] == 0)
                          const Text('已保存作答；本次不增加独立掌握证据。'),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  try {
                                    await finishReview(result);
                                    final p = await syncLearning(
                                      widget.courseId,
                                    );
                                    if (mounted) setState(() => earned += p);
                                  } catch (e) {
                                    if (mounted) showError(context, e);
                                  }
                                },
                          child: const Text('重新同步成果'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const Text('提示使用、重复作答与看解析的记录由服务端核验。任务与积分按真实证据结算。'),
            ],
          ),
  );
}

Future<void> openTask(BuildContext context, dynamic task) async {
  final course = val(task['course_id']), target = val(task['target_id']);
  Widget page;
  switch (task['type']) {
    case 'practice':
      page = PracticePage(
        courseId: course,
        questionId: target,
        taskId: val(task['task_id']),
      );
    case 'review':
      final review = await api.get('/courses/$course/reviews/$target');
      page = PracticePage(
        courseId: course,
        questionId: val(review['question_id']),
        taskId: val(task['task_id']),
        reviewId: target,
      );
    case 'lesson':
      page = LessonPlayerPage(
        lessonId: target,
        courseId: course,
        taskId: val(task['task_id']),
      );
    case 'exam':
      page = NativeExamPage(
        courseId: course,
        examId: target,
        taskId: val(task['task_id']),
      );
    case 'mistake':
      page = MistakePage(
        courseId: course,
        mistakeId: target,
        taskId: val(task['task_id']),
      );
    case 'qa':
      page = AskPage(courseId: course);
    default:
      throw Exception('无法识别的任务类型');
  }
  if (context.mounted)
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

class LessonPlayerPage extends StatefulWidget {
  final String lessonId, courseId;
  final String? taskId;
  const LessonPlayerPage({
    super.key,
    required this.lessonId,
    required this.courseId,
    this.taskId,
  });
  @override
  State<LessonPlayerPage> createState() => _LessonPlayerState();
}

class _LessonPlayerState extends State<LessonPlayerPage> {
  dynamic lesson;
  String? error;
  int pageIndex = 0, segment = 0, playVersion = 0;
  bool speaking = false;
  final tts = FlutterTts();
  String get path => '/courses/${widget.courseId}/lessons/${widget.lessonId}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final l = await api.get(path);
      final position = await api.get('$path/position');
      final pages = l['pages'] as List;
      var index = position == null
          ? -1
          : pages.indexWhere((p) => p['page_id'] == position['page_id']);
      if (index < 0) index = 0;
      if (mounted)
        setState(() {
          lesson = l;
          pageIndex = index;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> save() async {
    if (lesson == null) return;
    final p = lesson['pages'][pageIndex];
    final segments = p['narration_segments'] as List;
    if (segments.isEmpty) return;
    final current = segment.clamp(0, segments.length - 1);
    await api.request('PUT', '$path/position', {
      'page_id': p['page_id'],
      'segment_id': segments[current]['segment_id'],
      'offset_seconds': 0,
      if (widget.taskId != null) 'source_task_id': widget.taskId,
    });
  }

  Future<void> stop() async {
    playVersion++;
    final version = playVersion;
    try {
      await tts.stop();
    } catch (_) {
      /* 阅读与翻页不依赖设备语音服务。 */
    }
    if (mounted && version == playVersion) setState(() => speaking = false);
  }

  Future<void> speak() async {
    await stop();
    final version = playVersion;
    try {
      await tts.setSpeechRate(.45);
      await tts.awaitSpeakCompletion(true);
      final segments = lesson['pages'][pageIndex]['narration_segments'] as List;
      for (
        var i = 0;
        i < segments.length && version == playVersion && mounted;
        i++
      ) {
        setState(() {
          segment = i;
          speaking = true;
        });
        await save();
        final content = val(segments[i]['text']);
        await tts.setLanguage(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(content) ? 'zh-CN' : 'en-US',
        );
        final status = await tts.speak(content);
        if (status != 1) throw Exception('当前设备无可用朗读引擎，请先阅读文字讲解');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && version == playVersion) setState(() => speaking = false);
    }
  }

  Future<void> turn(int offset) async {
    unawaited(stop());
    if (!mounted) return;
    setState(() {
      pageIndex += offset;
      segment = 0;
    });
    try {
      await save();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  void dispose() {
    playVersion++;
    tts.stop().catchError((_) => 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null)
      return Scaffold(
        appBar: AppBar(title: const Text('课程讲解')),
        body: Center(child: Text(error!)),
      );
    if (lesson == null)
      return Scaffold(
        appBar: AppBar(title: const Text('课程讲解')),
        body: const Center(child: CircularProgressIndicator()),
      );
    final pages = lesson['pages'] as List, p = pages[pageIndex];
    final segments = p['narration_segments'] as List;
    final highlights = speaking && segments.isNotEmpty
        ? (segments[segment]['highlight_element_ids'] as List? ?? [])
        : [];
    return Scaffold(
      appBar: AppBar(title: Text(val(lesson['title']))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '第 ${pageIndex + 1} / ${pages.length} 页',
            key: const Key('lesson-position'),
          ),
          if ((lesson['generation_warnings'] as List?)?.isNotEmpty == true)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('随堂练习生成提示'),
                    ...(lesson['generation_warnings'] as List).map(
                      (warning) => Text(val(warning['message'])),
                    ),
                  ],
                ),
              ),
            ),
          Text(
            val(p['title']),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          ...(p['elements'] as List).map(
            (e) => Card(
              color: highlights.contains(e['element_id'])
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: ReadingText(
                  val(e['text']),
                  selectable: true,
                  rich: RegExp(
                    r'\\\(.+?\\\)|\\\[.+?\\\]|\$\$.+?\$\$',
                    dotAll: true,
                  ).hasMatch(val(e['text'])),
                ),
              ),
            ),
          ),
          ...segments.map(
            (s) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('讲解：${val(s['text'])}'),
            ),
          ),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: pageIndex > 0 ? () => turn(-1) : null,
                child: const Text('上一页'),
              ),
              FilledButton.icon(
                onPressed: speaking ? stop : speak,
                icon: Icon(speaking ? Icons.stop : Icons.volume_up),
                label: Text(speaking ? '停止朗读' : '朗读本页'),
              ),
              OutlinedButton(
                onPressed: pageIndex < pages.length - 1 ? () => turn(1) : null,
                child: const Text('下一页'),
              ),
            ],
          ),
          const Text('朗读使用 Android 设备的语音引擎；设备缺少语音包时可继续阅读。页面与分段位置保存到后端。'),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QuizPage(
                  lessonId: widget.lessonId,
                  courseId: widget.courseId,
                ),
              ),
            ),
            child: const Text('开始随堂练习'),
          ),
        ],
      ),
    );
  }
}

class NativeImportPage extends StatefulWidget {
  final String courseId;
  final bool mistake;
  const NativeImportPage({
    super.key,
    required this.courseId,
    required this.mistake,
  });
  @override
  State<NativeImportPage> createState() => _NativeImportState();
}

class _NativeImportState extends State<NativeImportPage> {
  PlatformFile? selected;
  bool busy = false;
  String? jobId, notice;
  final originalAnswer = TextEditingController();
  @override
  void dispose() {
    originalAnswer.dispose();
    super.dispose();
  }

  Future<void> choose() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: widget.mistake
          ? ['png', 'jpg', 'jpeg', 'webp']
          : ['pdf', 'pptx', 'png', 'jpg', 'jpeg', 'webp', 'txt', 'md'],
      withData: true,
    );
    if (r == null || !mounted) return;
    if (r.files.single.size > 20 * 1024 * 1024) {
      showError(context, '文件不能超过20MB');
      return;
    }
    setState(() {
      selected = r.files.single;
      notice = null;
      jobId = null;
    });
  }

  Future<void> submit() async {
    if (selected == null || busy) return;
    setState(() => busy = true);
    try {
      final r = await uploadFile(
        '/materials',
        'file',
        selected!,
        widget.courseId,
      );
      if (!mounted) return;
      setState(() {
        jobId = val(r['job_id']);
        notice = '已上传，正在解析原文…';
      });
      await waitJob(jobId!);
      if (widget.mistake) {
        final m = await api.post(
          '/courses/${widget.courseId}/mistakes/capture',
          {
            'material_id': r['material_id'],
            'original_answer': originalAnswer.text,
          },
        );
        if (mounted)
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MistakePage(
                courseId: widget.courseId,
                mistakeId: val(m['id']),
              ),
            ),
          );
      } else {
        if (mounted) {
          final extracted = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
              builder: (_) => MaterialReviewPage(
                courseId: widget.courseId,
                materialId: val(r['material_id']),
              ),
            ),
          );
          if (mounted)
            setState(
              () => notice = extracted == true
                  ? '资料已确认并提取知识点。'
                  : '资料已解析，可从“校对已上传资料”继续处理。',
            );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => notice = e.toString());
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.mistake ? '上传错题' : '导入资料')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.verified_outlined),
            title: Text('已连接真实资料处理服务'),
            subtitle: Text('上传后解析原文并保留来源。图片会执行 OCR，识别结果可以校对。'),
          ),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : choose,
          icon: const Icon(Icons.attach_file),
          label: Text(selected?.name ?? '选择文件'),
        ),
        if (widget.mistake)
          TextField(
            controller: originalAnswer,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '你当时的原始答案（保留不覆盖）'),
          ),
        FilledButton(
          onPressed: busy || selected == null ? null : submit,
          child: Text(busy ? '处理中…' : '上传并解析'),
        ),
        if (notice != null) SelectableText(notice!),
        if (!widget.mistake)
          TextButton.icon(
            onPressed: busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          MaterialReviewListPage(courseId: widget.courseId),
                    ),
                  ),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('校对已上传资料'),
          ),
        if (jobId != null)
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => JobPage(jobId: jobId!)),
            ),
            child: const Text('查看处理进度'),
          ),
      ],
    ),
  );
}

class MistakePage extends StatefulWidget {
  final String courseId, mistakeId;
  final String? taskId;
  const MistakePage({
    super.key,
    required this.courseId,
    required this.mistakeId,
    this.taskId,
  });
  @override
  State<MistakePage> createState() => _MistakeState();
}

class _MistakeState extends State<MistakePage> {
  dynamic mistake, explanation;
  String? error;
  bool busy = false;
  String get prefix =>
      '/courses/${widget.courseId}/mistakes/${widget.mistakeId}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final m = await api.get('/mistakes/${widget.mistakeId}');
      if (mounted)
        setState(() {
          mistake = m;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> variants() async {
    setState(() => busy = true);
    try {
      final j = await api.post('$prefix/variants', {
        'count': 2,
        'seed': DateTime.now().millisecondsSinceEpoch % 2147483647,
      });
      await waitJob(val(j['job_id']));
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('错题与变式')),
    body: error != null
        ? Center(child: Text(error!))
        : mistake == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                val(
                  mistake['corrected_question'] ??
                      mistake['recognized_question'],
                ),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text('原始作答：${val(mistake['original_answer'])}'),
              Text('状态：${val(mistake['status'])}'),
              if (mistake['status'] == 'needs_confirmation') ...[
                const Text('识别内容需要校对；学习者提交转写后仍需内容审核，不会自动生成判分答案。'),
                FilledButton.tonal(
                  onPressed: () async {
                    final text = await inputDialog(
                      context,
                      '校对题目',
                      '完整题目',
                      initial: val(
                        mistake['corrected_question'] ??
                            mistake['recognized_question'],
                      ),
                    );
                    if (text == null) return;
                    try {
                      await api.request('PATCH', '$prefix/transcription', {
                        'text': text,
                      });
                      await load();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('校对识别文字'),
                ),
              ] else ...[
                FilledButton(
                  onPressed: busy ? null : variants,
                  child: Text(busy ? '正在生成…' : '生成两道变式'),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      final e = await api.get('$prefix/explanation');
                      if (mounted) setState(() => explanation = e);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('查看分步讲解（记录为已看解析）'),
                ),
              ],
              if (explanation != null)
                ...items(
                  explanation,
                  'steps',
                ).map((s) => ListTile(title: Text(val(s['text'])))),
              ...items(mistake, 'variants').map(
                (q) => Card(
                  child: ListTile(
                    title: Text(val(q['prompt'])),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PracticePage(
                          courseId: widget.courseId,
                          questionId: val(q['id']),
                          taskId: widget.taskId,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}

class MaterialReviewListPage extends StatelessWidget {
  final String courseId;
  const MaterialReviewListPage({super.key, required this.courseId});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('选择资料校对')),
    body: RemoteView(
      load: () => api.get('/courses/$courseId/materials'),
      builder: (data, reload) {
        final materials = items(data);
        if (materials.isEmpty) return const Center(child: Text('暂无资料'));
        return ListView(
          children: materials
              .map(
                (m) => ListTile(
                  title: Text(val(m['filename'], '资料')),
                  subtitle: Text('状态：${val(m['status'])}'),
                  enabled: m['status'] == 'ready',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MaterialReviewPage(
                        courseId: courseId,
                        materialId: val(m['id']),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        );
      },
    ),
  );
}

class MaterialReviewPage extends StatefulWidget {
  final String courseId, materialId;
  const MaterialReviewPage({
    super.key,
    required this.courseId,
    required this.materialId,
  });
  @override
  State<MaterialReviewPage> createState() => _MaterialReviewState();
}

class _MaterialReviewState extends State<MaterialReviewPage> {
  dynamic material;
  String? error;
  bool busy = false;
  String get path =>
      '/courses/${widget.courseId}/materials/${widget.materialId}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await api.get(path);
      if (mounted)
        setState(() {
          material = value;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> edit(dynamic chunk) async {
    final changed = await showDialog<String>(
      context: context,
      builder: (_) => MaterialEditDialog(
        text: val(chunk['text']),
        page: val(chunk['page']),
      ),
    );
    if (changed == null || !mounted) return;
    if (changed.trim().isEmpty) {
      showError(context, '校对内容不能为空');
      return;
    }
    setState(() => busy = true);
    try {
      final updated = await api.request('PATCH', '$path/chunks', {
        'chunk_id': chunk['chunk_id'],
        'text': changed,
      });
      if (mounted) setState(() => material = updated);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    setState(() => busy = true);
    try {
      await api.post('/courses/${widget.courseId}/knowledge/extract', {
        'material_ids': [widget.materialId],
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('校对资料')),
    body: material == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!),
                      TextButton(onPressed: load, child: const Text('重试')),
                    ],
                  ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('请核对解析文字；引用后不能再修改原文，如需修订请重新上传版本。'),
              if (items(material, 'chunks').isEmpty)
                const Text('未提取到文字，暂不能提取知识点。'),
              ...items(material, 'chunks').map(
                (chunk) => Card(
                  child: ListTile(
                    title: Text(
                      '第 ${val(chunk['page'])} 页${chunk['needs_confirmation'] == true ? ' · OCR 待校对' : ''}',
                    ),
                    subtitle: Text(val(chunk['text'])),
                    trailing: TextButton(
                      onPressed: busy ? null : () => edit(chunk),
                      child: const Text('校对'),
                    ),
                  ),
                ),
              ),
              FilledButton(
                onPressed: busy || items(material, 'chunks').isEmpty
                    ? null
                    : confirm,
                child: Text(busy ? '处理中…' : '确认文字并提取知识点'),
              ),
            ],
          ),
  );
}

class MaterialEditDialog extends StatefulWidget {
  final String text, page;
  const MaterialEditDialog({super.key, required this.text, required this.page});
  @override
  State<MaterialEditDialog> createState() => _MaterialEditDialogState();
}

class _MaterialEditDialogState extends State<MaterialEditDialog> {
  late final controller = TextEditingController(text: widget.text);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('校对第 ${widget.page} 页'),
    content: TextField(
      controller: controller,
      minLines: 5,
      maxLines: 12,
      maxLength: 12000,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('保存校对'),
      ),
    ],
  );
}

class NativeExamPage extends StatefulWidget {
  final String courseId;
  final String? materialId, examId, taskId;
  const NativeExamPage({
    super.key,
    required this.courseId,
    this.materialId,
    this.examId,
    this.taskId,
  });
  @override
  State<NativeExamPage> createState() => _NativeExamState();
}

class _NativeExamState extends State<NativeExamPage> {
  List<dynamic>? concepts;
  String? examId, error, jobId;
  dynamic analysis;
  final slots = <Map<String, dynamic>>[];
  bool busy = false;
  dynamic exam, summary;
  final answers = <String, String>{}, sessions = <String, String>{};
  final submitted = <String>{};
  late final String submissionKey = api.commandKey();
  String get prefix => '/courses/${widget.courseId}';
  @override
  void initState() {
    super.initState();
    examId = widget.examId;
    load();
  }

  String suggestedKind(dynamic concept) =>
      RegExp(
        r'Accuracy|Recall|Precision|准确率|召回率|精确率|Euclidean|欧氏距离|算术平均|一元一次',
        caseSensitive: false,
      ).hasMatch(val(concept['title']))
      ? 'numeric'
      : 'cloze';
  Future<void> load() async {
    try {
      final g = await api.get('/courses/${widget.courseId}/knowledge');
      final draft = widget.materialId == null
          ? null
          : await api.post('$prefix/exams/analyze', {
              'material_id': widget.materialId,
            });
      if (!mounted) return;
      setState(() {
        concepts = items(g, 'nodes');
        analysis = draft;
        final validIds = concepts!.map((c) => val(c['id'])).toSet();
        final suggested = draft == null
            ? <dynamic>[]
            : items(draft, 'suggested_slots');
        slots.clear();
        for (final slot in suggested) {
          if (validIds.contains(val(slot['concept_id']))) {
            slots.add({
              'concept_id': val(slot['concept_id']),
              'kind': slot['kind'] == 'numeric' ? 'numeric' : 'cloze',
              'difficulty':
                  ['easy', 'medium', 'hard'].contains(slot['difficulty'])
                  ? slot['difficulty']
                  : 'medium',
              'count': (slot['count'] as num?)?.toInt() ?? 1,
              'points': (slot['points'] as num?)?.toDouble() ?? 10.0,
            });
          }
        }
        if (slots.isEmpty && concepts!.isNotEmpty) {
          slots.add({
            'concept_id': val(concepts!.first['id']),
            'kind': suggestedKind(concepts!.first),
            'difficulty': 'medium',
            'count': 1,
            'points': 10.0,
          });
        }
        error = null;
      });
      if (examId != null) await loadExam();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> loadExam() async {
    final e = await api.get('$prefix/exams/$examId');
    for (final q in items(e, 'questions')) {
      final qid = val(q['id']);
      if (!sessions.containsKey(qid)) {
        final s = await api.post('$prefix/questions/$qid/sessions');
        sessions[qid] = val(s['id']);
      }
    }
    if (mounted) setState(() => exam = e);
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> generate() async {
    if (slots.isEmpty ||
        slots.length > 20 ||
        slots.fold<int>(0, (sum, s) => sum + (s['count'] as int)) > 50 ||
        slots.any((s) => (s['count'] as int) < 1 || (s['count'] as int) > 20)) {
      throw Exception('请设置 1 至 20 组题目，每组 1 至 20 题，总数不超过 50 题。');
    }
    final bp = await api.post('$prefix/exam-blueprints', {
      'title': widget.materialId == null ? '知识点练习卷' : '原卷分析练习卷',
      'duration_minutes': 20,
      'slots': slots,
    });
    final j = await api.post('$prefix/exams', {
      'blueprint_id': bp['id'],
      'seed': DateTime.now().millisecondsSinceEpoch % 2147483647,
    });
    if (mounted) setState(() => jobId = val(j['job_id']));
    final r = await waitJob(val(j['job_id']));
    examId = val(r['id']);
    await loadExam();
  }

  Future<void> submit() async {
    final questions = items(exam, 'questions');
    if (questions.any((q) => (answers[val(q['id'])] ?? '').trim().isEmpty))
      throw Exception('请先完成所有题目');
    for (final q in questions) {
      final qid = val(q['id']);
      await api.request('POST', '$prefix/attempts', {
        'question_id': qid,
        'answer': answers[qid],
        'practice_session_id': sessions[qid],
        'exam_id': examId,
        if (widget.taskId != null) 'source_task_id': widget.taskId,
      }, '$submissionKey-$qid');
      submitted.add(qid);
    }
    await syncLearning(widget.courseId);
    final r = await api.get('$prefix/exams/$examId/results');
    if (mounted) setState(() => summary = r);
  }

  Future<void> download() async {
    final response = await api.client
        .get(
          api.uri('$prefix/exams/$examId/paper'),
          headers: {'Authorization': 'Bearer ${api.token}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 ||
        !utf8
            .decode(response.bodyBytes.take(4).toList(), allowMalformed: true)
            .startsWith('%PDF'))
      throw Exception('试卷下载失败');
    await FilePicker.platform.saveFile(
      dialogTitle: '保存试卷 PDF',
      fileName: 'zhi-study-paper.pdf',
      bytes: Uint8List.fromList(response.bodyBytes),
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('仿真试卷')),
    body: concepts == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Text(error!),
          )
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.fact_check_outlined),
                  title: Text('使用真实学习引擎'),
                  subtitle: Text('根据已提取的知识点生成题目。计算题通过数值校验；教材填空引用原文。'),
                ),
              ),
              if (exam == null) ...[
                if (analysis != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '原卷分析草稿',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '识别到 ${items(analysis, 'parsed_questions').length} 道编号题；知识点按题干中的名称匹配，题型和分值为默认建议，请核对。',
                          ),
                          ...items(
                            analysis,
                            'warnings',
                          ).map((w) => Text(val(w))),
                          if (items(analysis, 'suggested_slots').isEmpty)
                            const Text('未匹配到知识点，请手动配置下方蓝图。'),
                          ...items(analysis, 'parsed_questions').map(
                            (q) => ExpansionTile(
                              title: Text(
                                '第 ${val(q['number'])} 题${(q['concept_ids'] as List?)?.isEmpty == true ? ' · 未匹配知识点' : ''}',
                              ),
                              subtitle: Text(
                                q['points'] == null
                                    ? '原卷分值未识别'
                                    : '原卷分值 ${val(q['points'])}',
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: ReadingText(
                                    val(q['prompt']),
                                    selectable: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const Text('确认或调整出题蓝图'),
                if (concepts!.isEmpty) const Text('还没有知识点，请先导入资料并提取知识点。'),
                ...slots.asMap().entries.map((entry) {
                  final index = entry.key;
                  final slot = entry.value;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'concept-$index-${slot['concept_id']}',
                            ),
                            initialValue: slot['concept_id'] as String,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: '第 ${index + 1} 组知识点',
                            ),
                            items: concepts!
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: val(c['id']),
                                    child: Text(
                                      val(c['title']),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                    slot['concept_id'] = value;
                                  }),
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey('kind-$index-${slot['kind']}'),
                            initialValue: slot['kind'] as String,
                            decoration: const InputDecoration(
                              labelText: '题目类型',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'cloze',
                                child: Text('教材填空'),
                              ),
                              DropdownMenuItem(
                                value: 'numeric',
                                child: Text('可验证计算'),
                              ),
                            ],
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                    slot['kind'] = value;
                                  }),
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'difficulty-$index-${slot['difficulty']}',
                            ),
                            initialValue: slot['difficulty'] as String,
                            decoration: const InputDecoration(labelText: '难度'),
                            items: const [
                              DropdownMenuItem(
                                value: 'easy',
                                child: Text('简单'),
                              ),
                              DropdownMenuItem(
                                value: 'medium',
                                child: Text('中等'),
                              ),
                              DropdownMenuItem(
                                value: 'hard',
                                child: Text('困难'),
                              ),
                            ],
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                    slot['difficulty'] = value;
                                  }),
                          ),
                          Row(
                            children: [
                              const Text('题数'),
                              IconButton(
                                tooltip: '减少题数',
                                onPressed: busy || slot['count'] <= 1
                                    ? null
                                    : () => setState(() {
                                        slot['count']--;
                                      }),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              Text('${slot['count']}'),
                              IconButton(
                                tooltip: '增加题数',
                                onPressed: busy || slot['count'] >= 20
                                    ? null
                                    : () => setState(() {
                                        slot['count']++;
                                      }),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                              const Spacer(),
                              Text('${val(slot['points'])} 分/题'),
                              IconButton(
                                tooltip: '删除该组',
                                onPressed: busy
                                    ? null
                                    : () =>
                                          setState(() => slots.removeAt(index)),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                if (concepts!.isNotEmpty)
                  TextButton.icon(
                    onPressed: busy || slots.length >= 20
                        ? null
                        : () => setState(
                            () => slots.add({
                              'concept_id': val(concepts!.first['id']),
                              'kind': suggestedKind(concepts!.first),
                              'difficulty': 'medium',
                              'count': 1,
                              'points': 10.0,
                            }),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('添加出题组'),
                  ),
                FilledButton(
                  onPressed: busy || slots.isEmpty
                      ? null
                      : () => action(generate),
                  child: Text(busy ? '正在生成…' : '确认蓝图并生成练习卷'),
                ),
                if (jobId != null)
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => JobPage(jobId: jobId!)),
                    ),
                    child: const Text('查看生成进度'),
                  ),
              ] else ...[
                Text(
                  val(exam['title']),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                ...items(exam, 'questions').map(
                  (q) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ReadingText(val(q['prompt'])),
                          if ((q['options'] as Map?)?.isNotEmpty == true)
                            Text(val(q['options'])),
                          TextFormField(
                            key: ValueKey('exam-answer-${q['id']}'),
                            enabled:
                                !busy &&
                                summary == null &&
                                !submitted.contains(val(q['id'])),
                            decoration: const InputDecoration(labelText: '答案'),
                            onChanged: (v) => answers[val(q['id'])] = v,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (summary == null)
                  FilledButton(
                    onPressed: busy ? null : () => action(submit),
                    child: Text(busy ? '正在判卷…' : '提交试卷'),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => action(download),
                  icon: const Icon(Icons.download),
                  label: const Text('保存试卷 PDF'),
                ),
              ],
              if (summary != null)
                Card(
                  child: ListTile(
                    title: Text(
                      '得分 ${val(summary['score'])} / ${val(summary['total_points'])}',
                    ),
                    subtitle: Text(
                      '已批改 ${val(summary['graded_count'])} / ${val(summary['question_count'])} 题，成果已同步。',
                    ),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
            ],
          ),
  );
}

class GenerateLessonPage extends StatefulWidget {
  final String courseId;
  const GenerateLessonPage({super.key, required this.courseId});
  @override
  State<GenerateLessonPage> createState() => _GenerateLessonState();
}

class _GenerateLessonState extends State<GenerateLessonPage> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('生成课程讲解')),
    body: RemoteView(
      load: () => api.get('/courses/${widget.courseId}/knowledge'),
      builder: (data, reload) {
        final nodes = items(data, 'nodes');
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('选择一个知识点，生成有教材来源的小课。'),
            if (nodes.isEmpty) const Text('请先导入资料并提取知识点。'),
            ...nodes.map(
              (n) => Card(
                child: ListTile(
                  title: Text(val(n['title'])),
                  subtitle: Text(
                    val(n['description']),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  onTap: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            final j = await api.post(
                              '/courses/${widget.courseId}/lessons',
                              {
                                'title': val(n['title']),
                                'concept_ids': [n['id']],
                              },
                            );
                            final r = await waitJob(val(j['job_id']));
                            if (context.mounted)
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LessonPlayerPage(
                                    courseId: widget.courseId,
                                    lessonId: val(r['id']),
                                  ),
                                ),
                              );
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class CourseEditorPage extends StatefulWidget {
  final String? courseId;
  const CourseEditorPage({super.key, this.courseId});
  @override
  State<CourseEditorPage> createState() => _CourseEditorState();
}

class _CourseEditorState extends State<CourseEditorPage> {
  final title = TextEditingController(),
      goal = TextEditingController(),
      start = TextEditingController(text: '18:00'),
      end = TextEditingController(text: '23:00');
  DateTime deadline = DateTime.now().add(const Duration(days: 14));
  final weekdays = <int>{1, 2, 3, 4, 5, 6, 7};
  bool busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.courseId != null) load();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final c = await api.get('/courses/${widget.courseId}');
      if (!mounted) return;
      title.text = val(c['title']);
      goal.text = val(c['goal_text']);
      final slots = items(c, 'available_slots');
      if (slots.isNotEmpty) {
        start.text = val(slots.first['start']);
        end.text = val(slots.first['end']);
        weekdays
          ..clear()
          ..addAll(slots.map((s) => (s['weekday'] as num).toInt()));
      }
      if (c['ddl'] != null) deadline = DateTime.parse(c['ddl']);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    title.dispose();
    goal.dispose();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final hm = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
    if (title.text.trim().isEmpty ||
        !hm.hasMatch(start.text) ||
        !hm.hasMatch(end.text) ||
        start.text.compareTo(end.text) >= 0 ||
        weekdays.isEmpty) {
      showError(context, '请填写课程名称、有效时段（HH:mm）与可用星期');
      return;
    }
    setState(() => busy = true);
    try {
      await api.request(
        widget.courseId == null ? 'POST' : 'PATCH',
        widget.courseId == null ? '/courses' : '/courses/${widget.courseId}',
        {
          'title': title.text.trim(),
          'goal_text': goal.text,
          'ddl': date(deadline),
          'available_slots': weekdays
              .map((d) => {'weekday': d, 'start': start.text, 'end': end.text})
              .toList(),
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.courseId == null ? '创建课程' : '课程目标与时段')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: title,
          decoration: const InputDecoration(labelText: '课程名称'),
        ),
        TextField(
          controller: goal,
          decoration: const InputDecoration(labelText: '学习目标'),
        ),
        ListTile(
          title: Text('截止日期：${date(deadline)}'),
          trailing: const Icon(Icons.calendar_today),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: deadline,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (d != null && mounted) setState(() => deadline = d);
          },
        ),
        Wrap(
          spacing: 6,
          children: List.generate(
            7,
            (i) => FilterChip(
              label: Text('周${['一', '二', '三', '四', '五', '六', '日'][i]}'),
              selected: weekdays.contains(i + 1),
              onSelected: (yes) => setState(
                () => yes ? weekdays.add(i + 1) : weekdays.remove(i + 1),
              ),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: start,
                decoration: const InputDecoration(labelText: '开始时间 HH:mm'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: end,
                decoration: const InputDecoration(labelText: '结束时间 HH:mm'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '正在保存…' : '保存课程'),
        ),
        if (widget.courseId != null)
          const Text('修改 DDL 或可用时段后，未完成且未固定的任务会重新安排。已完成证据与固定任务保留。'),
      ],
    ),
  );
}
