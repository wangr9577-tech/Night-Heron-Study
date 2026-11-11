import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhi_ai/local_course_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reading position persists across opening and text can request speech',
    (tester) async {
      if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
        throw TestFailure('Use isolated emulator');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('local_note_position_987');
      final note = <String, Object?>{
        'id': 987,
        'title': '阅读示例',
        'body': List.generate(
          120,
          (i) => 'This is reading line $i.',
        ).join('\n'),
        'is_markdown': 0,
      };
      Widget screen() => MaterialApp(home: LocalNotePage(note: note));
      await tester.pumpWidget(screen());
      await tester.pump(const Duration(seconds: 2));
      await tester.drag(
        find.byKey(const Key('local-note-scroll')),
        const Offset(0, -600),
      );
      await tester.pump(const Duration(seconds: 2));
      final saved = prefs.getDouble('local_note_position_987');
      expect(saved, isNotNull);
      expect(saved!, greaterThan(100));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(screen());
      await tester.pump(const Duration(seconds: 2));
      final scroll = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('local-note-scroll')),
      );
      expect(scroll.controller!.offset, closeTo(saved, 3));
      await tester.tap(find.text('朗读文字'));
      await tester.pump(const Duration(milliseconds: 300));
      if (find.text('停止朗读').evaluate().isNotEmpty) {
        await tester.tap(find.text('停止朗读'));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.takeException(), isNull);
      await prefs.remove('local_note_position_987');
    },
  );
}
