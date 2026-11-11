import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhi_ai/local_review.dart';

void main() {
  sqfliteFfiInit();
  test('review respects due time, isolation and duplicate ratings', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE local_questions (id INTEGER PRIMARY KEY, course_id INTEGER NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_reviews (question_id INTEGER PRIMARY KEY, course_id INTEGER NOT NULL, repetitions INTEGER NOT NULL, interval_days INTEGER NOT NULL, ease REAL NOT NULL, due_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_review_history (id INTEGER PRIMARY KEY AUTOINCREMENT, question_id INTEGER NOT NULL, course_id INTEGER NOT NULL, quality INTEGER NOT NULL, reviewed_at TEXT NOT NULL, next_due_at TEXT NOT NULL)',
    );
    await db.execute(
      "INSERT INTO local_questions VALUES (1, 1, '题目', '答案', ''), (2, 2, '其他', '答案', '')",
    );
    final review = LocalReview(db, 1);
    final start = DateTime.utc(2026, 1, 1);
    await review.schedule(1, at: start);
    await review.schedule(1, at: start.add(const Duration(hours: 2)));
    await expectLater(review.schedule(2, at: start), throwsStateError);
    expect(await review.due(at: start), hasLength(1));
    final results = await Future.wait([
      review.rate(1, 4, at: start).then((_) => true, onError: (_) => false),
      review.rate(1, 4, at: start).then((_) => true, onError: (_) => false),
    ]);
    expect(results.where((x) => x), hasLength(1));
    expect(await review.due(at: start), isEmpty);
    expect(
      await review.due(at: start.add(const Duration(days: 1))),
      hasLength(1),
    );
    expect(await db.query('local_review_history'), hasLength(1));
    await db.close();
  });
}
