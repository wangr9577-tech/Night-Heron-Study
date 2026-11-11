import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/focus_store.dart';
import 'package:zhi_ai/local_growth_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('pet customization migration keeps existing growth', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    final location = path.join(await getDatabasesPath(), 'focus_local.db');
    await deleteDatabase(location);
    final old = await openDatabase(
      location,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE local_pet (id INTEGER PRIMARY KEY, exp INTEGER NOT NULL)',
        );
        await db.execute('INSERT INTO local_pet VALUES (1, 35)');
      },
    );
    await old.close();
    final migrated = await FocusStore.open();
    expect((await migrated.pet())['exp'], 35);
    await migrated.customizePet('夜鹭', 'bird_blue');
    expect((await migrated.pet())['avatar_key'], 'bird_blue');
    await migrated.close();
  });
  testWidgets('focus rewards can buy and feed the local pet once', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await deleteDatabase(path.join(await getDatabasesPath(), 'focus_local.db'));
    final store = await FocusStore.open();
    final id = await store.start(
      '学习',
      5,
      at: DateTime.now().subtract(const Duration(minutes: 6)),
    );
    expect(await store.complete(id), isTrue);
    await store.close();
    await tester.pumpWidget(const MaterialApp(home: LocalGrowthPage()));
    for (var i = 0; i < 50 && find.text('本机积分：5').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('本机积分：5'), findsOneWidget);
    await tester.ensureVisible(find.text('兑换'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('兑换'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('本机积分：0'), findsOneWidget);
    await tester.ensureVisible(find.text('投喂谷粒 · 经验 +5'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('投喂谷粒 · 经验 +5'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('等级 1 · 经验 5'), findsOneWidget);
    await tester.ensureVisible(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '夜鹭');
    await tester.ensureVisible(find.text('晴蓝'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('晴蓝'));
    await tester.ensureVisible(find.text('保存名字与配色'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('保存名字与配色'));
    await tester.pump(const Duration(seconds: 2));
    final check = await FocusStore.open();
    expect((await check.pet())['name'], '夜鹭');
    expect((await check.pet())['avatar_key'], 'bird_blue');
    await check.close();
    expect(tester.takeException(), isNull);
  });
}
