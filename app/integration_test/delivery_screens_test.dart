import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/focus_store.dart';
import 'package:zhi_ai/focus_page.dart';
import 'package:zhi_ai/local_growth_page.dart';
import 'package:zhi_ai/local_home.dart';
import 'package:zhi_ai/local_course_page.dart';
import 'package:zhi_ai/local_courses.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture real local feature screens with labelled fixtures', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    final key = GlobalKey();
    Widget wrap(Widget home) => RepaintBoundary(
      key: key,
      child: MaterialApp(
        builder: (_, child) => Column(
          children: [
            const Material(
              color: Colors.amber,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '自动化演示｜合成学习记录 · 模拟 AI 服务',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
            Expanded(child: child!),
          ],
        ),
        home: home,
      ),
    );
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final root = await getExternalStorageDirectory();
        final folder = Directory('${root!.path}/delivery_demo');
        await folder.create(recursive: true);
        await File('${folder.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List(), flush: true);
        image.dispose();
      });
    }

    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    final store = await LocalCourses.open();
    await store.add('Data Science · 演示课程');
    final course = (await store.list()).single['id'] as int;
    await store.addNote(course, '分类指标与公式', r'''# 分类指标

准确率是分类预测中正确预测的比例。

$$Accuracy = \frac{TP+TN}{TP+TN+FP+FN}$$

| 指标 | 含义 |
| --- | --- |
| Precision | 预测为正的样本中真正为正的比例 |
| Recall | 真实为正的样本中被预测为正的比例 |

例：100 个样本预测正确 85 个，Accuracy 为 85%。
''', markdown: true);
    final note = (await store.notes(course)).single;
    await store.close();
    await tester.pumpWidget(wrap(const LocalHome()));
    for (var i = 0; i < 100 && find.text('本地课程').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await shot('01-home');
    await deleteDatabase(path.join(await getDatabasesPath(), 'focus_local.db'));
    final focus = await FocusStore.open();
    final now = DateTime.now();
    for (final entry in [(3, '学习', 25), (2, '阅读', 15), (1, '练习', 45)]) {
      final start = now.subtract(Duration(days: entry.$1));
      final id = await focus.start(entry.$2, entry.$3, at: start);
      expect(
        await focus.complete(id, at: start.add(Duration(minutes: entry.$3))),
        isTrue,
      );
      await focus.skipRest();
    }
    await focus.close();
    await tester.pumpWidget(wrap(const FocusPage()));
    for (var i = 0; i < 100 && find.text('开始专注').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await shot('02-focus-calendar');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('focus-category-阅读')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(seconds: 1));
    await shot('03-focus-statistics');
    await tester.pumpWidget(wrap(const LocalGrowthPage()));
    for (var i = 0; i < 100 && find.text('本机积分：85').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.ensureVisible(find.text('兑换'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('兑换'));
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('投喂谷粒 · 经验 +5'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('投喂谷粒 · 经验 +5'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('等级 1 · 经验 5'), findsOneWidget);
    await shot('04-pet-rewards');
    await tester.pumpWidget(wrap(LocalNotePage(note: note)));
    await tester.pump(const Duration(seconds: 2));
    await shot('05-markdown-math');
    // Give the host exporter time to preserve images before Flutter uninstalls.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
