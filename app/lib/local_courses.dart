import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

class LocalCourses {
  LocalCourses(this.db) : _sharedHandle = false;
  LocalCourses._shared(this.db) : _sharedHandle = true;
  final Database db;
  final bool _sharedHandle;
  bool _closed = false;
  static final _lock = Lock();
  static Database? _database;
  static int _references = 0;

  static Future<LocalCourses> open() => _lock.synchronized(() async {
    _database ??= await openDatabase(
      path.join(await getDatabasesPath(), 'local_courses.db'),
      version: 8,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE courses (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, created_at TEXT NOT NULL)',
        );
        await _createNotes(db);
        await _createAttachments(db);
        await _createPractice(db);
        await _createKnowledge(db);
        await _createReview(db);
        await _createExam(db);
        await _createAiSources(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createNotes(db);
        if (oldVersion < 3) await _createAttachments(db);
        if (oldVersion < 4) await _createPractice(db);
        if (oldVersion < 5) await _createKnowledge(db);
        if (oldVersion < 6) await _createReview(db);
        if (oldVersion < 7) await _createExam(db);
        if (oldVersion < 8) await _createAiSources(db);
      },
    );
    _references++;
    return LocalCourses._shared(_database!);
  });

  Future<void> close() => _lock.synchronized(() async {
    if (_closed) return;
    _closed = true;
    if (!_sharedHandle) {
      await db.close();
      return;
    }
    _references--;
    if (_references == 0) {
      final previous = _database;
      _database = null;
      await previous?.close();
    }
  });

  static Future<void> _createNotes(DatabaseExecutor db) => db.execute(
    'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL REFERENCES courses(id), title TEXT NOT NULL, body TEXT NOT NULL, is_markdown INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)',
  );

  static Future<void> _createAttachments(DatabaseExecutor db) => db.execute(
    'CREATE TABLE note_files (note_id INTEGER PRIMARY KEY REFERENCES notes(id), local_path TEXT NOT NULL)',
  );

  static Future<void> _createPractice(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE local_questions (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL REFERENCES courses(id), prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_attempts (id INTEGER PRIMARY KEY AUTOINCREMENT, question_id INTEGER NOT NULL REFERENCES local_questions(id), response TEXT NOT NULL, correct INTEGER NOT NULL, created_at TEXT NOT NULL)',
    );
  }

  static Future<void> _createKnowledge(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE local_concepts (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL REFERENCES courses(id), title TEXT NOT NULL COLLATE NOCASE, note_id INTEGER REFERENCES notes(id), created_at TEXT NOT NULL, UNIQUE(course_id,title))',
    );
    await db.execute(
      "CREATE TABLE local_edges (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL REFERENCES courses(id), source_id INTEGER NOT NULL REFERENCES local_concepts(id), target_id INTEGER NOT NULL REFERENCES local_concepts(id), kind TEXT NOT NULL CHECK(kind IN ('prerequisite','related')), UNIQUE(course_id,source_id,target_id,kind))",
    );
  }

  static Future<void> _createReview(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE local_reviews (question_id INTEGER PRIMARY KEY REFERENCES local_questions(id), course_id INTEGER NOT NULL REFERENCES courses(id), repetitions INTEGER NOT NULL, interval_days INTEGER NOT NULL, ease REAL NOT NULL, due_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_review_history (id INTEGER PRIMARY KEY AUTOINCREMENT, question_id INTEGER NOT NULL REFERENCES local_questions(id), course_id INTEGER NOT NULL REFERENCES courses(id), quality INTEGER NOT NULL, reviewed_at TEXT NOT NULL, next_due_at TEXT NOT NULL)',
    );
  }

  static Future<void> _createAiSources(DatabaseExecutor db) => db.execute(
    'CREATE TABLE local_question_sources (question_id INTEGER PRIMARY KEY REFERENCES local_questions(id), note_id INTEGER NOT NULL REFERENCES notes(id), source_title TEXT NOT NULL, quote TEXT NOT NULL, model TEXT NOT NULL)',
  );

  static Future<void> _createExam(DatabaseExecutor db) async {
    await db.execute(
      "CREATE TABLE local_exams (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL REFERENCES courses(id), title TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('draft','submitted')), created_at TEXT NOT NULL, submitted_at TEXT, correct_count INTEGER)",
    );
    await db.execute(
      'CREATE TABLE local_exam_items (exam_id INTEGER NOT NULL REFERENCES local_exams(id), question_id INTEGER NOT NULL REFERENCES local_questions(id), position INTEGER NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, explanation TEXT NOT NULL, response TEXT NOT NULL, correct INTEGER, PRIMARY KEY(exam_id,question_id))',
    );
  }

  Future<List<Map<String, Object?>>> questions(int courseId) => db.query(
    'local_questions',
    where: 'course_id = ?',
    whereArgs: [courseId],
    orderBy: 'id DESC',
  );

  /// Only the latest attempt decides whether a question appears here; no
  /// assumption is made about mastery or semantic equivalence.
  Future<List<Map<String, Object?>>> incorrectQuestions(int courseId) =>
      db.rawQuery(
        '''
    SELECT q.*, a.response AS last_response, a.created_at AS last_attempt_at
    FROM local_questions q JOIN local_attempts a ON a.question_id = q.id
    WHERE q.course_id = ? AND a.correct = 0
      AND a.id = (SELECT MAX(a2.id) FROM local_attempts a2 WHERE a2.question_id = q.id)
    ORDER BY a.id DESC
  ''',
        [courseId],
      );

  Future<void> addQuestion(
    int courseId,
    String prompt,
    String answer,
    String explanation,
  ) async {
    if (prompt.trim().isEmpty ||
        answer.trim().isEmpty ||
        prompt.length > 5000 ||
        answer.length > 1000 ||
        explanation.length > 5000)
      throw ArgumentError('请填写题目与参考答案');
    await db.transaction((tx) async {
      if ((await tx.query(
        'courses',
        where: 'id = ?',
        whereArgs: [courseId],
      )).isEmpty)
        throw StateError('课程不存在');
      await tx.insert('local_questions', {
        'course_id': courseId,
        'prompt': prompt.trim(),
        'answer': answer.trim(),
        'explanation': explanation.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<bool> attempt(int courseId, int questionId, String response) async =>
      db.transaction((tx) async {
        final rows = await tx.query(
          'local_questions',
          where: 'id = ? AND course_id = ?',
          whereArgs: [questionId, courseId],
        );
        if (rows.isEmpty) throw StateError('题目不存在');
        if (response.trim().isEmpty || response.length > 1000)
          throw ArgumentError('请输入答案');
        final correct =
            response.trim().toLowerCase() ==
            (rows.first['answer'] as String).trim().toLowerCase();
        await tx.insert('local_attempts', {
          'question_id': questionId,
          'response': response.trim(),
          'correct': correct ? 1 : 0,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        return correct;
      });

  Future<List<Map<String, Object?>>> notes(int courseId) => db.rawQuery(
    'SELECT notes.*, note_files.local_path FROM notes LEFT JOIN note_files ON notes.id = note_files.note_id WHERE notes.course_id = ? ORDER BY notes.id DESC',
    [courseId],
  );

  Future<void> addNote(
    int courseId,
    String title,
    String body, {
    bool markdown = false,
    String? localFile,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty ||
        cleanTitle.length > 120 ||
        body.trim().isEmpty ||
        body.length > 500000) {
      throw ArgumentError('资料标题或内容无效');
    }
    await db.transaction((tx) async {
      final course = await tx.query(
        'courses',
        where: 'id = ?',
        whereArgs: [courseId],
      );
      if (course.isEmpty) throw StateError('课程不存在');
      final id = await tx.insert('notes', {
        'course_id': courseId,
        'title': cleanTitle,
        'body': body,
        'is_markdown': markdown ? 1 : 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (localFile != null)
        await tx.insert('note_files', {'note_id': id, 'local_path': localFile});
    });
  }

  Future<void> add(String title) async {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 80)
      throw ArgumentError('课程名称应为 1 到 80 字');
    await db.insert('courses', {
      'title': clean,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> list() =>
      db.query('courses', orderBy: 'id DESC');
}
