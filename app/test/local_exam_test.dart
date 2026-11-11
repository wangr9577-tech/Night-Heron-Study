import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhi_ai/local_exam.dart';

void main() {
  sqfliteFfiInit();
  test(
    'exam snapshots, course boundaries, drafts and repeated submit',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'CREATE TABLE local_questions (id INTEGER PRIMARY KEY, course_id INTEGER NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE local_question_sources (question_id INTEGER PRIMARY KEY, note_id INTEGER, source_title TEXT, quote TEXT, model TEXT)',
      );
      await db.execute(
        'CREATE TABLE local_attempts (id INTEGER PRIMARY KEY AUTOINCREMENT, question_id INTEGER NOT NULL, response TEXT NOT NULL, correct INTEGER NOT NULL, created_at TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE local_exams (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, submitted_at TEXT, correct_count INTEGER)',
      );
      await db.execute(
        "CREATE TABLE local_exam_items (exam_id INTEGER NOT NULL, question_id INTEGER NOT NULL, position INTEGER NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL, response TEXT NOT NULL, correct INTEGER, PRIMARY KEY(exam_id, question_id))",
      );
      await db.execute(
        "INSERT INTO local_questions VALUES (1,1,'一加一','2','解析'),(2,1,'二加二','4',''),(3,2,'其他','X','')",
      );
      final exams = LocalExam(db, 1);
      await expectLater(exams.create('跨课程', [1, 3]), throwsStateError);
      final id = await exams.create('测试卷', [1, 2]);
      await exams.saveAnswer(id, 1, ' 2 ');
      await db.update('local_questions', {
        'answer': 'changed',
      }, where: 'id = 1');
      final draft = await exams.load(id);
      expect((draft['items'] as List).first['answer'], '2');
      await Future.wait([exams.submit(id), exams.submit(id)]);
      final saved = await exams.load(id);
      expect(saved['status'], 'submitted');
      expect(saved['correct_count'], 1);
      expect(await db.query('local_attempts'), hasLength(2));
      await expectLater(exams.saveAnswer(id, 1, 'new'), throwsStateError);
      await expectLater(LocalExam(db, 2).load(id), throwsStateError);
      await db.close();
    },
  );
}
