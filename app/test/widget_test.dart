import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.token = 'test';
  });
  tearDown(() {
    api.token = null;
    api.client.close();
    api.client = http.Client();
  });
  testWidgets('remote home view loads and reloads without async setState', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteView(
            load: () async => ++loads,
            builder: (value, reload) => Column(
              children: [
                Text('loaded $value'),
                TextButton(onPressed: reload, child: const Text('reload')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('loaded 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('reload'));
    await tester.pumpAndSettle();
    expect(find.text('loaded 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('login and registration screens are available', (tester) async {
    await tester.pumpWidget(const ZhiApp());
    expect(find.text('啄知 AI'), findsOneWidget);
    await tester.tap(find.text('创建账号'));
    await tester.pump();
    expect(find.text('注册'), findsOneWidget);
  });
  testWidgets('feeding a pet refreshes companion growth on return', (
    tester,
  ) async {
    var exp = 0;
    var food = 1;
    var petReads = 0;
    api.client = MockClient((request) async {
      final path = request.url.path;
      dynamic data;
      if (path.endsWith('/companion/pets')) {
        petReads++;
        data = {
          'items': [
            {
              'pet_id': 'p1',
              'name': '小啄',
              'growth': {'level': 1, 'exp': exp},
            },
          ],
        };
      } else if (path.endsWith('/growth-summary')) {
        data = {
          'exp_in_level': exp,
          'exp_to_next_level': 100 - exp,
          'feed_count': 1 - food,
          'interaction_count': 0,
          'interacted_today': false,
          'recent_events': [],
        };
      } else if (path.endsWith('/rewards/points')) {
        data = {'balance': 15};
      } else if (path.endsWith('/rewards/shop')) {
        data = {
          'items': [
            {'item_id': 'itm_apple', 'name': '苹果', 'price': 10, 'desc': '水果'},
          ],
        };
      } else if (path.endsWith('/rewards/bag')) {
        data = {
          'items': food > 0
              ? [
                  {'item_id': 'itm_apple', 'qty': food},
                ]
              : [],
        };
      } else if (path.endsWith('/rewards/feed')) {
        expect(jsonDecode(request.body)['pet_id'], 'p1');
        food--;
        exp += 5;
        data = {'ok': true};
      } else {
        return http.Response('unexpected request: $path', 404);
      }
      return http.Response(
        jsonEncode(data),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TickerMode(enabled: false, child: CompanionPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('等级 1 · 经验 0'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('积分商店与背包'), 250);
    await tester.ensureVisible(find.text('积分商店与背包'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('积分商店与背包'));
    await tester.pumpAndSettle();
    expect(find.text('苹果'), findsNWidgets(2));
    expect(find.text('itm_apple'), findsNothing);
    await tester.tap(find.text('投喂'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('等级 1 · 经验 5'), findsOneWidget);
    expect(petReads, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'create companion through dialog reloads without a framework exception',
    (tester) async {
      var created = false;
      api.client = MockClient((r) async {
        if (r.url.path.endsWith('/growth-summary')) {
          return http.Response(
            jsonEncode({
              'exp_in_level': 0,
              'exp_to_next_level': 100,
              'feed_count': 0,
              'interaction_count': 0,
              'interacted_today': false,
              'recent_events': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.method == 'POST') {
          expect(jsonDecode(r.body)['name'], '小啄');
          created = true;
        }
        return http.Response(
          jsonEncode({
            'items': created
                ? [
                    {
                      'pet_id': 'p1',
                      'name': '小啄',
                      'growth': {'level': 1, 'exp': 0},
                    },
                  ]
                : [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TickerMode(enabled: false, child: CompanionPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建宠物'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '小啄');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('小啄'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'daily companion interaction updates growth and disables repeat',
    (tester) async {
      var interacted = false;
      var requests = 0;
      api.client = MockClient((r) async {
        final path = r.url.path;
        dynamic result;
        if (path.endsWith('/companion/pets')) {
          result = {
            'items': [
              {
                'pet_id': 'p1',
                'name': '小啄',
                'growth': {'level': 1, 'exp': interacted ? 3 : 0},
              },
            ],
          };
        } else if (path.endsWith('/growth-summary')) {
          result = {
            'exp_in_level': interacted ? 3 : 0,
            'exp_to_next_level': interacted ? 97 : 100,
            'feed_count': 0,
            'interaction_count': interacted ? 1 : 0,
            'interacted_today': interacted,
            'recent_events': interacted
                ? [
                    {
                      'type': 'play',
                      'exp_delta': 3,
                      'at': '2026-11-08T01:00:00Z',
                    },
                  ]
                : [],
          };
        } else if (path.endsWith('/interact') && r.method == 'POST') {
          requests++;
          interacted = true;
          result = {'reaction_text': '谢谢你的陪伴！', 'already_done': false};
        } else {
          return http.Response('unexpected $path', 404);
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TickerMode(enabled: false, child: CompanionPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('距离下一级还需 100 经验'), findsOneWidget);
      await tester.tap(find.byKey(const Key('companion-interact')));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('今天已陪伴'), findsOneWidget);
      expect(find.text('距离下一级还需 97 经验'), findsOneWidget);
      expect(find.text('每日陪伴'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('companion-interact')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'oral practice finalizes automatically when target turns are reached',
    (tester) async {
      final paths = <String>[];
      api.client = MockClient((r) async {
        paths.add(r.url.path);
        dynamic result;
        if (r.url.path.endsWith('/turn')) {
          result = {
            'turn': {
              'reply_text': 'Good work!',
              'feedback': {'grammar_fix': null},
            },
            'finished': true,
          };
        } else if (r.url.path.endsWith('/finish')) {
          result = {
            'summary': {
              'tips': ['Speak clearly', 'Keep practising'],
            },
          };
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
        const MaterialApp(
          home: OralSession(sessionId: 's1', opening: 'Hello'),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Hello there');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(paths, [
        '/api/v1/speech/oral/sessions/s1/turn',
        '/api/v1/speech/oral/sessions/s1/finish',
      ]);
      expect(find.text('伙伴：Good work!'), findsOneWidget);
      expect(find.text('练习总结：Speak clearly；Keep practising'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'exam uses reviewed original-paper analysis as editable blueprint',
    (tester) async {
      Map<String, dynamic>? submittedBlueprint;
      api.client = MockClient((r) async {
        final path = r.url.path;
        dynamic result;
        if (path.endsWith('/knowledge')) {
          result = {
            'nodes': [
              {'id': 'c1', 'title': 'Accuracy'},
              {'id': 'c2', 'title': 'Recall'},
            ],
          };
        } else if (path.endsWith('/exams/analyze')) {
          expect(jsonDecode(r.body)['material_id'], 'm1');
          result = {
            'parsed_questions': [
              {
                'number': 1,
                'prompt': 'Accuracy original problem',
                'concept_ids': ['c1'],
                'points': 5,
              },
            ],
            'suggested_slots': [
              {
                'concept_id': 'c1',
                'count': 2,
                'kind': 'cloze',
                'difficulty': 'medium',
                'points': 10.0,
              },
              {
                'concept_id': 'c2',
                'count': 1,
                'kind': 'numeric',
                'difficulty': 'easy',
                'points': 8.0,
              },
            ],
            'warnings': [],
          };
        } else if (path.endsWith('/exam-blueprints')) {
          submittedBlueprint = jsonDecode(r.body);
          result = {'id': 'b1'};
        } else if (path.endsWith('/exams') && r.method == 'POST') {
          result = {'job_id': 'j1'};
        } else if (path.endsWith('/jobs/j1')) {
          result = {
            'status': 'succeeded',
            'result_ref': {'id': 'e1'},
          };
        } else if (path.endsWith('/exams/e1')) {
          result = {'title': 'Practice', 'questions': []};
        } else {
          return http.Response('unexpected $path', 404);
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: NativeExamPage(courseId: 'course', materialId: 'm1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('原卷分析草稿'), findsOneWidget);
      expect(find.textContaining('识别到 1 道编号题'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('增加题数').first);
      await tester.tap(find.byTooltip('增加题数').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('确认蓝图并生成练习卷'), 300);
      await tester.ensureVisible(find.text('确认蓝图并生成练习卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认蓝图并生成练习卷'));
      await tester.pumpAndSettle();
      expect(submittedBlueprint!['slots'], hasLength(2));
      expect(submittedBlueprint!['slots'][0]['concept_id'], 'c1');
      expect(submittedBlueprint!['slots'][0]['count'], 3);
      expect(submittedBlueprint!['slots'][1]['concept_id'], 'c2');
      expect(submittedBlueprint!['slots'][1]['kind'], 'numeric');
      expect(submittedBlueprint!['slots'][1]['points'], 8);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'material correction is saved before explicit knowledge extraction',
    (tester) async {
      final requests = <http.Request>[];
      api.client = MockClient((r) async {
        requests.add(r);
        dynamic result;
        if (r.method == 'GET') {
          result = {
            'chunks': [
              {
                'chunk_id': 'ch1',
                'page': 1,
                'text': 'OCR mistake',
                'needs_confirmation': true,
              },
            ],
          };
        } else if (r.method == 'PATCH') {
          expect(jsonDecode(r.body), {
            'chunk_id': 'ch1',
            'text': 'corrected text',
          });
          result = {
            'chunks': [
              {
                'chunk_id': 'ch1',
                'page': 1,
                'text': 'corrected text',
                'needs_confirmation': false,
              },
            ],
          };
        } else {
          expect(r.url.path, '/api/v1/courses/c1/knowledge/extract');
          expect(jsonDecode(r.body)['material_ids'], ['m1']);
          result = {'nodes': []};
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: MaterialReviewPage(courseId: 'c1', materialId: 'm1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.tap(find.text('校对'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'corrected text');
      await tester.tap(find.text('保存校对'));
      await tester.pumpAndSettle();
      expect(find.text('corrected text'), findsOneWidget);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.tap(find.text('确认文字并提取知识点'));
      await tester.pumpAndSettle();
      expect(requests.map((r) => r.method), ['GET', 'PATCH', 'POST']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('practice uses a real session, task identity, and event sync', (
    tester,
  ) async {
    final requests = <http.Request>[];
    api.client = MockClient((r) async {
      requests.add(r);
      final path = r.url.path;
      dynamic result;
      if (path.endsWith('/questions/q1')) {
        result = {'id': 'q1', 'prompt': 'What is 2 + 2?', 'options': {}};
      } else if (path.endsWith('/questions/q1/sessions')) {
        result = {'id': 's1'};
      } else if (path.endsWith('/attempts')) {
        result = {
          'attempt_id': 'a1',
          'score': 1,
          'status': 'graded',
          'solution_viewed': false,
          'evidence_weight': 1,
          'grading_rationale': 'Correct',
        };
      } else if (path.endsWith('/rewards/consume-events')) {
        result = {
          'awarded': [
            {'points': 25},
          ],
          'has_more': false,
        };
      } else {
        return http.Response('not found: $path', 404);
      }
      return http.Response(
        jsonEncode(result),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: PracticePage(courseId: 'c1', questionId: 'q1', taskId: 't1'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('What is 2 + 2?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('practice-answer')), '4');
    await tester.ensureVisible(find.byKey(const Key('submit-practice')));
    await tester.tap(find.byKey(const Key('submit-practice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('practice-result')), findsOneWidget);
    expect(find.text('本次同步获得 25 积分'), findsOneWidget);
    final attempt = requests.singleWhere(
      (r) => r.url.path.endsWith('/attempts'),
    );
    expect(jsonDecode(attempt.body)['source_task_id'], 't1');
    expect(jsonDecode(attempt.body)['practice_session_id'], 's1');
    expect(attempt.headers['Idempotency-Key'], isNotEmpty);
    expect(
      requests
          .where((r) => r.url.path.endsWith('/rewards/consume-events'))
          .length,
      1,
    );
  });
  testWidgets('lesson restores position and saves page changes', (
    tester,
  ) async {
    final requests = <http.Request>[];
    api.client = MockClient((r) async {
      requests.add(r);
      dynamic value;
      if (r.method == 'PUT') {
        value = {'ok': true};
      } else if (r.url.path.endsWith('/position')) {
        value = {'page_id': 'p2', 'segment_id': 's2'};
      } else {
        value = {
          'title': 'Lesson',
          'generation_warnings': [
            {
              'concept_id': 'c1',
              'code': 'INSUFFICIENT_SOURCE',
              'message': '该知识点来源不足，未生成随堂练习',
            },
          ],
          'pages': [
            {
              'page_id': 'p1',
              'title': 'First',
              'elements': [
                {'element_id': 'e1', 'text': 'First text'},
              ],
              'narration_segments': [
                {
                  'segment_id': 's1',
                  'text': 'First',
                  'highlight_element_ids': ['e1'],
                },
              ],
            },
            {
              'page_id': 'p2',
              'title': 'Second',
              'elements': [
                {'element_id': 'e2', 'text': 'Second text'},
              ],
              'narration_segments': [
                {
                  'segment_id': 's2',
                  'text': 'Second',
                  'highlight_element_ids': ['e2'],
                },
              ],
            },
          ],
        };
      }
      return http.Response(
        jsonEncode(value),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: LessonPlayerPage(lessonId: 'l1', courseId: 'c1'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(find.text('该知识点来源不足，未生成随堂练习'), findsOneWidget);
    await tester.ensureVisible(find.text('上一页'));
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    final saved = requests.singleWhere((r) => r.method == 'PUT');
    expect(jsonDecode(saved.body)['page_id'], 'p1');
  });
  testWidgets('import shows actual service and select file action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: UploadPage(courseId: 'c1', mistake: false)),
    );
    expect(find.text('已连接真实资料处理服务'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
  });
}
