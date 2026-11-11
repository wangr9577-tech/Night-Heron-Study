import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/focus_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'overlapping local screens share connections without closing one another',
    (tester) async {
      if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
        throw TestFailure('Use isolated emulator');
      final root = await getDatabasesPath();
      await deleteDatabase(path.join(root, 'local_courses.db'));
      await deleteDatabase(path.join(root, 'focus_local.db'));
      final courses = await Future.wait([
        LocalCourses.open(),
        LocalCourses.open(),
      ]);
      expect(identical(courses[0].db, courses[1].db), isTrue);
      await courses[0].add('课程');
      await courses[0].close();
      await courses[0].close();
      expect((await courses[1].list()).single['title'], '课程');
      await courses[1].close();
      final focus = await Future.wait([FocusStore.open(), FocusStore.open()]);
      expect(identical(focus[0].db, focus[1].db), isTrue);
      await focus[0].start('学习', 15);
      await focus[0].close();
      expect(await focus[1].active(), isNotNull);
      await focus[1].close();
    },
  );
}
