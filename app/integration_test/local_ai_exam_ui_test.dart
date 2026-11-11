import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/ai_settings.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_exam_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('AI paper is reviewed and saved through Android UI', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    final store = await LocalCourses.open();
    await store.add('界面测试课程');
    final course = (await store.list()).single['id'] as int;
    await store.addNote(course, '界面测试资料', '此资料含有测试原文，供模拟服务使用。');
    await store.close();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var sentSelectedSource = false;
    server.listen((request) async {
      requests++;
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      sentSelectedSource = body['messages'].last['content'].toString().contains('测试原文');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'questions': List.generate(
                    3,
                    (i) => {
                      'prompt': '模拟题 ${i + 1}',
                      'answer': '测试原文',
                      'explanation': '模拟解析',
                      'source_quote': '测试原文',
                    },
                  ),
                }),
              },
            },
          ],
        }),
      );
      await request.response.close();
    });
    try {
      await AiSettings(
        endpoint: 'http://127.0.0.1:${server.port}/v1',
        model: 'mock-model',
        key: 'test',
      ).save();
      await tester.pumpWidget(
        MaterialApp(home: LocalExamListPage(courseId: course)),
      );
      for (
        var i = 0;
        i < 100 && find.text('AI 根据资料出题').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.tap(find.text('AI 根据资料出题'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      for (var i = 0; i < 100 && find.text('发送资料并生成').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      for (
        var i = 0;
        i < 100 &&
            tester
                    .widget<FilledButton>(
                      find.widgetWithText(FilledButton, '发送资料并生成'),
                    )
                    .onPressed ==
                null;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.ensureVisible(find.text('发送资料并生成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送资料并生成'));
      for (var i = 0; i < 300 && find.text('第 1 题').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.scrollUntilVisible(find.text('确认并保存试卷'), 400, scrollable: find.byType(Scrollable).first, maxScrolls: 40);
      expect(find.text('确认并保存试卷'), findsOneWidget);
      expect(sentSelectedSource, isTrue);
      expect(requests, 1);
      await tester.ensureVisible(find.text('确认并保存试卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认并保存试卷'));
      for (
        var i = 0;
        i < 100 && find.text('AI 资料自测卷').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('AI 资料自测卷'), findsOneWidget);
      await tester.tap(find.text('AI 资料自测卷'));
      for (
        var i = 0;
        i < 100 && find.textContaining('模拟题 1').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('模拟题 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await AiSettings.clear();
      await server.close(force: true);
    }
  });
}
