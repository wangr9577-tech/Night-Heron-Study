import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_practice_page.dart';
import 'package:zhi_ai/local_review_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('schedule a question and record a self-rated review', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    final store = await LocalCourses.open();
    await store.add('测试课程');
    final id = (await store.list()).single['id'] as int;
    await store.addQuestion(id, '测试问题', '参考答案', '解析');
    await store.close();
    await tester.pumpWidget(MaterialApp(home: LocalPracticePage(courseId: id)));
    for (var i = 0; i < 80 && find.text('测试问题').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.text('测试问题'));
    await tester.tap(
      find.descendant(
        of: find.byType(LocalPracticePage),
        matching: find.text('测试问题'),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('加入复习计划'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('间隔复习'));
    for (var i = 0; i < 80 && find.text('现在可以复习').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('现在可以复习'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(LocalReviewPage),
        matching: find.text('测试问题'),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('查看参考答案'));
    await tester.pump();
    await tester.tap(find.text('记得'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('下次复习：'), findsOneWidget);
    final check = await LocalCourses.open();
    expect(await check.db.query('local_review_history'), hasLength(1));
    expect((await check.db.query('local_reviews')).single['interval_days'], 1);
    await check.close();
    expect(tester.takeException(), isNull);
  });
}
