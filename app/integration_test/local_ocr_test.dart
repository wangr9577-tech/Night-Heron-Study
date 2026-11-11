import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_ocr_page.dart';

import 'synthetic_ocr_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline OCR recognizes and saves a synthetic page', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use an isolated emulator');
    await deleteDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
    );
    final store = await LocalCourses.open();
    await store.add('OCR');
    final courseId = (await store.list()).single['id'] as int;
    await store.close();
    await tester.pumpWidget(
      MaterialApp(
        home: LocalOcrPage(
          image: base64Decode(syntheticOcrBase64),
          courseId: courseId,
          title: '识别结果',
        ),
      ),
    );
    await tester.tap(find.text('开始识别'));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final field = tester.widget<TextField>(find.byType(TextField));
      if ((field.controller?.text ?? '').contains('数据科学')) break;
    }
    final result = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    expect(result.toUpperCase(), contains('ACCURACY'));
    expect(result, contains('数据科学'));
    await tester.tap(find.text('保存为课程资料'));
    await tester.pump(const Duration(seconds: 2));
    final reopened = await LocalCourses.open();
    expect(
      (await reopened.notes(courseId)).single['body'].toString().toUpperCase(),
      contains('ACCURACY'),
    );
    await reopened.close();
    expect(tester.takeException(), isNull);
  });
}
