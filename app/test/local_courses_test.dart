import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhi_ai/local_courses.dart';

void main() {
  sqfliteFfiInit();
  test('local courses are stored and reject empty titles', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE courses (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, is_markdown INTEGER NOT NULL, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE note_files (note_id INTEGER PRIMARY KEY, local_path TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_questions (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_attempts (id INTEGER PRIMARY KEY AUTOINCREMENT, question_id INTEGER NOT NULL, response TEXT NOT NULL, correct INTEGER NOT NULL, created_at TEXT NOT NULL)',
    );
    final courses = LocalCourses(db);
    await courses.add(' 数学 ');
    expect((await courses.list()).single['title'], '数学');
    final courseId = (await courses.list()).single['id'] as int;
    await courses.addNote(courseId, '笔记.md', r'$x^2$', markdown: true);
    expect((await courses.notes(courseId)).single['body'], r'$x^2$');
    await expectLater(courses.addNote(999, '缺失课程', '内容'), throwsStateError);
    await courses.addQuestion(courseId, '2 + 2 = ?', '4', '加法');
    final id = (await courses.questions(courseId)).single['id'] as int;
    expect(await courses.attempt(courseId, id, ' 4 '), isTrue);
    expect(await courses.attempt(courseId, id, '5'), isFalse);
    expect(await courses.incorrectQuestions(courseId), hasLength(1));
    await expectLater(courses.attempt(999, id, '4'), throwsStateError);
    expect(await db.query('local_attempts'), hasLength(2));
    expect(await courses.attempt(courseId, id, '4'), isTrue);
    expect(await courses.incorrectQuestions(courseId), isEmpty);
    await expectLater(courses.add('  '), throwsArgumentError);
    await db.close();
  });
}
