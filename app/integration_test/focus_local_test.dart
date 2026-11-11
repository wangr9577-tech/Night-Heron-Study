import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:zhi_ai/focus_page.dart';
import 'package:zhi_ai/focus_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local focus timer survives reopening and reports completed time',
    (tester) async {
      const isolated = bool.fromEnvironment('INTEGRATION_TEST_ISOLATED');
      if (!isolated)
        throw TestFailure('Use a disposable isolated Android emulator.');
      final dbPath = path.join(await getDatabasesPath(), 'focus_local.db');
      await deleteDatabase(dbPath);
      final store = await FocusStore.open();
      await store.start(
        '阅读',
        15,
        at: DateTime.now().subtract(const Duration(minutes: 21)),
      );
      await store.close();
      await tester.pumpWidget(const MaterialApp(home: FocusPage()));
      for (var i = 0; i < 50 && find.text('开始专注').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('开始专注'), findsOneWidget);
      expect(find.text('阅读'), findsWidgets);
      await tester.ensureVisible(find.text('开始专注'));
      await tester.tap(find.text('开始专注'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('放弃本次专注'), findsOneWidget);
      await tester.tap(find.text('放弃本次专注'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('开始专注'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('focus-category-阅读')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: find.byKey(const ValueKey('focus-category-阅读')), matching: find.text('15 分钟')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      final reopened = await FocusStore.open();
      final rows = await reopened.completed();
      expect(rows, hasLength(1));
      expect(rows.first['category'], '阅读');
      await reopened.close();
    },
  );
  testWidgets('completed focus starts a persistent break that can be skipped', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await deleteDatabase(path.join(await getDatabasesPath(), 'focus_local.db'));
    final store = await FocusStore.open();
    await store.start(
      '学习',
      15,
      at: DateTime.now().subtract(const Duration(minutes: 16)),
    );
    await store.close();
    await tester.pumpWidget(const MaterialApp(home: FocusPage()));
    for (var i = 0; i < 60 && find.text('结束休息').evaluate().isEmpty; i++)
      await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('休息 5 分钟，不计积分'), findsOneWidget);
    await tester.tap(find.text('结束休息'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('开始专注'), findsOneWidget);
    final reopened = await FocusStore.open();
    expect(await reopened.activeRest(), isNull);
    expect((await reopened.completed()).single['points'], 15);
    await reopened.close();
  });
}
