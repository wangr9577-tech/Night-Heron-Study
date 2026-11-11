import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zhi_ai/ai_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('secure configuration and network request work on Android', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED')) {
      throw TestFailure('Use a disposable isolated Android emulator.');
    }
    await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = server.first.then((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        expect(request.headers.value('authorization'), 'Bearer test-only-key');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['model'], 'test-model');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '模拟服务的回答'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      try {
        final original = AiSettings(
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          model: 'test-model',
          key: 'test-only-key',
        );
        await original.save();
        final loaded = await AiSettings.load();
        expect(loaded, isNotNull);
        expect(await loaded!.ask('测试问题'), '模拟服务的回答');
        await served;
      } finally {
        await AiSettings.clear();
        await server.close(force: true);
      }
    });
  });
}
