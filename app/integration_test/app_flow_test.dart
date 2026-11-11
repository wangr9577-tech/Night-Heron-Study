import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/main.dart' as app;

Future<void> visible(
  WidgetTester tester,
  Finder finder, {
  int tries = 150,
}) async {
  for (var i = 0; i < tries; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

String solve(String prompt) {
  final match = RegExp(
    r'TP\s*=\s*(\d+).*?TN\s*=\s*(\d+).*?FP\s*=\s*(\d+).*?FN\s*=\s*(\d+)',
    dotAll: true,
  ).firstMatch(prompt);
  if (match == null) throw TestFailure('Unexpected problem $prompt');
  final tp = int.parse(match[1]!),
      tn = int.parse(match[2]!),
      fp = int.parse(match[3]!),
      fn = int.parse(match[4]!);
  if (prompt.contains('Recall') || prompt.contains('召回率'))
    return (tp / (tp + fn)).toString();
  if (prompt.contains('Precision') || prompt.contains('精确率'))
    return (tp / (tp + fp)).toString();
  return ((tp + tn) / (tp + tn + fp + fn)).toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android app signs in, studies real KNN evidence and keeps rewards',
    (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      // This test clears app preferences and writes learning data. Require an
      // explicit isolated target instead of silently using a developer's server.
      const isolated = bool.fromEnvironment('INTEGRATION_TEST_ISOLATED');
      const testApi = String.fromEnvironment('API_BASE');
      if (!isolated || testApi.isEmpty) {
        throw TestFailure(
          'Use a disposable emulator and a separately seeded backend, then '
          'pass --dart-define=INTEGRATION_TEST_ISOLATED=true and '
          '--dart-define=API_BASE=<isolated backend URL>.',
        );
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      app.api.token = null;
      app.api.selectedCourse = null;
      app.api.baseUrl = testApi;
      await tester.pumpWidget(const app.ZhiApp());
      await visible(tester, find.text('登录'));
      await tester.enterText(find.byType(TextField).at(0), 'demo_knn');
      await tester.enterText(find.byType(TextField).at(1), 'Demo12345');
      await tester.tap(find.text('登录'));
      await visible(tester, find.text('学习安排'));
      final prepared = await tester.runAsync(() async {
        final courses = app.items(await app.api.get('/courses'));
        final course = courses.firstWhere((c) => c['title'] == '数据科学导论 · KNN');
        final cid = app.val(course['course_id']);
        final graph = await app.api.get('/courses/$cid/knowledge');
        final concept = app
            .items(graph, 'nodes')
            .firstWhere((n) => app.val(n['title']).contains('Accuracy'));
        final bp = await app.api.post('/courses/$cid/exam-blueprints', {
          'title': 'App 联调',
          'duration_minutes': 10,
          'slots': [
            {
              'concept_id': concept['id'],
              'kind': 'numeric',
              'difficulty': 'easy',
              'count': 1,
              'points': 10,
            },
          ],
        });
        final job = await app.api.post('/courses/$cid/exams', {
          'blueprint_id': bp['id'],
          'seed': DateTime.now().millisecondsSinceEpoch % 2147483647,
        });
        final ref = await app.waitJob(app.val(job['job_id']));
        final exam = await app.api.get('/courses/$cid/exams/${ref['id']}');
        final question = app.items(exam, 'questions').first;
        final title = '设备联调 ${DateTime.now().millisecondsSinceEpoch}';
        final task = await app.api.post('/courses/$cid/planner/tasks', {
          'type': 'practice',
          'target_id': question['id'],
          'title': title,
          'planned_date': app.date(DateTime.now()),
          'estimated_minutes': 10,
        });
        return {'question': question, 'title': title, 'task': task};
      });
      final question = prepared!['question'] as dynamic;
      final title = prepared['title'] as String;
      final task = prepared['task'] as dynamic;
      await visible(tester, find.text('生成今日安排'));
      await tester.tap(find.text('生成今日安排'));
      await tester.pump(const Duration(seconds: 2));
      await tester.dragUntilVisible(
        find.text(title),
        find.byType(Scrollable).first,
        const Offset(0, -350),
      );
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await visible(tester, find.byKey(const Key('practice-answer')));
      await tester.enterText(
        find.byKey(const Key('practice-answer')),
        solve(app.val(question['prompt'])),
      );
      await tester.ensureVisible(find.byKey(const Key('submit-practice')));
      await tester.tap(find.byKey(const Key('submit-practice')));
      await visible(tester, find.byKey(const Key('practice-result')));
      await visible(tester, find.textContaining('得分：100 / 100'));
      await tester.pump(const Duration(seconds: 2));
      final status = await tester.runAsync(
        () => app.api.get('/planner/tasks/${task['task_id']}'),
      );
      expect(status['status'], 'done');
      final points = await tester.runAsync(
        () => app.api.get('/rewards/points'),
      );
      expect(points['balance'], greaterThanOrEqualTo(25));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('学习'));
      await tester.pumpAndSettle();
      expect(find.text('已连接真实学习内容'), findsOneWidget);
      await tester.tap(find.text('宠物'));
      // The companion intentionally animates continuously, so it never settles.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('宠物'), findsWidgets);
      if (find.text('创建宠物').evaluate().isNotEmpty) {
        await tester.tap(find.text('创建宠物'));
        await tester.pump(const Duration(seconds: 1));
        await tester.enterText(find.byType(TextField).last, '小啄');
        await tester.tap(find.text('确定'));
        await tester.pump(const Duration(seconds: 2));
      }
      await visible(tester, find.byKey(const Key('mini-pet-paint')));
      await visible(tester, find.text('自定义宠物'));
      final previousPets = await tester.runAsync(
        () => app.api.get('/companion/pets'),
      );
      final wasRose =
          app.items(previousPets).first['avatar_key'] == 'bird_rose';
      final colorName = wasRose ? '晴蓝' : '樱粉';
      final colorKey = wasRose ? 'bird_blue' : 'bird_rose';
      await tester.tap(find.text('自定义宠物'));
      await visible(tester, find.text('内置配色'));
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(find.text(colorName));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(colorName));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text(colorName),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.text('保存名字与配色'));
      await tester.pump(const Duration(seconds: 2));
      final savedPets = await tester.runAsync(
        () => app.api.get('/companion/pets'),
      );
      expect(app.items(savedPets).first['avatar_key'], colorKey);
      await tester.pageBack();
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('我的'));
      await visible(tester, find.text('内容与作答审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('内容与作答审核'));
      await tester.pumpAndSettle();
      await visible(tester, find.text('课程审核'));
      await visible(tester, find.textContaining('需要该课程的内容审核权限'));
      await tester.tap(find.text('主观题评分'));
      await visible(tester, find.textContaining('需要该课程的内容审核权限'));
    },
  );
}
