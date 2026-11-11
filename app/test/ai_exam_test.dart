import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhi_ai/ai_exam.dart';
import 'package:zhi_ai/ai_settings.dart';

void main() {
  const settings = AiSettings(
    endpoint: 'https://example.test/v1',
    model: 'demo',
    key: 'test',
  );
  test(
    'sends selected excerpt and accepts grounded structured question',
    () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['model'], 'demo');
        expect(body['messages'].last['content'], contains('学习资料是测试原文'));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'questions': [
                      {
                        'prompt': '什么是资料？',
                        'answer': '测试原文',
                        'explanation': '解释',
                        'source_quote': '测试原文',
                      },
                    ],
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final q = await generateAiExam(
        settings,
        '学习资料是测试原文',
        1,
        '',
        client: client,
      );
      expect(q.single.quote, '测试原文');
    },
  );
  test('rejects invented source and malformed output', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'questions': [
                    {
                      'prompt': '题',
                      'answer': '答',
                      'explanation': '',
                      'source_quote': '虚构引用',
                    },
                  ],
                }),
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await expectLater(
      generateAiExam(settings, '真实资料', 1, '', client: client),
      throwsFormatException,
    );
  });
}
