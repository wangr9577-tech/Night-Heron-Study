import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

import 'readable_text.dart';
import 'pet_avatar.dart';
import 'focus_page.dart';
import 'ai_settings.dart';
import 'local_home.dart';
import 'local_platform.dart';
import 'desktop_shell.dart';

part 'learning_pages.dart';
part 'review_pages.dart';
part 'graph_pages.dart';
part 'pet_customization.dart';

const configuredBase = String.fromEnvironment('API_BASE');
final base = configuredBase.isNotEmpty
    ? configuredBase
    : Platform.isWindows
    ? 'http://127.0.0.1:8000'
    : 'http://10.0.2.2:8000';
final api = Api();
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeLocalPlatform();
  await api.restore();
  runApp(ZhiApp(signedIn: api.token != null, localMode: api.token == null));
}

class Api {
  String? token;
  String baseUrl = base;
  String? selectedCourse;
  http.Client client = http.Client();
  int _command = 0;
  String commandKey() =>
      'app-${DateTime.now().microsecondsSinceEpoch}-${_command++}';
  Uri uri(String path) => Uri.parse('$baseUrl/api/v1$path');
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('api_base') ?? base;
    token = prefs.getString('token');
    selectedCourse = prefs.getString('course');
    if (token != null) {
      try {
        await get('/users/me');
      } catch (_) {}
    }
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base', baseUrl);
    if (token == null) {
      await prefs.remove('token');
      await prefs.remove('course');
    } else {
      await prefs.setString('token', token!);
    }
    if (selectedCourse != null && token != null) {
      await prefs.setString('course', selectedCourse!);
    }
  }

  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
    String? key,
  ]) async {
    final request = http.Request(method, uri(path));
    request.headers.addAll({
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      if (method != 'GET') 'Idempotency-Key': key ?? commandKey(),
    });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 30)),
    );
    dynamic data;
    try {
      data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw Exception('服务器返回无法解析的数据');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 && token != null) {
        token = null;
        selectedCourse = null;
        await persist();
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (_) => false,
        );
      }
      throw Exception(
        data is Map
            ? (data['message'] ??
                  data['error']?['message'] ??
                  data['detail'] ??
                  '请求失败 (${response.statusCode})')
            : '请求失败 (${response.statusCode})',
      );
    }
    return data;
  }

  Future<dynamic> get(String path) => request('GET', path);
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      request('POST', path, body);
}

class ZhiApp extends StatelessWidget {
  final bool signedIn;
  final bool localMode;
  const ZhiApp({super.key, this.signedIn = false, this.localMode = false});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '啄知 AI',
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff557b60)),
    ),
    home: signedIn
        ? const HomePage()
        : localMode
        ? (Platform.isWindows ? const DesktopShell() : const LocalHome())
        : const LoginPage(),
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
      await api.persist();
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
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final value = await inputDialog(
                            context,
                            '连接后端',
                            '服务地址，例如 http://10.0.2.2:8000',
                            initial: api.baseUrl,
                          );
                          if (value == null) return;
                          final uri = Uri.tryParse(value);
                          if (uri == null ||
                              !['http', 'https'].contains(uri.scheme) ||
                              uri.host.isEmpty) {
                            if (context.mounted)
                              showError(context, '请输入有效的服务地址');
                            return;
                          }
                          api.baseUrl = value.replaceAll(RegExp(r'/+$'), '');
                          await api.persist();
                          if (mounted) setState(() {});
                        },
                  icon: const Icon(Icons.dns_outlined),
                  label: Text('后端：${api.baseUrl}'),
                ),
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
                TextButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LocalHome()),
                  ),
                  child: const Text('进入本地体验'),
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
  void initState() {
    super.initState();
    loadCourse();
  }

  Future<void> loadCourse() async {
    try {
      final courses = items(await api.get('/courses'))
          .where((c) => c['archived'] != true)
          .toList();
      if (!mounted) return;
      if (courses.isEmpty) {
        api.selectedCourse = null;
        setState(() {
          tab = 3;
          courseId = null;
          courseTitle = '';
        });
        await api.persist();
        return;
      }
      final selected = courses.firstWhere(
        (c) => c['course_id'] == api.selectedCourse,
        orElse: () => courses.first,
      );
      api.selectedCourse = val(selected['course_id']);
      setState(() {
        courseId = selected['course_id'];
        courseTitle = selected['title'];
      });
      await api.persist();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      PlannerPage(key: ValueKey('p$courseId$version'), courseId: courseId),
      StudyPage(key: ValueKey('s$courseId$version'), courseId: courseId),
      const CompanionPage(),
      ProfilePage(
        onCoursesChanged: () {
          setState(() => version++);
          loadCourse();
        },
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['学习安排', '学习中心', '宠物', '我的'][tab]),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LocalHome()),
            ),
            icon: const Icon(Icons.phone_android_outlined),
            tooltip: '本地体验',
          ),
          TextButton.icon(
            onPressed: chooseCourse,
            icon: const Icon(Icons.school_outlined),
            label: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * .25,
              ),
              child: Text(
                courseTitle.isEmpty ? '选择课程' : courseTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
          NavigationDestination(icon: Icon(Icons.pets_outlined), label: '宠物'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }

  Future<void> chooseCourse() async {
    try {
      final courses = items(await api.get('/courses'))
          .where((c) => c['archived'] != true)
          .toList();
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
          api.selectedCourse = courseId;
          unawaited(api.persist());
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
    if (!mounted) return;
    setState(() {
      future = widget.load();
    });
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
                    final lessonId = await inputDialog(
                      context,
                      '关联课程讲解',
                      '讲解 ID',
                    );
                    if (lessonId == null || !context.mounted) return;
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked == null || !context.mounted) return;
                    try {
                      await api.post('/courses/$id/planner/tasks', {
                        'title': title,
                        'type': 'lesson',
                        'target_id': lessonId,
                        'planned_date': date(picked),
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
                      builder: (_) => CalendarPage(courseId: id),
                    ),
                  ),
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
                  onTap: () async {
                    try {
                      await openTask(context, t);
                      reload();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
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
                      if (['lesson', 'qa'].contains(t['type']))
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
          child: ListView(
            children: [
              if (data is Map && data['is_demo'] == true) demoNotice(data),
              if (list.isEmpty) const ListTile(title: Text('暂无内容')),
              ...list.map(itemBuilder),
            ],
          ),
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
            title: Text('已连接真实学习内容'),
            subtitle: Text('资料、知识点、练习和掌握状态均来自本地学习引擎，保留教材来源与作答证据。'),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('导入学习资料'),
            subtitle: const Text('选择 PDF、PPTX 或图片上传'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UploadPage(courseId: id, mistake: false),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.add_a_photo_outlined),
            title: const Text('上传错题'),
            subtitle: const Text('选择错题图片并提交识别'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => UploadPage(courseId: id, mistake: true),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.assignment_outlined),
            title: const Text('仿真试卷'),
            subtitle: const Text('选择已有资料，导入并生成试卷'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ExamImportPage(courseId: id)),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.auto_stories),
            title: const Text('生成课程讲解'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GenerateLessonPage(courseId: id),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('课程目标与时段'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => CourseEditorPage(courseId: id)),
            ),
          ),
        ),
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
                        if (item['review_id'] != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PracticePage(
                                courseId: id,
                                questionId: val(item['question_id']),
                                reviewId: val(item['review_id']),
                              ),
                            ),
                          );
                          return;
                        }
                        final itemId =
                            item['lesson_id'] ??
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
                              builder: (_) => item['lesson_id'] != null
                                  ? LessonPlayerPage(
                                      lessonId: val(itemId),
                                      courseId: id,
                                    )
                                  : item['mistake_id'] != null
                                  ? MistakePage(
                                      mistakeId: val(itemId),
                                      courseId: id,
                                    )
                                  : DetailPage(
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
              MaterialPageRoute(
                builder: (_) => AdvancedGraphPage(courseId: id),
              ),
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
          if (data['description'] != null)
            SelectableText(val(data['description'])),
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
                    courseId: val(data['course_id']),
                  ),
                ),
              ),
              icon: const Icon(Icons.quiz_outlined),
              label: const Text('开始随堂练习'),
            ),
          if (data['error_cause'] != null) Text('错误原因：${data['error_cause']}'),
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
  bool useModel = false;
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
          SwitchListTile(
            value: useModel,
            onChanged: busy
                ? null
                : (value) => setState(() => useModel = value),
            title: const Text('使用已配置的 AI 模型'),
            subtitle: Text(
              useModel
                  ? '问题会发送给你设置的模型服务；此模式不自动附带课程资料。'
                  : '关闭时基于已导入资料检索并使用规则提示。',
            ),
          ),
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
                      if (useModel) {
                        final settings = await AiSettings.load();
                        if (settings == null)
                          throw Exception('请先在“我的”中配置 AI 模型');
                        final reply = await settings.ask(question.text.trim());
                        if (mounted) setState(() => answer = reply);
                      } else {
                        final r = await api.post('/tutoring/ask', {
                          'course_id': widget.courseId,
                          'question': question.text.trim(),
                          'mode': 'explain',
                        });
                        if (mounted) setState(() => answer = val(r['text']));
                      }
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
            child: SingleChildScrollView(
              child: ReadingText(answer, selectable: true, rich: true),
            ),
          ),
        ],
      ),
    ),
  );
}

class CompanionPage extends StatefulWidget {
  const CompanionPage({super.key});
  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends State<CompanionPage> {
  bool interacting = false;

  Future<dynamic> loadCompanion() async {
    final data = await api.get('/companion/pets');
    final pets = items(data);
    if (pets.isEmpty) return {'pets': pets};
    final id = val(pets.first['pet_id']);
    final summary = await api.get('/companion/pets/$id/growth-summary');
    Uint8List? sprite;
    try {
      final response = await api.client
          .get(
            api.uri('/companion/pets/$id/sprite'),
            headers: {'Authorization': 'Bearer ${api.token}'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) sprite = response.bodyBytes;
    } catch (_) {
      // A missing or unavailable optional atlas does not block learning.
    }
    return {'pets': pets, 'summary': summary, 'sprite': sprite};
  }

  @override
  Widget build(BuildContext context) => RemoteView(
    load: loadCompanion,
    builder: (data, reload) {
      final pets = data['pets'] as List;
      if (pets.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('还没有宠物'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final name = await inputDialog(context, '给宠物起个名字', '名字');
                  if (name == null || name.trim().isEmpty) return;
                  try {
                    await api.post('/companion/pets', {'name': name.trim()});
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('创建宠物'),
              ),
            ],
          ),
        );
      }
      final pet = pets.first;
      final id = val(pet['pet_id']);
      final summary = data['summary'] as Map;
      final currentExp = (summary['exp_in_level'] as num?)?.toInt() ?? 0;
      final remainingExp =
          (summary['exp_to_next_level'] as num?)?.toInt() ?? 100;
      final denominator = currentExp + remainingExp;
      final progress = denominator > 0
          ? (currentExp / denominator).clamp(0.0, 1.0)
          : 0.0;
      final todayDone = summary['interacted_today'] == true;
      final events = (summary['recent_events'] as List?) ?? [];
      final colors = Theme.of(context).colorScheme;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: colors.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  MiniPetAvatar(
                    size: 144,
                    avatarKey: val(pet['avatar_key'], 'bird_1'),
                    spriteBytes: data['sprite'] as Uint8List?,
                    motion: interacting ? PetMotion.waving : PetMotion.idle,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    val(pet['name'], '学习宠物'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.palette_outlined),
                    label: const Text('自定义宠物'),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PetCustomizationPage(pet: pet),
                        ),
                      );
                      if (context.mounted) reload();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '等级 ${val(pet['growth']?['level'], '1')} · 经验 ${val(pet['growth']?['exp'], '0')}',
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                    semanticsLabel: '升级进度',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '距离下一级还需 $remainingExp 经验',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('companion-interact'),
                      onPressed: interacting || todayDone
                          ? null
                          : () async {
                              setState(() => interacting = true);
                              try {
                                final result = await api.post(
                                  '/companion/pets/$id/interact',
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        val(result['reaction_text'], '陪伴成功！'),
                                      ),
                                    ),
                                  );
                                  reload();
                                }
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              } finally {
                                if (mounted)
                                  setState(() => interacting = false);
                              }
                            },
                      icon: const Icon(Icons.favorite_outline),
                      label: Text(
                        interacting
                            ? '陪伴中…'
                            : todayDone
                            ? '今天已陪伴'
                            : '陪伴一下 · +3 经验',
                      ),
                    ),
                  ),
                  Text(
                    '每天可陪伴一次，和宠物一起成长',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('成长足迹', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    '陪伴 ${val(summary['interaction_count'], '0')} 次 · 投喂 ${val(summary['feed_count'], '0')} 次',
                  ),
                  const Divider(),
                  if (events.isEmpty)
                    const Text('还没有成长记录，来陪伴宠物或投喂食物吧。')
                  else
                    ...events.take(3).map((event) {
                      final eventTime = DateTime.tryParse(val(event['at']))
                          ?.toLocal();
                      final dateLabel = eventTime == null
                          ? ''
                          : '${eventTime.year}-${eventTime.month.toString().padLeft(2, '0')}-${eventTime.day.toString().padLeft(2, '0')}';
                      final type = event['type'] == 'feed'
                          ? '投喂食物'
                          : event['type'] == 'play'
                          ? '每日陪伴'
                          : '成长';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                          event['type'] == 'feed'
                              ? Icons.restaurant_outlined
                              : Icons.favorite_outline,
                        ),
                        title: Text(type),
                        subtitle: Text(dateLabel),
                        trailing: Text('+${val(event['exp_delta'], '0')} 经验'),
                      );
                    }),
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('和宠物聊天'),
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
              leading: const Icon(Icons.timer_outlined),
              title: const Text('番茄钟与专注统计'),
              subtitle: const Text('记录专注时间，查看日历和分类'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FocusPage(scope: val(pet['user_id'], id)),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: const Text('积分商店与背包'),
              subtitle: const Text('用学习积分兑换食物，投喂宠物'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => RewardsPage(petId: id)),
                );
                if (context.mounted) reload();
              },
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
    appBar: AppBar(title: const Text('宠物聊天 · 演示')),
    body: Column(
      children: [
        Expanded(
          child: RemoteView(
            key: ValueKey(version),
            load: () => api.get('/companion/pets/${widget.petId}/chat'),
            builder: (data, reload) {
              final messages = items(data);
              if (messages.isEmpty) return const Center(child: Text('向宠物说句话吧'));
              return ListView(
                children: messages
                    .map(
                      (m) => ListTile(
                        title: Text(val(m['content'])),
                        subtitle: Text(m['role'] == 'user' ? '我' : '宠物'),
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
  final recognizer = SpeechToText();
  final voice = FlutterTts();
  bool listening = false;
  bool busy = false, finished = false;
  late String latestReply;
  @override
  void initState() {
    super.initState();
    latestReply = widget.opening;
    lines.add(widget.opening);
  }

  @override
  void dispose() {
    recognizer.stop();
    voice.stop();
    text.dispose();
    super.dispose();
  }

  Future<void> listen() async {
    try {
      if (listening) {
        await recognizer.stop();
        if (mounted) setState(() => listening = false);
        return;
      }
      final available = await recognizer.initialize(
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => listening = false);
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() => listening = false);
            showError(context, '语音识别不可用，请直接输入文字');
          }
        },
      );
      if (!available) throw Exception('没有可用的语音识别服务，请直接输入文字');
      if (mounted) setState(() => listening = true);
      await recognizer.listen(
        listenOptions: SpeechListenOptions(
          localeId: 'en_US',
          partialResults: true,
        ),
        onResult: (result) {
          if (mounted) text.text = result.recognizedWords;
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => listening = false);
        showError(context, '语音识别不可用，请直接输入文字');
      }
    }
  }

  Future<void> finishSession() async {
    final r = await api.post(
      '/speech/oral/sessions/${widget.sessionId}/finish',
    );
    if (!mounted) return;
    final tips = r['summary']?['tips'];
    final tipsText = tips is List ? tips.join('；') : val(tips, '继续练习');
    setState(() {
      finished = true;
      lines.add('练习总结：$tipsText');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('口语练习'),
      actions: [
        IconButton(
          tooltip: '朗读最近一句',
          onPressed: () async {
            try {
              await voice.setLanguage('en-US');
              if (await voice.speak(latestReply) != 1 && context.mounted)
                showError(context, '设备语音不可用，请阅读文字');
            } catch (_) {
              if (context.mounted) showError(context, '设备语音不可用，请阅读文字');
            }
          },
          icon: const Icon(Icons.volume_up),
        ),
        TextButton(
          onPressed: finished || busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await finishSession();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => busy = false);
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
                IconButton(
                  tooltip: listening ? '停止录音' : '语音输入',
                  onPressed: busy ? null : listen,
                  icon: Icon(listening ? Icons.mic_off : Icons.mic),
                ),
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
                            if (!mounted) return;
                            setState(() {
                              lines.add('我：$sent');
                              latestReply = val(r['turn']?['reply_text']);
                              lines.add('伙伴：$latestReply');
                              lines.add(
                                '建议：${val(r['turn']?['feedback']?['grammar_fix'], '继续保持')}',
                              );
                              text.clear();
                            });
                            if (r['finished'] == true) await finishSession();
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

String bagItemName(dynamic item, dynamic shop) {
  final match = items(shop).firstWhere(
    (candidate) => candidate['item_id'] == item['item_id'],
    orElse: () => null,
  );
  return val(item['name'] ?? match?['name'] ?? item['item_id']);
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
              title: Text(bagItemName(i, data[1])),
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
          subtitle: Text(
            '${val(user['username'])}\n用户 ID：${val(user['user_id'])}',
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('创建课程'),
            onTap: () async {
              final saved = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const CourseEditorPage()),
              );
              if (saved == true) onCoursesChanged();
            },
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('AI 模型设置'),
            subtitle: const Text('配置服务地址、模型和 API Key'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiSettingsPage()),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('内容与作答审核'),
            subtitle: const Text('仅限已获授权的课程审核员'),
            onTap: () {
              if (api.selectedCourse == null) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('请先选择课程')));
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ReviewQueuePage(courseId: api.selectedCourse!),
                ),
              );
            },
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('课程成员管理'),
            subtitle: const Text('课程创建者可按用户 ID 添加审核员为成员'),
            onTap: () {
              if (api.selectedCourse == null) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('请先选择课程')));
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      CourseMembersPage(courseId: api.selectedCourse!),
                ),
              );
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
                api.token = null;
                api.selectedCourse = null;
                await api.persist();
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
  String label, {
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _InputDialog(title: title, label: label, initial: initial),
);

class _InputDialog extends StatefulWidget {
  final String title, label, initial;
  const _InputDialog({
    required this.title,
    required this.label,
    required this.initial,
  });
  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final TextEditingController controller;
  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (controller.text.trim().isNotEmpty)
            Navigator.pop(context, controller.text.trim());
        },
        child: const Text('确定'),
      ),
    ],
  );
}

class QuizPage extends StatelessWidget {
  final String lessonId, courseId;
  const QuizPage({super.key, required this.lessonId, required this.courseId});
  @override
  Widget build(BuildContext context) {
    return JsonListPage(
      title: '随堂练习',
      path: '/lessons/$lessonId/quiz',
      itemBuilder: (q) => ListTile(
        title: Text(val(q['stem'])),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PracticePage(
              courseId: courseId,
              questionId: val(q['question_id']),
            ),
          ),
        ),
      ),
    );
  }
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
        load: () => api.get('/courses/$courseId/planner/calendar?month=$month'),
        builder: (data, reload) {
          final days = items(data, 'days');
          if (days.isEmpty) return const Center(child: Text('本月暂无安排'));
          return ListView(
            children: days
                .map(
                  (day) => ExpansionTile(
                    title: Text(val(day['date'])),
                    children: items(day)
                        .map(
                          (task) => ListTile(
                            title: Text(val(task['title'])),
                            subtitle: Text(val(task['status'])),
                          ),
                        )
                        .toList(),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }
}

Widget demoNotice(dynamic data) => Card(
  child: ListTile(
    leading: const Icon(Icons.info_outline),
    title: const Text('演示内容'),
    subtitle: Text(val(data['notice'], '当前内容为演示数据')),
  ),
);

Future<dynamic> uploadFile(
  String path,
  String field,
  PlatformFile file,
  String courseId,
) async {
  final bytes = file.bytes;
  if (bytes == null) throw Exception('无法读取文件，请重新选择');
  final request = http.MultipartRequest('POST', api.uri(path));
  if (api.token != null)
    request.headers['Authorization'] = 'Bearer ${api.token}';
  request.fields['course_id'] = courseId;
  request.files.add(
    http.MultipartFile.fromBytes(field, bytes, filename: file.name),
  );
  final response = await http.Response.fromStream(
    await request.send().timeout(const Duration(seconds: 30)),
  );
  dynamic data;
  try {
    data = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    throw Exception('上传接口返回无法解析的数据');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      response.statusCode == 404 || response.statusCode == 405
          ? '该上传服务尚未接入（${response.statusCode}）'
          : (data is Map
                ? data['message'] ?? data['detail'] ?? '上传失败'
                : '上传失败'),
    );
  }
  return data;
}

class UploadPage extends StatelessWidget {
  final String courseId;
  final bool mistake;
  const UploadPage({super.key, required this.courseId, required this.mistake});
  @override
  Widget build(BuildContext context) =>
      NativeImportPage(courseId: courseId, mistake: mistake);
}

class JobPage extends StatelessWidget {
  final String jobId;
  const JobPage({super.key, required this.jobId});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('处理进度')),
    body: RemoteView(
      load: () => api.get('/jobs/$jobId'),
      builder: (data, reload) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('状态：${val(data['status'])}'),
          Text('进度：${val(data['progress'])}%'),
          if (data['error_code'] != null) Text('错误：${val(data['error_code'])}'),
          TextButton(onPressed: reload, child: const Text('刷新进度')),
        ],
      ),
    ),
  );
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
        return ListView(
          children: [
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('从课程资料生成练习卷'),
                subtitle: Text('选择已经解析的资料，分析知识点并生成可判分练习。'),
              ),
            ),
            if (list.isEmpty) const ListTile(title: Text('暂无资料，请先导入资料')),
            ...list.map(
              (m) => ListTile(
                title: Text(val(m['title'])),
                subtitle: Text(val(m['status'])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExamWorkflow(
                      courseId: courseId,
                      materialId: val(m['material_id']),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class ExamWorkflow extends StatelessWidget {
  final String courseId, materialId;
  const ExamWorkflow({
    super.key,
    required this.courseId,
    required this.materialId,
  });
  @override
  Widget build(BuildContext context) =>
      NativeExamPage(courseId: courseId, materialId: materialId);
}
