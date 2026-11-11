import 'package:sqflite/sqflite.dart';

import 'ai_exam.dart';

/// A paper built from user-authored questions, with immutable snapshots.
class LocalExam {
  LocalExam(this.db, this.courseId);
  final Database db;
  final int courseId;

  Future<int> create(String title, List<int> questionIds) => db.transaction((
    tx,
  ) async {
    final name = title.trim();
    if (name.isEmpty ||
        name.length > 120 ||
        questionIds.isEmpty ||
        questionIds.length > 50 ||
        questionIds.toSet().length != questionIds.length)
      throw ArgumentError('试卷名称或题目无效');
    final placeholders = List.filled(questionIds.length, '?').join(',');
    final questions = await tx.query(
      'local_questions',
      where: 'course_id = ? AND id IN ($placeholders)',
      whereArgs: [courseId, ...questionIds],
    );
    if (questions.length != questionIds.length) throw StateError('部分题目不属于当前课程');
    final byId = {for (final q in questions) q['id'] as int: q};
    final id = await tx.insert('local_exams', {
      'course_id': courseId,
      'title': name,
      'status': 'draft',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    for (var i = 0; i < questionIds.length; i++) {
      final q = byId[questionIds[i]]!;
      await tx.insert('local_exam_items', {
        'exam_id': id,
        'question_id': questionIds[i],
        'position': i,
        'prompt': q['prompt'],
        'answer': q['answer'],
        'explanation': q['explanation'],
        'response': '',
      });
    }
    return id;
  });

  Future<int> createFromAi(
    String title,
    int noteId,
    String model,
    List<AiExamQuestion> questions,
  ) => db.transaction((tx) async {
    final name = title.trim();
    if (name.isEmpty ||
        name.length > 120 ||
        questions.isEmpty ||
        questions.length > 10 ||
        model.trim().isEmpty)
      throw ArgumentError('试卷信息无效');
    final notes = await tx.query(
      'notes',
      where: 'id = ? AND course_id = ?',
      whereArgs: [noteId, courseId],
    );
    if (notes.isEmpty) throw StateError('资料不存在');
    final note = notes.first;
    final excerpt = aiSourceExcerpt(note['body'] as String);
    for (final q in questions) {
      if (q.prompt.trim().isEmpty ||
          q.prompt.length > 5000 ||
          q.answer.trim().isEmpty ||
          q.answer.length > 1000 ||
          q.explanation.length > 5000 ||
          q.quote.isEmpty ||
          q.quote.length > 400 ||
          !excerpt.contains(q.quote))
        throw ArgumentError('题目或引用无效');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final examId = await tx.insert('local_exams', {
      'course_id': courseId,
      'title': name,
      'status': 'draft',
      'created_at': now,
    });
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final qid = await tx.insert('local_questions', {
        'course_id': courseId,
        'prompt': q.prompt.trim(),
        'answer': q.answer.trim(),
        'explanation': q.explanation.trim(),
        'created_at': now,
      });
      await tx.insert('local_question_sources', {
        'question_id': qid,
        'note_id': noteId,
        'source_title': note['title'],
        'quote': q.quote,
        'model': model,
      });
      await tx.insert('local_exam_items', {
        'exam_id': examId,
        'question_id': qid,
        'position': i,
        'prompt': q.prompt.trim(),
        'answer': q.answer.trim(),
        'explanation': q.explanation.trim(),
        'response': '',
      });
    }
    return examId;
  });

  Future<List<Map<String, Object?>>> list() => db.query(
    'local_exams',
    where: 'course_id = ?',
    whereArgs: [courseId],
    orderBy: 'id DESC',
  );

  Future<Map<String, Object?>> load(int examId) => db.transaction((tx) async {
    final exams = await tx.query(
      'local_exams',
      where: 'id = ? AND course_id = ?',
      whereArgs: [examId, courseId],
    );
    if (exams.isEmpty) throw StateError('试卷不存在');
    final items = await tx.rawQuery(
      'SELECT i.*, s.source_title, s.quote FROM local_exam_items i LEFT JOIN local_question_sources s ON i.question_id = s.question_id WHERE i.exam_id = ? ORDER BY i.position',
      [examId],
    );
    return {...exams.first, 'items': items};
  });

  Future<void> saveAnswer(int examId, int questionId, String response) =>
      db.transaction((tx) async {
        if (response.length > 1000) throw ArgumentError('答案过长');
        final papers = await tx.query(
          'local_exams',
          columns: ['status'],
          where: 'id = ? AND course_id = ?',
          whereArgs: [examId, courseId],
        );
        if (papers.isEmpty || papers.first['status'] != 'draft')
          throw StateError('试卷不存在或已经提交');
        final count = await tx.update(
          'local_exam_items',
          {'response': response},
          where: 'exam_id = ? AND question_id = ?',
          whereArgs: [examId, questionId],
        );
        if (count != 1) throw StateError('题目不属于该试卷');
      });

  Future<void> submit(int examId) => db.transaction((tx) async {
    final papers = await tx.query(
      'local_exams',
      where: 'id = ? AND course_id = ?',
      whereArgs: [examId, courseId],
    );
    if (papers.isEmpty) throw StateError('试卷不存在');
    if (papers.first['status'] == 'submitted') return;
    final items = await tx.query(
      'local_exam_items',
      where: 'exam_id = ?',
      whereArgs: [examId],
      orderBy: 'position',
    );
    if (items.isEmpty) throw StateError('空试卷不能提交');
    final now = DateTime.now().toUtc().toIso8601String();
    var correctCount = 0;
    for (final item in items) {
      final response = (item['response'] as String).trim();
      final correct =
          response.isNotEmpty &&
          response.toLowerCase() ==
              (item['answer'] as String).trim().toLowerCase();
      if (correct) correctCount++;
      await tx.update(
        'local_exam_items',
        {'correct': correct ? 1 : 0},
        where: 'exam_id = ? AND question_id = ?',
        whereArgs: [examId, item['question_id']],
      );
      await tx.insert('local_attempts', {
        'question_id': item['question_id'],
        'response': response,
        'correct': correct ? 1 : 0,
        'created_at': now,
      });
    }
    await tx.update(
      'local_exams',
      {
        'status': 'submitted',
        'submitted_at': now,
        'correct_count': correctCount,
      },
      where: 'id = ? AND course_id = ?',
      whereArgs: [examId, courseId],
    );
  });
}
