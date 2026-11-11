import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhi_ai/main.dart';

void main() {
  testWidgets(
    'pet color and name persist while unconfigured generation is disabled',
    (tester) async {
      Map<String, dynamic>? saved;
      api.token = 'test';
      api.client = MockClient((request) async {
        if (request.url.path.endsWith('/sprite-capabilities')) {
          return http.Response(
            jsonEncode({'generation_configured': false}),
            200,
          );
        }
        if (request.method == 'PATCH') {
          saved = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{}', 200);
        }
        return http.Response('missing', 404);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: false,
            child: PetCustomizationPage(
              pet: {'pet_id': 'p1', 'name': '小啄', 'avatar_key': 'bird_1'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '蓝蓝');
      await tester.tap(find.text('晴蓝'));
      await tester.tap(find.text('保存名字与配色'));
      await tester.pumpAndSettle();
      expect(saved, {'name': '蓝蓝', 'avatar_key': 'bird_blue'});
      await tester.dragUntilVisible(
        find.text('用 AI 生成图集'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '用 AI 生成图集'),
      );
      expect(button.onPressed, isNull);
      await tester.dragUntilVisible(
        find.textContaining('图集生成服务尚未配置'),
        find.byType(ListView),
        const Offset(0, -150),
      );
      expect(find.textContaining('图集生成服务尚未配置'), findsOneWidget);
      api.token = null;
      api.client.close();
      api.client = http.Client();
    },
  );

  testWidgets('generated sprite is not claimed visible if reloading fails', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    api.token = 'test';
    api.client = MockClient((request) async {
      if (request.url.path.endsWith('/sprite-capabilities')) {
        return http.Response(jsonEncode({'generation_configured': true}), 200);
      }
      if (request.url.path.endsWith('/sprite/generate')) {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }
      return http.Response('missing', 404);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: PetCustomizationPage(
            pet: {'pet_id': 'p1', 'name': '小啄', 'avatar_key': 'bird_1'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('用 AI 生成图集'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.ensureVisible(find.text('用 AI 生成图集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用 AI 生成图集'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '戴围巾的小鸟');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(sent, {'description': '戴围巾的小鸟'});
    await tester.dragUntilVisible(
      find.textContaining('暂时无法读取结果'),
      find.byType(ListView),
      const Offset(0, -150),
    );
    expect(find.text('新形象已生成并保存。'), findsNothing);
    api.token = null;
    api.client.close();
    api.client = http.Client();
  });
}
