import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/main.dart';

void main() {
  testWidgets('long course names fit a narrow phone with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    api.token = 'test';
    api.selectedCourse = null;
    api.client = MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.path.endsWith('/courses')
              ? {
                  'items': [
                    {'course_id': 'long', 'title': '数据科学与机器学习特别长的课程名称'},
                  ],
                }
              : {'items': []},
        ),
        200,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const HomePage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('本地体验'), findsOneWidget);
    expect(tester.takeException(), isNull);
    api.token = null;
    api.selectedCourse = null;
    api.client.close();
    api.client = http.Client();
  });
  testWidgets('automatic course selection is persisted for other pages', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    api.token = 'test';
    api.selectedCourse = null;
    api.client = MockClient((request) async {
      final data = request.url.path.endsWith('/courses')
          ? {
              'items': [
                {'course_id': 'course-1', 'title': 'Course One'},
              ],
            }
          : {'items': []};
      return http.Response(jsonEncode(data), 200);
    });
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();
    expect(api.selectedCourse, 'course-1');
    expect(
      (await SharedPreferences.getInstance()).getString('course'),
      'course-1',
    );
    api.token = null;
    api.selectedCourse = null;
    api.client.close();
    api.client = http.Client();
  });
}
