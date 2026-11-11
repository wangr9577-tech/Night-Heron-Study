import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_search_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('search shows a local verbatim source without a server', (
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
    await store.addNote(
      id,
      'classification.txt',
      'Accuracy equals the fraction of correct predictions.',
    );
    await store.close();
    await tester.pumpWidget(MaterialApp(home: LocalSearchPage(courseId: id)));
    await tester.enterText(find.byType(TextField), 'Accuracy');
    await tester.tap(find.text('查找资料'));
    for (
      var i = 0;
      i < 100 && find.text('来源：classification.txt').evaluate().isEmpty;
      i++
    )
      await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('来源：classification.txt'), findsOneWidget);
    expect(
      find.text('Accuracy equals the fraction of correct predictions.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
