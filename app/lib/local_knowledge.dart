import 'package:sqflite/sqflite.dart';

class LocalKnowledge {
  LocalKnowledge(this.db, this.courseId);
  final Database db;
  final int courseId;

  Future<List<Map<String, Object?>>> concepts() => db.rawQuery(
    '''SELECT local_concepts.*, notes.title AS source_title FROM local_concepts
    LEFT JOIN notes ON notes.id = local_concepts.note_id
    WHERE local_concepts.course_id = ? ORDER BY local_concepts.id DESC''',
    [courseId],
  );

  Future<List<Map<String, Object?>>> edges() => db.rawQuery(
    '''SELECT e.*, s.title AS source_title, t.title AS target_title FROM local_edges e
    JOIN local_concepts s ON s.id = e.source_id JOIN local_concepts t ON t.id = e.target_id
    WHERE e.course_id = ? ORDER BY e.id DESC''',
    [courseId],
  );

  Future<void> addConcept(String input, {int? noteId}) async {
    final title = input.trim();
    if (title.isEmpty || title.length > 100)
      throw ArgumentError('知识点名称应为 1 到 100 字');
    await db.transaction((tx) async {
      if ((await tx.query(
        'courses',
        where: 'id = ?',
        whereArgs: [courseId],
      )).isEmpty)
        throw StateError('课程不存在');
      if (noteId != null &&
          (await tx.query(
            'notes',
            where: 'id = ? AND course_id = ?',
            whereArgs: [noteId, courseId],
          )).isEmpty)
        throw StateError('来源不属于该课程');
      await tx.insert('local_concepts', {
        'course_id': courseId,
        'title': title,
        'note_id': noteId,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> addEdge(int source, int target, String kind) async {
    if (source == target || !const {'related', 'prerequisite'}.contains(kind))
      throw ArgumentError('关系无效');
    await db.transaction((tx) async {
      final endpoints = await tx.query(
        'local_concepts',
        columns: ['id'],
        where: 'course_id = ? AND id IN (?, ?)',
        whereArgs: [courseId, source, target],
      );
      if (endpoints.length != 2) throw StateError('知识点不属于该课程');
      if (kind == 'prerequisite') {
        final rows = await tx.query(
          'local_edges',
          columns: ['source_id', 'target_id'],
          where: 'course_id = ? AND kind = ?',
          whereArgs: [courseId, 'prerequisite'],
        );
        final adjacency = <int, List<int>>{};
        for (final row in rows) {
          adjacency
              .putIfAbsent(row['source_id'] as int, () => [])
              .add(row['target_id'] as int);
        }
        final pending = <int>[target];
        final seen = <int>{};
        while (pending.isNotEmpty) {
          final node = pending.removeLast();
          if (node == source) throw StateError('前置关系会形成循环');
          if (seen.add(node)) pending.addAll(adjacency[node] ?? const []);
        }
      }
      await tx.insert('local_edges', {
        'course_id': courseId,
        'source_id': source,
        'target_id': target,
        'kind': kind,
      });
    });
  }
}
