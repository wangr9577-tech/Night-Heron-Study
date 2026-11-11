import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/local_course_page.dart';

void main() {
  testWidgets('PDF reading controls fit a narrow phone at larger text size', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final note = <String, Object?>{
      'id': 10,
      'course_id': 1,
      'title': '很长的课程资料名称和数学公式.pdf',
      'body': '公式和说明。',
      'is_markdown': 0,
      'local_path': '/private/file.pdf',
    };
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LocalNotePage(note: note),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看原 PDF'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'reading position persists and restores for the same local note',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final note = <String, Object?>{
        'id': 73,
        'title': '长资料',
        'body': List.generate(120, (i) => '这是第 $i 行的测试内容。').join('\n'),
        'is_markdown': 0,
      };
      Widget page() => MaterialApp(home: LocalNotePage(note: note));
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('local-note-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final saved = (await SharedPreferences.getInstance()).getDouble(
        'local_note_position_73',
      );
      expect(saved, isNotNull);
      expect(saved!, greaterThan(100));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final view = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('local-note-scroll')),
      );
      expect(view.controller!.offset, closeTo(saved, 2));
      expect(tester.takeException(), isNull);
    },
  );
}
