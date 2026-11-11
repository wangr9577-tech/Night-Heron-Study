import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zhi_ai/ai_exam.dart';
import 'package:zhi_ai/ai_settings.dart';
import 'package:zhi_ai/desktop_shell.dart';
import 'package:zhi_ai/desktop_pdf.dart';
import 'package:zhi_ai/local_platform.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_exam.dart';
import 'package:zhi_ai/local_pdf_import.dart';
import 'package:zhi_ai/focus_store.dart';

import 'synthetic_ocr_fixture.dart';
import 'synthetic_pdf_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows SQLite, PDF, OCR, AI service and desktop navigation', (
    tester,
  ) async {
    if (!Platform.isWindows ||
        !const bool.fromEnvironment('DESKTOP_TEST_ISOLATED'))
      throw TestFailure('Use isolated Windows test data');
    final root = await Directory.systemTemp.createTemp(
      'zhi_windows_acceptance_',
    );
    await initializeLocalPlatform(databaseDirectory: '${root.path}/databases');
    late int course;
    await tester.runAsync(() async {
      final store = await LocalCourses.open();
      await store.add('桌面验收课程');
      course = (await store.list()).single['id'] as int;
      await store.addNote(course, '桌面资料', '分类准确率 Accuracy 是预测正确的样本比例。');
      final note = (await store.notes(course)).single;
      final pdf = File('${root.path}/fixture.pdf');
      await pdf.writeAsBytes(base64Decode(syntheticPdfBase64));
      expect(
        (await desktopPdfText(pdf.path)).join().toLowerCase(),
        contains('accuracy'),
      );
      expect(await desktopPdfCount(pdf.path), 1);
      final png = await desktopPdfPage(pdf.path, 0);
      expect(png, isNotNull);
      expect(png!.take(4), [137, 80, 78, 71]);
      await importLocalPdf(store, course, 'fixture.pdf', pdf);
      final imported = (await store.notes(course)).first;
      expect(
        await File(imported['local_path'] as String).readAsBytes(),
        base64Decode(syntheticPdfBase64),
      );
      final image = File('${root.path}/ocr.png');
      await image.writeAsBytes(base64Decode(syntheticOcrBase64));
      final recognized = await const MethodChannel('zhi/local_ocr')
          .invokeMethod<String>('recognize', {
            'path': image.path,
            'language': 'en-US',
          });
      expect(recognized!.toUpperCase(), contains('ACCURACY'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final previous = await AiSettings.load();
      try {
        final requestDone = server.first.then((request) async {
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          if (body['model'] != 'desktop-test' ||
              !body['messages'].last['content'].toString().contains('分类准确率'))
            throw StateError('Unexpected AI context');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'questions': [
                        {
                          'prompt': 'Accuracy 表示什么？',
                          'answer': '预测正确的样本比例',
                          'explanation': '见原文',
                          'source_quote': '预测正确的样本比例',
                        },
                      ],
                    }),
                  },
                },
              ],
            }),
          );
          await request.response.close();
        });
        final settings = AiSettings(
          endpoint: 'http://127.0.0.1:${server.port}/v1',
          model: 'desktop-test',
          key: 'test-only',
        );
        await settings.save();
        expect((await AiSettings.load())!.model, 'desktop-test');
        final questions = await generateAiExam(
          settings,
          note['body'] as String,
          1,
          '',
        );
        await requestDone;
        final exam = LocalExam(store.db, course);
        final id = await exam.createFromAi(
          '桌面 AI 试卷',
          note['id'] as int,
          settings.model,
          questions,
        );
        expect((await exam.load(id))['status'], 'draft');
      } finally {
        await server.close(force: true);
        if (previous == null) {
          await AiSettings.clear();
        } else {
          await previous.save();
        }
      }
      await store.close();
      final reopened = await LocalCourses.open();
      expect((await reopened.list()).single['title'], '桌面验收课程');
      expect(await LocalExam(reopened.db, course).list(), hasLength(1));
      await reopened.close();
      final focus = await FocusStore.open();
      final start = DateTime.now().subtract(const Duration(minutes: 16));
      final sid = await focus.start('阅读', 15, at: start);
      expect(await focus.complete(sid), isTrue);
      expect((await focus.growth())['balance'], 15);
      await focus.skipRest();
      await focus.close();
    });
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff557b60),
            ),
          ),
          home: const DesktopShell(),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('桌面验收课程').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('本机课程'), findsOneWidget);
    expect(find.text('桌面验收课程'), findsOneWidget);
    await tester.tap(find.text('专注与统计').first);
    for (var i = 0; i < 100 && find.text('开始专注').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('开始专注'), findsOneWidget);
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = Directory(
        const String.fromEnvironment(
          'DESKTOP_TEST_OUTPUT',
          defaultValue: 'D:/nh-app/output/windows-test',
        ),
      );
      await out.create(recursive: true);
      await File('${out.path}/desktop-focus.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
