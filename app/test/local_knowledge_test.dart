import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhi_ai/local_knowledge.dart';

void main() {
  sqfliteFfiInit();
  test(
    'prerequisites reject cycles and sources remain within course',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('CREATE TABLE courses (id INTEGER PRIMARY KEY)');
      await db.execute(
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, course_id INTEGER NOT NULL, title TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE local_concepts (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL, title TEXT NOT NULL, note_id INTEGER, created_at TEXT NOT NULL, UNIQUE(course_id,title))',
      );
      await db.execute(
        'CREATE TABLE local_edges (id INTEGER PRIMARY KEY AUTOINCREMENT, course_id INTEGER NOT NULL, source_id INTEGER NOT NULL, target_id INTEGER NOT NULL, kind TEXT NOT NULL, UNIQUE(course_id,source_id,target_id,kind))',
      );
      await db.execute('INSERT INTO courses VALUES (1), (2)');
      await db.execute("INSERT INTO notes VALUES (1,1,'资料'), (2,2,'其他')");
      final graph = LocalKnowledge(db, 1);
      await graph.addConcept('A', noteId: 1);
      await graph.addConcept('B');
      await graph.addConcept('C');
      final nodes = await graph.concepts();
      final ids = {for (final n in nodes) n['title'] as String: n['id'] as int};
      await graph.addEdge(ids['A']!, ids['B']!, 'prerequisite');
      await graph.addEdge(ids['B']!, ids['C']!, 'prerequisite');
      await expectLater(
        graph.addEdge(ids['C']!, ids['A']!, 'prerequisite'),
        throwsStateError,
      );
      await expectLater(graph.addConcept('wrong', noteId: 2), throwsStateError);
      expect(await graph.edges(), hasLength(2));
      expect(nodes.firstWhere((n) => n['title'] == 'A')['source_title'], '资料');
      await db.close();
    },
  );
}
