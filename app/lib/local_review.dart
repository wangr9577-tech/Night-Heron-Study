import 'package:sqflite/sqflite.dart';

import 'local_sm2.dart';

/// User-rated personal study reminders; these are not mastery evidence.
class LocalReview {
  LocalReview(this.db, this.courseId);
  final Database db;
  final int courseId;

  Future<void> schedule(int questionId, {DateTime? at}) =>
      db.transaction((tx) async {
        final q = await tx.query(
          'local_questions',
          columns: ['id'],
          where: 'id = ? AND course_id = ?',
          whereArgs: [questionId, courseId],
        );
        if (q.isEmpty) throw StateError('题目不属于该课程');
        await tx.insert('local_reviews', {
          'question_id': questionId,
          'course_id': courseId,
          'repetitions': 0,
          'interval_days': 0,
          'ease': 2.5,
          'due_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });

  Future<List<Map<String, Object?>>> all() => db.rawQuery(
    '''SELECT r.*, q.prompt, q.answer, q.explanation
      FROM local_reviews r JOIN local_questions q ON q.id = r.question_id AND q.course_id = r.course_id
      WHERE r.course_id = ? ORDER BY r.due_at''',
    [courseId],
  );

  Future<List<Map<String, Object?>>> due({DateTime? at}) async {
    final now = (at ?? DateTime.now()).toUtc();
    final rows = await all();
    return rows
        .where(
          (r) => !DateTime.parse(r['due_at'] as String).toUtc().isAfter(now),
        )
        .toList();
  }

  Future<ReviewSchedule> rate(int questionId, int quality, {DateTime? at}) =>
      db.transaction((tx) async {
        final now = (at ?? DateTime.now()).toUtc();
        final rows = await tx.query(
          'local_reviews',
          where: 'question_id = ? AND course_id = ?',
          whereArgs: [questionId, courseId],
        );
        if (rows.isEmpty) throw StateError('未找到复习项目');
        final item = rows.first;
        if (DateTime.parse(item['due_at'] as String).toUtc().isAfter(now))
          throw StateError('尚未到复习时间');
        final result = nextReview(
          repetitions: item['repetitions'] as int,
          intervalDays: item['interval_days'] as int,
          ease: (item['ease'] as num).toDouble(),
          quality: quality,
        );
        final nextDue = now.add(Duration(days: result.intervalDays));
        await tx.update(
          'local_reviews',
          {
            'repetitions': result.repetitions,
            'interval_days': result.intervalDays,
            'ease': result.ease,
            'due_at': nextDue.toIso8601String(),
          },
          where: 'question_id = ? AND course_id = ?',
          whereArgs: [questionId, courseId],
        );
        await tx.insert('local_review_history', {
          'question_id': questionId,
          'course_id': courseId,
          'quality': quality,
          'reviewed_at': now.toIso8601String(),
          'next_due_at': nextDue.toIso8601String(),
        });
        return result;
      });
}
