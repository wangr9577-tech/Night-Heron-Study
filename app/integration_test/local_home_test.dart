import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_home.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline home stores courses without a server account', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use an isolated emulator');
    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    await tester.pumpWidget(const MaterialApp(home: LocalHome()));
    for (var i = 0; i < 50 && find.byTooltip('新建课程').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.tap(find.byTooltip('新建课程'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '离线课程');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('离线课程'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const MaterialApp(home: LocalHome()));
    for (var i = 0; i < 50 && find.text('离线课程').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('离线课程'), findsOneWidget);
  });
}
