import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/ai_exam.dart';
import 'package:zhi_ai/ai_settings.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_exam.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android AI request and local paper persistence', (tester) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    await tester.runAsync(() async {
      await deleteDatabase(
        path.join(await getDatabasesPath(), 'local_courses.db'),
      );
      final store = await LocalCourses.open();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        await store.add('测试课程');
        final course = (await store.list()).single['id'] as int;
        await store.addNote(course, '测试资料', '这里是合成测试资料，包含测试原文。');
        final note = (await store.notes(course)).single;
        final served = server.first.then((request) async {
          expect(request.uri.path, '/v1/chat/completions');
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['messages'].last['content'], contains('测试原文'));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'questions': [
                        {
                          'prompt': '资料包含什么？',
                          'answer': '测试原文',
                          'explanation': '见资料',
                          'source_quote': '测试原文',
                        },
                      ],
                    }),
                  },
                },
              ],
            }),
          );
          await request.response.close();
        });
        final settings = AiSettings(
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          model: 'mock-model',
          key: 'test',
        );
        final questions = await generateAiExam(
          settings,
          note['body'] as String,
          1,
          '测试',
        );
        await served;
        final exams = LocalExam(store.db, course);
        await expectLater(
          exams.createFromAi('不应保存', note['id'] as int, settings.model, [
            AiExamQuestion(
              prompt: '题',
              answer: '答',
              explanation: '',
              quote: '虚构',
            ),
          ]),
          throwsArgumentError,
        );
        expect(await exams.list(), isEmpty);
        final id = await exams.createFromAi(
          'AI 卷',
          note['id'] as int,
          settings.model,
          questions,
        );
        final saved = await exams.load(id);
        expect((saved['items'] as List).single['quote'], '测试原文');
        await exams.saveAnswer(
          id,
          (saved['items'] as List).single['question_id'] as int,
          '测试原文',
        );
        await exams.submit(id);
        expect((await exams.load(id))['correct_count'], 1);
      } finally {
        await server.close(force: true);
        await store.close();
      }
    });
  });
}
