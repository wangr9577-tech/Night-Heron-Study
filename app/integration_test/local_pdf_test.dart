import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_pdf_import.dart';
import 'package:zhi_ai/local_pdf_view.dart';
import 'package:path_provider/path_provider.dart';

import 'synthetic_pdf_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('imports a synthetic PDF locally and keeps the original', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use an isolated emulator');
    final savedPath = await tester.runAsync(() async {
      final fixture = File(
        path.join((await getTemporaryDirectory()).path, 'synthetic.pdf'),
      );
      await fixture.writeAsBytes(base64Decode(syntheticPdfBase64));
      await deleteDatabase(
        path.join(await getDatabasesPath(), 'local_courses.db'),
      );
      final store = await LocalCourses.open();
      try {
        await store.add('KNN');
        final id = (await store.list()).single['id'] as int;
        await importLocalPdf(store, id, 'KNN.pdf', fixture);
        final note = (await store.notes(id)).single;
        expect((note['body'] as String).toLowerCase(), contains('accuracy'));
        final attachments = await store.db.query('note_files');
        expect(attachments, hasLength(1));
        final saved = File(attachments.single['local_path'] as String);
        expect(await saved.exists(), isTrue);
        expect(await saved.length(), await fixture.length());
        return saved.path;
      } finally {
        await store.close();
      }
    });
    expect(savedPath, isNotNull);
    await expectLater(
      const MethodChannel('zhi/local_pdf').invokeMethod<int>('pageCount', {
        'path': '/sdcard/Download/knn-reference.pdf',
      }),
      throwsA(isA<PlatformException>()),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LocalPdfView(filePath: savedPath!, title: '原 PDF', courseId: 1),
      ),
    );
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('识别本页'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('开始识别'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
