import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'focus_page.dart';
import 'local_courses.dart';
import 'readable_text.dart';
import 'main.dart' show LoginPage;
import 'local_growth_page.dart';
import 'local_course_page.dart';

class LocalHome extends StatefulWidget {
  const LocalHome({super.key});
  @override
  State<LocalHome> createState() => _LocalHomeState();
}

class _LocalHomeState extends State<LocalHome> {
  LocalCourses? store;
  List<Map<String, Object?>> courses = [];
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
      if (mounted) setState(() => error = '无法打开本地课程：$e');
    }
  }

  Future<void> _reload() async {
    final result = await store!.list();
    if (mounted) setState(() => courses = result);
  }

  Future<void> _create() async {
    var courseTitle = '';
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建本地课程'),
        content: TextField(
          onChanged: (value) => courseTitle = value,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '课程名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, courseTitle),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    try {
      await store!.add(title);
      await _reload();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法创建：$e')));
    }
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('啄知 AI · 本地体验'),
      actions: [
        TextButton(
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            }
          },
          child: Text(Navigator.of(context).canPop() ? '返回服务器' : '服务器登录'),
        ),
      ],
    ),
    body: store == null
        ? Center(child: Text(error ?? '正在打开本地数据…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '课程、资料、试卷和专注记录保存在此设备。配置模型后，可进行资料问答与 AI 出题；生成内容请核对。',
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('专注与统计'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FocusPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.pets_outlined),
                title: const Text('宠物'),
                subtitle: const Text('使用专注获得的本机积分'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LocalGrowthPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.smart_toy_outlined),
                title: const Text('模型设置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiSettingsPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.chat_outlined),
                title: const Text('模型问答'),
                subtitle: const Text('需要先设置可用模型；问题会发送给模型服务'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LocalAsk()),
                ),
              ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '本地课程',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _create,
                    tooltip: '新建课程',
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (courses.isEmpty) const Text('还没有课程，点击右侧加号创建。'),
              ...courses.map(
                (c) => ListTile(
                  leading: const Icon(Icons.book_outlined),
                  title: Text(c['title'] as String),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LocalCoursePage(
                        id: c['id'] as int,
                        title: c['title'] as String,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}

class LocalAsk extends StatefulWidget {
  const LocalAsk({super.key, this.sourceText, this.sourceTitle});
  final String? sourceText;
  final String? sourceTitle;
  @override
  State<LocalAsk> createState() => _LocalAskState();
}

class _LocalAskState extends State<LocalAsk> {
  final question = TextEditingController();
  String answer = '';
  bool busy = false;
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> ask() async {
    final text = question.text.trim();
    if (text.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      final settings = await AiSettings.load();
      if (settings == null) throw Exception('请先配置模型服务');
      final excerpt = widget.sourceText == null
          ? null
          : String.fromCharCodes(widget.sourceText!.runes.take(12000));
      final result = await settings.ask(text, sourceText: excerpt);
      if (mounted) setState(() => answer = result);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('模型问答')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            widget.sourceText == null
                ? '你的问题会发送给所配置的服务；本地课程资料不会自动附带。'
                : '发送时会把问题和《${widget.sourceTitle}》的前 12000 字发送给所配置的服务。超出部分不会发送。',
          ),
          TextField(
            controller: question,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '输入问题'),
          ),
          FilledButton(
            onPressed: busy ? null : ask,
            child: Text(busy ? '等待回答…' : '发送'),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: ReadingText(answer, rich: true, selectable: true),
            ),
          ),
        ],
      ),
    ),
  );
}
