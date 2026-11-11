import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhi_ai/main.dart';

void main() {
  setUp(() => api.token = 'reviewer');
  tearDown(() {
    api.token = null;
    api.client.close();
    api.client = http.Client();
  });

  testWidgets(
    'mistake confirmation sends reviewer input with original source',
    (tester) async {
      Map<String, dynamic>? submitted;
      api.client = MockClient((request) async {
        if (request.method == 'GET') return http.Response('missing', 404);
        submitted = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.path, '/api/v1/courses/c1/mistakes/m1/confirm');
        return http.Response('{}', 200);
      });
      final ref = {
        'material_id': 'm',
        'chunk_id': 'c',
        'page': 1,
        'quote': '原文',
        'start': 0,
        'end': 2,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: MistakeReviewPage(
            courseId: 'c1',
            entry: {
              'id': 'm1',
              'corrected_question': '计算题',
              'original_answer': '2',
              'available_concepts': [
                {'id': 'k1', 'title': '运算'},
              ],
              'source_refs': [ref],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.textContaining('第 1 页 · 原文'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.byType(CheckboxListTile));
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.dragUntilVisible(
        field('标准答案'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.enterText(field('标准答案'), '3');
      await tester.dragUntilVisible(
        field('解析与评分要点'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.enterText(field('解析与评分要点'), '先计算并核对结果。');
      await tester.dragUntilVisible(
        find.text('确认校对'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.tap(find.text('确认校对'));
      await tester.pumpAndSettle();
      expect(submitted!['question']['answer'], '3');
      expect(submitted!['question']['concept_ids'], ['k1']);
      expect(submitted!['question']['source_refs'], [ref]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reviewer cannot submit an invalid score or short rationale', (
    tester,
  ) async {
    var calls = 0;
    api.client = MockClient((request) async {
      calls++;
      return http.Response('{}', 200);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AttemptReviewPage(
          courseId: 'c1',
          entry: {
            'id': 'a1',
            'submitted_answer': '答案',
            'question': {
              'prompt': '题目',
              'answer': '参考答案',
              'rubric': ['评分要点'],
            },
          },
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '2');
    await tester.enterText(find.byType(TextField).last, '短');
    await tester.ensureVisible(find.text('确认评分'));
    await tester.tap(find.text('确认评分'));
    await tester.pump();
    expect(calls, 0);
    expect(find.textContaining('分数应在 0 到 1 之间'), findsOneWidget);
  });

  testWidgets('course owner can add a member without granting review rights', (
    tester,
  ) async {
    Map<String, dynamic>? added;
    api.client = MockClient((request) async {
      if (request.method == 'POST') {
        added = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }
      if (request.url.path.endsWith('/users/me')) {
        return http.Response(jsonEncode({'user_id': 'owner'}), 200);
      }
      return http.Response(
        jsonEncode({
          'items': [
            {'user_id': 'owner', 'role': 'owner'},
          ],
        }),
        200,
      );
    });
    await tester.pumpWidget(
      const MaterialApp(home: CourseMembersPage(courseId: 'c1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('按用户 ID 添加成员'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'reviewer-id');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(added, {'user_id': 'reviewer-id'});
    expect(find.textContaining('不会自动授予审核权限'), findsOneWidget);
  });
}
