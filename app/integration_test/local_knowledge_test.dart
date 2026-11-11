import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_knowledge.dart';
import 'package:zhi_ai/local_knowledge_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('create a sourced concept and a prerequisite on Android', (
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
    await store.addNote(id, '知识来源', '课程资料');
    final graph = LocalKnowledge(store.db, id);
    await graph.addConcept('基础');
    await graph.addConcept('进阶');
    await store.close();
    await tester.pumpWidget(
      MaterialApp(home: LocalKnowledgePage(courseId: id)),
    );
    for (var i = 0; i < 50 && find.text('新建知识点').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('新建知识点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新知识');
    await tester.tap(find.text('关联资料（可选）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识来源').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    for (var i = 0; i < 60 && (find.byType(AlertDialog).evaluate().isNotEmpty || find.text('新知识').evaluate().isEmpty); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('新知识'), findsOneWidget);
    final checkedStore = await LocalCourses.open();
    final checkedNodes = await LocalKnowledge(checkedStore.db, id).concepts();
    expect(
      checkedNodes.firstWhere((n) => n['title'] == '新知识')['source_title'],
      '知识来源',
    );
    await checkedStore.close();
    await tester.ensureVisible(find.text('新知识'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('来源：知识来源'), findsOneWidget);
    await tester.tap(find.text('建立关系'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 60 && find.text('前置关系').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('前置关系'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
