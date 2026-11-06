import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

const base = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://10.0.2.2:8000',
);
final api = Api();

void main() => runApp(const ZhiApp());

class Api {
  String? token;
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('$base/api/v1$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final response = await (method == 'GET'
            ? http.get(uri, headers: headers)
            : method == 'PATCH'
                ? http.patch(
                    uri,
                    headers: headers,
                    body: jsonEncode(body ?? {}),
                  )
                : http.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body ?? {}),
                  ))
        .timeout(const Duration(seconds: 20));
    dynamic data;
    try {
      data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw Exception('服务器返回无法解析的数据');
    }
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw Exception(
        data is Map
            ? (data['message'] ?? '请求失败 (${response.statusCode})')
            : '请求失败 (${response.statusCode})',
      );
    return data;
  }

  Future<dynamic> get(String path) => request('GET', path);
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      request('POST', path, body);
}

class ZhiApp extends StatelessWidget {
  const ZhiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '啄知 AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff557b60)),
        ),
        home: const LoginPage(),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  bool register = false;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      showError(context, '请填写账号和密码');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await api.post(
        '/auth/${register ? 'register' : 'login'}',
        {'username': username.text.trim(), 'password': password.text},
      );
      api.token = result['access_token'] as String;
      if (mounted)
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.auto_stories_rounded,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '啄知 AI',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('让每一步学习都有迹可循', textAlign: TextAlign.center),
                    const SizedBox(height: 32),
                    TextField(
                      controller: username,
                      decoration: const InputDecoration(
                        labelText: '账号',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(
                        busy
                            ? '正在连接…'
                            : register
                                ? '注册'
                                : '登录',
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => register = !register),
                      child: Text(register ? '已有账号？登录' : '创建账号'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
    );
String date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
List<dynamic> items(dynamic data, [String key = 'items']) =>
    data is Map && data[key] is List ? data[key] as List : [];
String val(dynamic x, [String fallback = '']) =>
    x == null ? fallback : x.toString();

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> {
  int tab = 0;
  String? courseId;
  String courseTitle = '';
  int version = 0;
  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      PlannerPage(key: ValueKey('p$courseId$version'), courseId: courseId),
      StudyPage(key: ValueKey('s$courseId$version'), courseId: courseId),
      const CompanionPage(),
      ProfilePage(onCoursesChanged: () => setState(() => version++)),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['学习安排', '学习中心', 'AI 伴学', '我的'][tab]),
        actions: [
          TextButton.icon(
            onPressed: chooseCourse,
            icon: const Icon(Icons.school_outlined),
            label: Text(
              courseTitle.isEmpty ? '选择课程' : courseTitle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsPage()),
            ),
            icon: const Icon(Icons.notifications_outlined),
            tooltip: '通知',
          ),
        ],
      ),
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            label: '安排',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: '学习',
          ),
          NavigationDestination(icon: Icon(Icons.pets_outlined), label: '伴学'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }

  Future<void> chooseCourse() async {
    try {
      final courses = items(await api.get('/courses'));
      if (!mounted) return;
      final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('选择课程')),
              if (courses.isEmpty)
                const ListTile(title: Text('还没有课程，请在“我的”中创建')),
              ...courses.map(
                (c) => ListTile(
                  title: Text(val(c['title'])),
                  onTap: () => Navigator.pop(ctx, Map<String, dynamic>.from(c)),
                ),
              ),
            ],
          ),
        ),
      );
      if (selected != null && mounted)
        setState(() {
          courseId = val(selected['course_id']);
          courseTitle = val(selected['title']);
        });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

class RemoteView extends StatefulWidget {
  final Future<dynamic> Function() load;
  final Widget Function(dynamic, VoidCallback) builder;
  const RemoteView({super.key, required this.load, required this.builder});
  @override
  State<RemoteView> createState() => _RemoteState();
}

class _RemoteState extends State<RemoteView> {
  late Future<dynamic> future;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    setState(() => future = widget.load());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done)
            return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError)
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('加载失败：${snapshot.error}'),
                  TextButton(onPressed: reload, child: const Text('重试')),
                ],
              ),
            );
          return widget.builder(snapshot.data, reload);
        },
      );
}

class PlannerPage extends StatelessWidget {
  final String? courseId;
  const PlannerPage({super.key, this.courseId});
  @override
  Widget build(BuildContext context) {
    if (courseId == null) return const Center(child: Text('请先选择课程'));
    final id = courseId!;
    return RemoteView(
      load: () =>
          api.get('/courses/$id/planner/today?date=${date(DateTime.now())}'),
      builder: (data, reload) {
        final tasks = items(data);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '今天 · ${date(DateTime.now())}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    try {
                      await api.post('/courses/$id/planner/auto-generate', {
                        'date': date(DateTime.now()),
                      });
                      reload();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('生成今日安排'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => JsonListPage(
                        title: '推荐任务',
                        path: '/courses/$id/planner/candidates',
                        itemBuilder: (c) => ListTile(
                          title: Text(val(c['title'])),
                          subtitle: Text(val(c['reason'])),
                          trailing: const Icon(Icons.add),
                          onTap: () async {
                            try {
                              await api.post(
                                '/courses/$id/planner/accept-recommendation',
                                {
                                  'candidate_id': c['candidate_id'],
                                  'planned_date': date(DateTime.now()),
                                },
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                                reload();
                              }
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  child: const Text('查看推荐'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    final title = await inputDialog(context, '添加学习任务', '任务名称');
                    if (title == null || !context.mounted) return;
                    final lessonId =
                        await inputDialog(context, '关联课程讲解', '讲解 ID');
                    if (lessonId == null || !context.mounted) return;
                    final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100));
                    if (picked == null || !context.mounted) return;
                    try {
                      await api.post('/courses/$id/planner/tasks', {
                        'title': title,
                        'type': 'lesson',
                        'target_id': lessonId,
                        'planned_date': date(picked)
                      });
                      reload();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('添加讲解任务'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => CalendarPage(courseId: id))),
                  child: const Text('本月日历'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => JsonListPage(
                        title: '完成记录',
                        path:
                            '/courses/$id/planner/completions?month=${date(DateTime.now()).substring(0, 7)}',
                        itemBuilder: (c) => ListTile(
                          title: Text(val(c['title'])),
                          subtitle: Text(val(c['completed_at'])),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('完成记录'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (tasks.isEmpty)
              const Card(
                child: ListTile(
                  title: Text('今天还没有安排'),
                  subtitle: Text('可以生成安排或添加推荐任务。'),
                ),
              ),
            ...tasks.map(
              (t) => Card(
                child: ListTile(
                  onTap: () {
                    if (t['type'] == 'lesson') {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => DetailPage(
                                  title: '课程讲解',
                                  path: '/lessons/${t['target_id']}')));
                    } else if (t['type'] == 'qa') {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => AskPage(courseId: id)));
                    } else if (t['type'] == 'mistake') {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => DetailPage(
                                  title: '错题',
                                  path: '/mistakes/${t['target_id']}')));
                    } else {
                      showError(context, '该类型任务的跳转尚未接入');
                    }
                  },
                  title: Text(val(t['title'])),
                  subtitle: Text(
                    '${val(t['status'])} · ${val(t['reason'], '手动安排')}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      try {
                        if (action == 'complete') {
                          await api.post(
                            '/planner/tasks/${t['task_id']}/complete',
                            {'completion': 'full'},
                          );
                        } else if (action == 'tomorrow') {
                          await api.post(
                            '/planner/tasks/${t['task_id']}/reschedule',
                            {
                              'to_date': date(
                                DateTime.now().add(const Duration(days: 1)),
                              ),
                              'reason': '用户调整',
                            },
                          );
                        } else {
                          await api.post(
                            '/planner/tasks/${t['task_id']}/cancel',
                          );
                        }
                        reload();
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    itemBuilder: (_) => [
                      if (['lesson', 'qa', 'review'].contains(t['type']))
                        const PopupMenuItem(
                          value: 'complete',
                          child: Text('标记完成'),
                        ),
                      const PopupMenuItem(
                        value: 'tomorrow',
                        child: Text('移到明天'),
                      ),
                      const PopupMenuItem(value: 'cancel', child: Text('取消任务')),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class JsonListPage extends StatelessWidget {
  final String title, path;
  final Widget Function(dynamic) itemBuilder;
  const JsonListPage({
    super.key,
    required this.title,
    required this.path,
    required this.itemBuilder,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: RemoteView(
          load: () => api.get(path),
          builder: (data, reload) {
            final list = items(data);
            return RefreshIndicator(
              onRefresh: () async => reload(),
              child: ListView(children: [
                if (data is Map && data['is_demo'] == true) demoNotice(data),
                if (list.isEmpty) const ListTile(title: Text('暂无内容')),
                ...list.map(itemBuilder)
              ]),
            );
          },
        ),
      );
}

class StudyPage extends StatelessWidget {
  final String? courseId;
  const StudyPage({super.key, this.courseId});
  @override
  Widget build(BuildContext context) {
    if (courseId == null) return const Center(child: Text('请先选择课程'));
    final id = courseId!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('学习中心', style: Theme.of(context).textTheme.headlineSmall),
        const Text('浏览课程资料，查看知识图谱并开始练习。'),
        const Card(
            child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('学习内容为演示数据'),
                subtitle: Text('资料、图谱、课程和练习来自乙侧演示接口，尚未接入真实学习服务。'))),
        const SizedBox(height: 16),
        Card(
            child: ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('导入学习资料'),
                subtitle: const Text('选择 PDF、PPTX 或图片上传'),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            UploadPage(courseId: id, mistake: false))))),
        Card(
            child: ListTile(
                leading: const Icon(Icons.add_a_photo_outlined),
                title: const Text('上传错题'),
                subtitle: const Text('选择错题图片并提交识别'),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            UploadPage(courseId: id, mistake: true))))),
        Card(
            child: ListTile(
                leading: const Icon(Icons.assignment_outlined),
                title: const Text('仿真试卷'),
                subtitle: const Text('选择已有资料，导入并生成试卷'),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ExamImportPage(courseId: id))))),
        ...[
          ('资料', Icons.folder_outlined, '/materials?course_id=$id'),
          ('课程讲解', Icons.play_circle_outline, '/lessons?course_id=$id'),
          ('错题本', Icons.edit_note_outlined, '/mistakes?course_id=$id'),
          (
            '待复习',
            Icons.history,
            '/reviews/due?course_id=$id&date=${date(DateTime.now())}',
          ),
        ].map(
          (entry) => Card(
            child: ListTile(
              leading: Icon(entry.$2),
              title: Text(entry.$1),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JsonListPage(
                    title: entry.$1,
                    path: entry.$3,
                    itemBuilder: (item) => ListTile(
                      title: Text(
                        val(
                          item['title'] ??
                              item['recognized_question'] ??
                              item['target_id'],
                          '未命名',
                        ),
                      ),
                      subtitle: Text(val(item['status'] ?? item['due_date'])),
                      onTap: () {
                        final itemId = item['lesson_id'] ??
                            item['material_id'] ??
                            item['mistake_id'];
                        final prefix = item['lesson_id'] != null
                            ? 'lessons'
                            : item['material_id'] != null
                                ? 'materials'
                                : 'mistakes';
                        if (itemId != null)
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailPage(
                                title: entry.$1,
                                path: '/$prefix/$itemId',
                              ),
                            ),
                          );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('知识图谱'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => GraphPage(courseId: id)),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.question_answer_outlined),
            title: const Text('学习问答'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AskPage(courseId: id)),
            ),
          ),
        ),
      ],
    );
  }
}

class DetailPage extends StatelessWidget {
  final String title, path;
  const DetailPage({super.key, required this.title, required this.path});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: RemoteView(
          load: () => api.get(path),
          builder: (data, reload) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (data is Map && data['is_demo'] == true) demoNotice(data),
              Text(
                val(data['title'] ?? data['recognized_question'], title),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (data['pages'] is List)
                ...(data['pages'] as List).map<Widget>(
                  (p) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '第 ${val(p['order'] ?? p['page_no'])} 页',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          ...((p['elements'] ?? p['blocks'] ?? []) as List)
                              .map<Widget>(
                            (e) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(val(e['content'] ?? e['text'])),
                            ),
                          ),
                          ...((p['explanation_segments'] ?? []) as List)
                              .map<Widget>((s) => Text('讲解：${val(s['text'])}')),
                        ],
                      ),
                    ),
                  ),
                ),
              if (data['lesson_id'] != null && data['course_id'] != null)
                FilledButton.tonalIcon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => QuizPage(
                                lessonId: val(data['lesson_id']),
                                courseId: val(data['course_id'])))),
                    icon: const Icon(Icons.quiz_outlined),
                    label: const Text('开始随堂练习')),
              if (data['error_cause'] != null)
                Text('错误原因：${data['error_cause']}'),
              if (data['correct_answer'] != null)
                Text('参考答案：${data['correct_answer']}'),
              ...((data['step_explanations'] ?? []) as List).map<Widget>(
                (s) => ListTile(title: Text(val(s['text']))),
              ),
            ],
          ),
        ),
      );
}

class GraphPage extends StatelessWidget {
  final String courseId;
  const GraphPage({super.key, required this.courseId});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('知识图谱')),
        body: RemoteView(
          load: () => api.get('/courses/$courseId/graph'),
          builder: (data, reload) {
            final nodes = items(data, 'nodes');
            if (nodes.isEmpty) return const Center(child: Text('暂无知识点'));
            return ListView(
              children: [
                if (data is Map && data['is_demo'] == true) demoNotice(data),
                ...nodes
                    .map(
                      (n) => ListTile(
                        title: Text(val(n['name'])),
                        subtitle: Text(
                          '掌握度：${n['mastery'] == null ? '暂无' : '${((n['mastery'] as num) * 100).round()}%'}',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DetailPage(
                              title: '知识点',
                              path: '/graph/nodes/${n['node_id']}',
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList()
              ],
            );
          },
        ),
      );
}

class AskPage extends StatefulWidget {
  final String courseId;
  const AskPage({super.key, required this.courseId});
  @override
  State<AskPage> createState() => _AskState();
}

class _AskState extends State<AskPage> {
  final question = TextEditingController();
  String answer = '';
  bool busy = false;
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('学习问答')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('演示问答，尚未接入教学引擎')),
              TextField(
                controller: question,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '输入你的问题',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (question.text.trim().isEmpty) return;
                        setState(() => busy = true);
                        try {
                          final r = await api.post('/tutoring/ask', {
                            'course_id': widget.courseId,
                            'question': question.text.trim(),
                            'mode': 'explain',
                          });
                          setState(() => answer = val(r['text']));
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                child: Text(busy ? '思考中…' : '提问'),
              ),
              const SizedBox(height: 12),
              Expanded(
                  child: SingleChildScrollView(child: SelectableText(answer))),
            ],
          ),
        ),
      );
}

class CompanionPage extends StatelessWidget {
  const CompanionPage({super.key});
  @override
  Widget build(BuildContext context) => RemoteView(
        load: () => api.get('/companion/pets'),
        builder: (data, reload) {
          final pets = items(data);
          if (pets.isEmpty)
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('创建你的学习伙伴'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final name = await inputDialog(context, '给伙伴起个名字', '名字');
                      if (name == null) return;
                      try {
                        await api.post('/companion/pets', {'name': name});
                        reload();
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    child: const Text('创建伙伴'),
                  ),
                ],
              ),
            );
          final pet = pets.first;
          final id = val(pet['pet_id']);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(
                        Icons.pets,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      Text(
                        val(pet['name'], '学习伙伴'),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        '等级 ${val(pet['growth']?['level'], '1')} · 经验 ${val(pet['growth']?['exp'], '0')}',
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.chat_outlined),
                  title: const Text('和伙伴聊天'),
                  subtitle: const Text('当前回复为演示模板'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ChatPage(petId: id)),
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('口语陪练'),
                  subtitle: const Text('当前对话与反馈为演示模板，支持文字输入'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OralPage()),
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.shopping_bag_outlined),
                  title: const Text('积分商店与背包'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RewardsPage(petId: id)),
                  ),
                ),
              ),
            ],
          );
        },
      );
}

class ChatPage extends StatefulWidget {
  final String petId;
  const ChatPage({super.key, required this.petId});
  @override
  State<ChatPage> createState() => _ChatState();
}

class _ChatState extends State<ChatPage> {
  final message = TextEditingController();
  int version = 0;
  bool busy = false;
  @override
  void dispose() {
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('伙伴聊天 · 演示')),
        body: Column(
          children: [
            Expanded(
              child: RemoteView(
                key: ValueKey(version),
                load: () => api.get('/companion/pets/${widget.petId}/chat'),
                builder: (data, reload) {
                  final messages = items(data);
                  if (messages.isEmpty)
                    return const Center(child: Text('向伙伴说句话吧'));
                  return ListView(
                    children: messages
                        .map(
                          (m) => ListTile(
                            title: Text(val(m['content'])),
                            subtitle: Text(m['role'] == 'user' ? '我' : '伙伴'),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: message,
                        decoration: const InputDecoration(hintText: '输入消息'),
                      ),
                    ),
                    IconButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (message.text.trim().isEmpty) return;
                              setState(() => busy = true);
                              try {
                                await api.post(
                                  '/companion/pets/${widget.petId}/chat',
                                  {'content': message.text.trim()},
                                );
                                message.clear();
                                setState(() => version++);
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class OralPage extends StatelessWidget {
  const OralPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('口语陪练 · 演示')),
        body: RemoteView(
          load: () => api.get('/speech/oral/scenes'),
          builder: (data, reload) {
            final scenes = items(data);
            if (scenes.isEmpty) return const Center(child: Text('暂无场景'));
            return ListView(
              children: scenes
                  .map(
                    (s) => ListTile(
                      title: Text(val(s['title'])),
                      subtitle: Text(val(s['level'])),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        try {
                          final r = await api.post('/speech/oral/sessions', {
                            'scene_id': s['scene_id'],
                          });
                          if (context.mounted)
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => OralSession(
                                  sessionId: val(r['session']['session_id']),
                                  opening: val(r['opening']?['text']),
                                ),
                              ),
                            );
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  )
                  .toList(),
            );
          },
        ),
      );
}

class OralSession extends StatefulWidget {
  final String sessionId, opening;
  const OralSession({
    super.key,
    required this.sessionId,
    required this.opening,
  });
  @override
  State<OralSession> createState() => _OralSessionState();
}

class _OralSessionState extends State<OralSession> {
  final text = TextEditingController();
  final lines = <String>[];
  bool busy = false, finished = false;
  @override
  void initState() {
    super.initState();
    lines.add(widget.opening);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('口语练习'),
          actions: [
            TextButton(
              onPressed: finished
                  ? null
                  : () async {
                      try {
                        final r = await api.post(
                          '/speech/oral/sessions/${widget.sessionId}/finish',
                        );
                        setState(() {
                          finished = true;
                          lines.add('练习总结：${val(r['summary']?['tips'])}');
                        });
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
              child: const Text('结束'),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                children: lines.map((e) => ListTile(title: Text(e))).toList(),
              ),
            ),
            if (!finished)
              SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: text,
                        decoration: const InputDecoration(hintText: '输入练习内容'),
                      ),
                    ),
                    IconButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (text.text.trim().isEmpty) return;
                              setState(() => busy = true);
                              try {
                                final sent = text.text.trim();
                                final r = await api.post(
                                  '/speech/oral/sessions/${widget.sessionId}/turn',
                                  {'transcript': sent},
                                );
                                setState(() {
                                  lines.add('我：$sent');
                                  lines.add(
                                      '伙伴：${val(r['turn']?['reply_text'])}');
                                  lines.add(
                                    '建议：${val(r['turn']?['feedback']?['grammar_fix'], '继续保持')}',
                                  );
                                  finished = r['finished'] == true;
                                  text.clear();
                                });
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}

class RewardsPage extends StatefulWidget {
  final String petId;
  const RewardsPage({super.key, required this.petId});
  @override
  State<RewardsPage> createState() => _RewardsState();
}

class _RewardsState extends State<RewardsPage> {
  int version = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('积分与背包')),
        body: RemoteView(
          key: ValueKey(version),
          load: () async => await Future.wait([
            api.get('/rewards/points'),
            api.get('/rewards/shop'),
            api.get('/rewards/bag'),
          ]),
          builder: (data, reload) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '积分余额：${val(data[0]['balance'], '0')}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const ListTile(title: Text('商店')),
              ...items(data[1]).map(
                (i) => ListTile(
                  title: Text(val(i['name'])),
                  subtitle: Text('${val(i['price'])} 积分 · ${val(i['desc'])}'),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await api.post('/rewards/exchange', {
                          'item_id': i['item_id'],
                          'qty': 1,
                        });
                        setState(() => version++);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    child: const Text('兑换'),
                  ),
                ),
              ),
              const ListTile(title: Text('背包')),
              ...items(data[2]).map(
                (i) => ListTile(
                  title: Text(val(i['name'] ?? i['item_id'])),
                  subtitle: Text('数量 ${val(i['qty'])}'),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await api.post('/rewards/feed', {
                          'pet_id': widget.petId,
                          'item_id': i['item_id'],
                        });
                        setState(() => version++);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    child: const Text('投喂'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class ProfilePage extends StatelessWidget {
  final VoidCallback onCoursesChanged;
  const ProfilePage({super.key, required this.onCoursesChanged});
  @override
  Widget build(BuildContext context) => RemoteView(
        load: () => api.get('/users/me'),
        builder: (user, reload) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(val(user['nickname'] ?? user['username'])),
              subtitle: Text(val(user['username'])),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('创建课程'),
                onTap: () async {
                  final title = await inputDialog(context, '创建课程', '课程名称');
                  if (title == null) return;
                  try {
                    await api.post('/courses', {'title': title});
                    onCoursesChanged();
                    if (context.mounted)
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(
                          const SnackBar(content: Text('课程已创建，请从顶部选择')));
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                onTap: () async {
                  try {
                    await api.post('/auth/logout');
                  } catch (_) {}
                  api.token = null;
                  if (context.mounted)
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                      (route) => false,
                    );
                },
              ),
            ),
          ],
        ),
      );
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('通知')),
        body: RemoteView(
          load: () => api.get('/notifications'),
          builder: (data, reload) {
            final list = items(data);
            if (list.isEmpty) return const Center(child: Text('暂无通知'));
            return ListView(
              children: list
                  .map(
                    (n) => ListTile(
                      title: Text(val(n['title'])),
                      subtitle: Text(val(n['body'])),
                      trailing: n['read_at'] == null
                          ? const Icon(Icons.circle, size: 9)
                          : null,
                      onTap: () async {
                        try {
                          await api.post('/notifications/${n['ntf_id']}/read');
                          reload();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  )
                  .toList(),
            );
          },
        ),
      );
}

Future<String?> inputDialog(
  BuildContext context,
  String title,
  String label,
) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty)
              Navigator.pop(ctx, controller.text.trim());
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class QuizPage extends StatelessWidget {
  final String lessonId, courseId;
  const QuizPage({super.key, required this.lessonId, required this.courseId});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('随堂练习')),
        body: RemoteView(
            load: () => api.get('/lessons/$lessonId/quiz'),
            builder: (data, reload) {
              final questions = items(data);
              if (questions.isEmpty) return const Center(child: Text('暂无练习题'));
              return ListView(children: [
                if (data is Map && data['is_demo'] == true) demoNotice(data),
                ...questions
                    .map((q) => Card(
                            child: ListTile(
                          title: Text(val(q['stem'])),
                          subtitle: q['options'] == null
                              ? null
                              : Text(val(q['options'])),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () async {
                            final answer =
                                await inputDialog(context, '作答', '输入答案');
                            if (answer == null) return;
                            try {
                              final result = await api.post('/attempts', {
                                'question_id': q['question_id'],
                                'course_id': courseId,
                                'answer': answer
                              });
                              if (!context.mounted) return;
                              await showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                          title: const Text('作答结果'),
                                          content: Text(
                                              '${val(result['notice'])}\n得分：${val(result['score'])} / ${val(result['max_score'])}\n${val(result['grading_basis'])}'),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx),
                                                child: const Text('知道了'))
                                          ]));
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        )))
                    .toList()
              ]);
            }),
      );
}

class CalendarPage extends StatelessWidget {
  final String courseId;
  const CalendarPage({super.key, required this.courseId});
  @override
  Widget build(BuildContext context) {
    final month = date(DateTime.now()).substring(0, 7);
    return Scaffold(
        appBar: AppBar(title: Text('$month 学习安排')),
        body: RemoteView(
          load: () =>
              api.get('/courses/$courseId/planner/calendar?month=$month'),
          builder: (data, reload) {
            final days = items(data, 'days');
            if (days.isEmpty) return const Center(child: Text('本月暂无安排'));
            return ListView(
                children: days
                    .map((day) => ExpansionTile(
                        title: Text(val(day['date'])),
                        children: items(day)
                            .map((task) => ListTile(
                                title: Text(val(task['title'])),
                                subtitle: Text(val(task['status']))))
                            .toList()))
                    .toList());
          },
        ));
  }
}

Widget demoNotice(dynamic data) => Card(
    child: ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('演示内容'),
        subtitle: Text(val(data['notice'], '当前内容为演示数据'))));

Future<dynamic> uploadFile(
    String path, String field, PlatformFile file, String courseId) async {
  final bytes = file.bytes;
  if (bytes == null) throw Exception('无法读取文件，请重新选择');
  final request = http.MultipartRequest('POST', Uri.parse('$base/api/v1$path'));
  if (api.token != null)
    request.headers['Authorization'] = 'Bearer ${api.token}';
  request.fields['course_id'] = courseId;
  request.files
      .add(http.MultipartFile.fromBytes(field, bytes, filename: file.name));
  final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(seconds: 30)));
  dynamic data;
  try {
    data = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    throw Exception('上传接口返回无法解析的数据');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(response.statusCode == 404 || response.statusCode == 405
        ? '该上传服务尚未接入（${response.statusCode}）'
        : (data is Map ? data['message'] ?? data['detail'] ?? '上传失败' : '上传失败'));
  }
  return data;
}

class UploadPage extends StatefulWidget {
  final String courseId;
  final bool mistake;
  const UploadPage({super.key, required this.courseId, required this.mistake});
  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  PlatformFile? selected;
  bool busy = false;
  String? jobId;
  String? resultText;
  Future<void> choose() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: widget.mistake
              ? ['png', 'jpg', 'jpeg', 'webp']
              : ['pdf', 'pptx', 'png', 'jpg', 'jpeg', 'webp'],
          withData: true);
      if (picked == null) return;
      final file = picked.files.single;
      if (file.size > 20 * 1024 * 1024) {
        if (mounted) showError(context, '文件不能超过 20 MB');
        return;
      }
      setState(() {
        selected = file;
        resultText = null;
        jobId = null;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> submit() async {
    if (selected == null) return;
    setState(() => busy = true);
    try {
      final r = await uploadFile(
          widget.mistake ? '/mistakes/capture' : '/materials',
          widget.mistake ? 'image' : 'file',
          selected!,
          widget.courseId);
      if (!mounted) return;
      setState(() {
        jobId = r['job_id']?.toString();
        resultText =
            '已提交${widget.mistake ? '错题' : '资料'}${jobId == null ? '' : '，处理任务：$jobId'}';
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.mistake ? '上传错题' : '导入资料')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Card(
            child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('处理服务尚待接入'),
                subtitle: Text('当前乙侧演示接口不提供文件上传或识别，提交时将显示服务状态。'))),
        OutlinedButton.icon(
            onPressed: busy ? null : choose,
            icon: const Icon(Icons.attach_file),
            label: Text(selected?.name ?? '选择文件')),
        const SizedBox(height: 8),
        const Text('单个文件最大 20 MB'),
        FilledButton(
            onPressed: selected == null || busy ? null : submit,
            child: Text(busy ? '上传中…' : '提交')),
        if (resultText != null) ListTile(title: Text(resultText!)),
        if (jobId != null)
          OutlinedButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => JobPage(jobId: jobId!))),
              child: const Text('查看处理进度')),
      ]));
}

class JobPage extends StatelessWidget {
  final String jobId;
  const JobPage({super.key, required this.jobId});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('处理进度')),
      body: RemoteView(
          load: () => api.get('/jobs/$jobId'),
          builder: (data, reload) =>
              ListView(padding: const EdgeInsets.all(16), children: [
                Text('状态：${val(data['status'])}'),
                Text('进度：${val(data['progress'])}%'),
                if (data['error_code'] != null)
                  Text('错误：${val(data['error_code'])}'),
                TextButton(onPressed: reload, child: const Text('刷新进度'))
              ])));
}

class ExamImportPage extends StatelessWidget {
  final String courseId;
  const ExamImportPage({super.key, required this.courseId});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('选择试卷来源')),
      body: RemoteView(
          load: () => api.get('/materials?course_id=$courseId'),
          builder: (data, reload) {
            final list = items(data);
            return ListView(children: [
              const Card(
                  child: ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('试卷服务尚待接入'),
                      subtitle: Text('当前资料为演示数据；导入、生成和判卷依赖乙侧真实服务。'))),
              if (list.isEmpty) const ListTile(title: Text('暂无资料，请先导入资料')),
              ...list.map((m) => ListTile(
                  title: Text(val(m['title'])),
                  subtitle: Text(val(m['status'])),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ExamWorkflow(
                              courseId: courseId,
                              materialId: val(m['material_id']))))))
            ]);
          }));
}

class ExamWorkflow extends StatefulWidget {
  final String courseId, materialId;
  const ExamWorkflow(
      {super.key, required this.courseId, required this.materialId});
  @override
  State<ExamWorkflow> createState() => _ExamWorkflowState();
}

class _ExamWorkflowState extends State<ExamWorkflow> {
  bool busy = false;
  dynamic exam;
  String? jobId;
  List<dynamic>? paper;
  final answers = <String, String>{};
  dynamic summary;
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

  String get examId => val(exam['exam_id']);
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('仿真试卷')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Card(
            child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('试卷服务尚待接入'),
                subtitle: Text('该流程需要乙侧试卷接口，当前演示服务无法生成真实试卷。'))),
        if (exam == null)
          FilledButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                        final r = await api.post('/exams/import', {
                          'course_id': widget.courseId,
                          'material_id': widget.materialId
                        });
                        final e = r['exam'] ?? r;
                        if (e['exam_id'] == null) throw Exception('服务未返回试卷 ID');
                        if (!mounted) return;
                        setState(() {
                          exam = e;
                          jobId = r['job_id']?.toString() ??
                              e['job_id']?.toString();
                        });
                      }),
              child: const Text('导入试卷')),
        if (exam != null) ...[
          ListTile(
              title: Text('试卷 ${val(exam['status'])}'),
              subtitle: Text('ID: $examId')),
          if (jobId != null)
            OutlinedButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => JobPage(jobId: jobId!))),
                child: const Text('查看处理进度')),
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                        final r = await api.get('/exams/$examId');
                        if (mounted) setState(() => exam = r);
                      }),
              child: const Text('刷新试卷状态')),
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      final controller = TextEditingController(
                          text: const JsonEncoder.withIndent('  ')
                              .convert(exam['blueprint'] ?? {}));
                      final value = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                                  title: const Text('编辑试卷蓝图（JSON）'),
                                  content: SizedBox(
                                      width: 500,
                                      child: TextField(
                                          controller: controller,
                                          maxLines: 12)),
                                  actions: [
                                    TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, controller.text),
                                        child: const Text('保存'))
                                  ]));
                      controller.dispose();
                      if (value == null || !mounted) return;
                      await action(() async {
                        final blueprint = jsonDecode(value);
                        if (blueprint is! Map<String, dynamic>)
                          throw Exception('蓝图必须是 JSON 对象');
                        final r = await api.request(
                            'PATCH',
                            '/exams/$examId/blueprint',
                            {'blueprint': blueprint});
                        if (mounted) setState(() => exam = r);
                      });
                    },
              child: const Text('编辑试卷蓝图')),
          FilledButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                        final r = await api.post('/exams/$examId/generate');
                        if (mounted)
                          setState(() => jobId = r['job_id']?.toString());
                      }),
              child: const Text('生成试卷')),
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                        final r = await api.get('/exams/$examId/paper');
                        if (mounted)
                          setState(() {
                            paper = items(r, 'questions');
                            summary = null;
                          });
                      }),
              child: const Text('加载试题')),
        ],
        if (paper != null) ...[
          if (paper!.isEmpty) const ListTile(title: Text('试卷暂无题目')),
          ...paper!.map((q) => Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(val(q['stem'])),
                        if (q['options'] != null) Text(val(q['options'])),
                        TextFormField(
                            key: ValueKey(val(q['question_id'])),
                            initialValue: answers[val(q['question_id'])],
                            decoration: const InputDecoration(labelText: '答案'),
                            onChanged: (v) =>
                                answers[val(q['question_id'])] = v)
                      ])))),
          if (paper!.isNotEmpty)
            FilledButton(
                onPressed: busy
                    ? null
                    : () => action(() async {
                          final r = await api.post('/exams/$examId/submit', {
                            'answers': paper!
                                .map((q) => {
                                      'question_id': q['question_id'],
                                      'answer':
                                          answers[val(q['question_id'])] ?? ''
                                    })
                                .toList()
                          });
                          if (mounted) setState(() => summary = r['summary']);
                        }),
                child: const Text('提交试卷')),
        ],
        if (summary != null)
          Card(
              child: ListTile(
                  title: Text(
                      '得分 ${val(summary['score'])} / ${val(summary['total_score'])}'),
                  subtitle: Text('批改时间：${val(summary['graded_at'])}'))),
      ]));
}
