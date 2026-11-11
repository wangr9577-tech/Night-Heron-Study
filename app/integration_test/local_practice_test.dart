import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_practice_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local self-test records incorrect and correct answers', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    final store = await LocalCourses.open();
    await store.add('数学');
    final courseId = (await store.list()).single['id'] as int;
    await store.close();
    await tester.pumpWidget(
      MaterialApp(home: LocalPracticePage(courseId: courseId)),
    );
    for (var i = 0; i < 50 && find.text('新建题目').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('新建题目'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '2 + 2 = ?');
    await tester.enterText(find.byType(TextField).at(1), '4');
    await tester.ensureVisible(find.text('保存题目'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('保存题目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 + 2 = ?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('与参考答案不一致'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('只看最近答错的题'));
    await tester.tap(find.text('只看最近答错的题'));
    await tester.pumpAndSettle();
    expect(find.text('上次作答：5'), findsOneWidget);
    await tester.tap(find.text('2 + 2 = ?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('与参考答案一致'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('目前没有最近答错的题。'), findsOneWidget);
    final verify = await LocalCourses.open();
    expect(await verify.db.query('local_attempts'), hasLength(2));
    await verify.close();
    expect(tester.takeException(), isNull);
  });
}
