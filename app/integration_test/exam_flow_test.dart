import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/main.dart' as app;

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  int tries = 200,
}) async {
  for (var i = 0; i < tries; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('review original paper blueprint and generate exam on Android', (
    tester,
  ) async {
    const isolated = bool.fromEnvironment('INTEGRATION_TEST_ISOLATED');
    const testApi = String.fromEnvironment('API_BASE');
    const material = String.fromEnvironment('EXAM_FIXTURE_TITLE');
    if (!isolated || testApi.isEmpty || material.isEmpty) {
      throw TestFailure(
        'Use a disposable emulator, isolated backend, and EXAM_FIXTURE_TITLE.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    app.api.token = null;
    app.api.selectedCourse = null;
    app.api.baseUrl = testApi;
    await tester.pumpWidget(const app.ZhiApp());
    await waitFor(tester, find.text('登录'));
    await tester.enterText(find.byType(TextField).at(0), 'demo_knn');
    await tester.enterText(find.byType(TextField).at(1), 'Demo12345');
    await tester.tap(find.text('登录'));
    await waitFor(tester, find.text('学习安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('仿真试卷'));
    await tester.tap(find.text('仿真试卷'));
    await waitFor(tester, find.text(material));
    await tester.tap(find.text(material));
    await waitFor(tester, find.text('原卷分析草稿'));
    expect(find.textContaining('识别到 2 道编号题'), findsOneWidget);
    await tester.dragUntilVisible(
      find.byTooltip('增加题数').first,
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    await tester.tap(find.byTooltip('增加题数').first);
    await tester.pump();
    final existing = await tester.runAsync(() async {
      final cid = app.api.selectedCourse!;
      final response = await app.api.get('/courses/$cid/exams');
      return app.items(response).map((exam) => exam['id'].toString()).toSet();
    });
    await tester.dragUntilVisible(
      find.text('确认蓝图并生成练习卷'),
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    await tester.tap(find.text('确认蓝图并生成练习卷'));
    // The bottom submit button is lazily built only when it is scrolled into view.
    await waitFor(tester, find.byType(TextFormField), tries: 350);
    final result = await tester.runAsync(() async {
      final cid = app.api.selectedCourse!;
      return await app.api.get('/courses/$cid/exams');
    });
    final exam = app
        .items(result)
        .firstWhere(
          (x) => x['title'] == '原卷分析练习卷' && !existing!.contains(x['id']),
        );
    expect(exam['items'].length, 3);
    expect(exam['blueprint_snapshot']['slots'][0]['count'], 2);
    expect(exam['blueprint_snapshot']['slots'].length, 2);
  });
}
