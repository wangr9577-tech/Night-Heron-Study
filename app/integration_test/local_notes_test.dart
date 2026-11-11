import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_home.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('saved local Markdown opens in the course after restarting', (
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
    await store.addNote(id, '笔记.md', r'公式 $\frac{1}{2}$', markdown: true);
    await store.close();
    await tester.pumpWidget(const MaterialApp(home: LocalHome()));
    for (var i = 0; i < 50 && find.text('测试课程').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('测试课程'));
    for (var i = 0; i < 50 && find.text('笔记.md').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('笔记.md'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('笔记.md'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
