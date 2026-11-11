import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhi_ai/ai_settings.dart';

void main() {
  test('source text is sent only when explicitly supplied', () async {
    final settings = AiSettings(
      endpoint: 'https://example.org/v1',
      model: 'test',
      key: 'key',
    );
    final client = MockClient((request) async {
      final messages = jsonDecode(request.body)['messages'] as List;
      expect(messages.length, 3);
      expect(messages.last['content'], contains('被选择的资料'));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'answer'},
            },
          ],
        }),
        200,
      );
    });
    expect(
      await settings.ask('问题', sourceText: '被选择的资料', client: client),
      'answer',
    );
    client.close();
  });
  test('fetches and deduplicates service model names', () async {
    final settings = AiSettings(
      endpoint: 'https://example.org/v1/',
      model: '',
      key: 'test',
    );
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/models');
      expect(request.followRedirects, isFalse);
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'one'},
            {'id': 'one'},
            {'id': 'two'},
          ],
        }),
        200,
      );
    });
    expect(await settings.models(client: client), ['one', 'two']);
    client.close();
  });
  test('service accepts secure and loopback URLs only', () {
    expect(AiSettings.endpointUri('https://example.org/v1'), isNotNull);
    expect(AiSettings.endpointUri('http://10.0.2.2:11434/v1'), isNotNull);
    expect(AiSettings.endpointUri('http://remote.example/v1'), isNull);
    expect(AiSettings.endpointUri('https://user@example.org/v1'), isNull);
  });
  test('sends chosen model and question without following redirects', () async {
    final settings = AiSettings(
      endpoint: 'https://example.org/v1',
      model: 'test-model',
      key: 'local-test-key',
    );
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/chat/completions');
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer local-test-key');
      expect(jsonDecode(request.body)['model'], 'test-model');
      expect(jsonDecode(request.body)['messages'][0]['content'], '问题');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '回答'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    expect(await settings.ask('问题', client: client), '回答');
    client.close();
  });
}
