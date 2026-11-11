import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zhi_ai/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('server session can enter and leave local mode without logout', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use an isolated emulator');
    final previousClient = app.api.client;
    app.api.token = 'test-token';
    app.api.client = MockClient((request) async {
      if (request.url.path.endsWith('/courses'))
        return http.Response(jsonEncode({'items': []}), 200);
      if (request.url.path.endsWith('/users/me'))
        return http.Response(jsonEncode({'username': 'test'}), 200);
      return http.Response('{}', 200);
    });
    try {
      await tester.pumpWidget(const app.ZhiApp(signedIn: true));
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byTooltip('本地体验'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('啄知 AI · 本地体验'), findsOneWidget);
      expect(find.text('返回服务器'), findsOneWidget);
      await tester.tap(find.text('返回服务器'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('本地体验'), findsOneWidget);
      expect(app.api.token, 'test-token');
      expect(tester.takeException(), isNull);
    } finally {
      app.api.client.close();
      app.api.client = previousClient;
      app.api.token = null;
    }
  });
}
