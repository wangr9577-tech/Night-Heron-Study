import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:zhi_ai/local_courses.dart';
import 'package:zhi_ai/local_knowledge.dart';
import 'package:zhi_ai/local_review.dart';
import 'package:zhi_ai/local_exam.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('course migration preserves existing records', (tester) async {
    if (!const bool.fromEnvironment('INTEGRATION_TEST_ISOLATED'))
      throw TestFailure('Use isolated emulator');
    final file = path.join(await getDatabasesPath(), 'local_courses.db');
    await deleteDatabase(file);
    final old = await openDatabase(
      file,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE courses (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, created_at TEXT NOT NULL)',
        );
        await db.insert('courses', {
          'title': '保留课程',
          'created_at': '2026-01-01',
        });
      },
    );
    await old.close();
    final migrated = await LocalCourses.open();
    final course = (await migrated.list()).single;
    expect(course['title'], '保留课程');
    await migrated.addNote(course['id'] as int, '笔记', '保留资料');
    await migrated.addQuestion(course['id'] as int, '测试？', '答案', '');
    final graph = LocalKnowledge(migrated.db, course['id'] as int);
    await graph.addConcept('基础知识');
    expect(await graph.concepts(), hasLength(1));
    expect(await migrated.notes(course['id'] as int), hasLength(1));
    expect(await migrated.questions(course['id'] as int), hasLength(1));
    final question = (await migrated.questions(course['id'] as int)).single;
    final review = LocalReview(migrated.db, course['id'] as int);
    await review.schedule(question['id'] as int);
    expect(await review.due(), hasLength(1));
    final exam = LocalExam(migrated.db, course['id'] as int);
    final examId = await exam.create('旧课程试卷', [question['id'] as int]);
    expect((await exam.load(examId))['status'], 'draft');
    await migrated.close();
  });
}
