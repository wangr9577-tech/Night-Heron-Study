import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhi_ai/main.dart';

void main() {
  setUp(() => api.token = 'student');
  tearDown(() {
    api.token = null;
    api.client.close();
    api.client = http.Client();
  });
  testWidgets(
    'graph displays actual relations and patches changed relation atomically',
    (tester) async {
      final calls = <http.Request>[];
      api.client = MockClient((r) async {
        calls.add(r);
        if (r.method == 'GET' && r.url.path.endsWith('/mastery'))
          return http.Response(
            jsonEncode({
              'items': [
                {'concept_id': 'a', 'mastery': 0.75},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        if (r.method == 'GET')
          return http.Response(
            jsonEncode({
              'nodes': [
                {
                  'id': 'a',
                  'title': '集合',
                  'description': '基础',
                  'source_refs': [],
                },
                {
                  'id': 'b',
                  'title': '函数',
                  'description': '进阶',
                  'source_refs': [],
                },
              ],
              'edges': [
                {
                  'id': 'e1',
                  'from_id': 'a',
                  'to_id': 'b',
                  'type': 'prerequisite',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        return http.Response(
          jsonEncode({'id': 'e2'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await tester.pumpWidget(
        const MaterialApp(home: AdvancedGraphPage(courseId: 'course')),
      );
      await tester.pumpAndSettle();
      expect(find.text('基础 · 掌握度 75%'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('集合 → 函数'), 200);
      expect(find.text('集合 → 函数'), findsOneWidget);
      await tester.ensureVisible(find.byType(PopupMenuButton<String>));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑关系'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('前置关系').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('相关关系').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final patch = calls.singleWhere((r) => r.method == 'PATCH');
      expect(patch.url.path, '/api/v1/courses/course/knowledge/edges/e1');
      expect(jsonDecode(patch.body), {
        'from_id': 'a',
        'to_id': 'b',
        'type': 'related',
      });
      expect(
        calls.where((r) => r.method == 'DELETE' || r.method == 'POST'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new concept requires and preserves source metadata', (
    tester,
  ) async {
    Map<String, dynamic>? submitted;
    api.client = MockClient((r) async {
      dynamic result;
      if (r.url.path.endsWith('/mastery')) {
        result = {'items': []};
      } else if (r.url.path.endsWith('/knowledge')) {
        result = {'nodes': [], 'edges': []};
      } else if (r.url.path.endsWith('/materials')) {
        result = {
          'items': [
            {'id': 'm1', 'filename': 'lesson.txt', 'status': 'ready'},
          ],
        };
      } else if (r.url.path.endsWith('/materials/m1')) {
        result = {
          'chunks': [
            {
              'chunk_id': 'chunk1',
              'page': 1,
              'text': '原文',
              'start': 0,
              'end': 2,
            },
          ],
        };
      } else if (r.method == 'POST') {
        submitted = jsonDecode(r.body);
        result = {'id': 'c1'};
      } else {
        return http.Response('unexpected request', 404);
      }
      return http.Response(
        jsonEncode(result),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      const MaterialApp(home: AdvancedGraphPage(courseId: 'course')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加知识点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '新知识');
    await tester.ensureVisible(find.text('资料'));
    await tester.tap(find.text('资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lesson.txt').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('来源片段'));
    await tester.tap(find.text('来源片段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 页 · 原文').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(submitted!['title'], '新知识');
    expect(submitted!['source_refs'], [
      {
        'material_id': 'm1',
        'chunk_id': 'chunk1',
        'page': 1,
        'quote': '原文',
        'start': 0,
        'end': 2,
      },
    ]);
    expect(tester.takeException(), isNull);
  });
}
