import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhi_ai/focus_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test('completion is timed, atomic and cannot award twice', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''CREATE TABLE focus_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
      duration_seconds INTEGER NOT NULL, started_at TEXT NOT NULL, ended_at TEXT,
      state TEXT NOT NULL, points INTEGER NOT NULL DEFAULT 0)''');
    await db.execute(
      "CREATE UNIQUE INDEX one_running_focus ON focus_sessions(state) WHERE state = 'running'",
    );
    await db.execute(
      'CREATE TABLE focus_rest (id INTEGER PRIMARY KEY, ends_at TEXT NOT NULL)',
    );
    final store = FocusStore(db);
    final start = DateTime.utc(2026, 1, 1);
    final id = await store.start('数学', 25, at: start);
    expect(
      await store.complete(id, at: start.add(const Duration(minutes: 24))),
      isFalse,
    );
    final results = await Future.wait([
      store.complete(id, at: start.add(const Duration(minutes: 25))),
      store.complete(id, at: start.add(const Duration(minutes: 25))),
    ]);
    expect(results.where((v) => v), hasLength(1));
    final records = await store.completed();
    expect(records.single['points'], 25);
    expect(records.single['category'], '数学');
    expect(
      records.single['ended_at'],
      start.add(const Duration(minutes: 25)).toIso8601String(),
    );
    expect(await store.active(), isNull);
    expect(
      await store.activeRest(at: start.add(const Duration(minutes: 26))),
      start.add(const Duration(minutes: 30)),
    );
    await expectLater(
      store.start('复习', 15, at: start.add(const Duration(minutes: 26))),
      throwsStateError,
    );
    await store.skipRest();
    expect(
      await store.activeRest(at: start.add(const Duration(minutes: 26))),
      isNull,
    );
    expect(
      await store.start('复习', 15, at: start.add(const Duration(minutes: 26))),
      isPositive,
    );
    await db.close();
  });
  test('local rewards cannot be spent or fed twice concurrently', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      "CREATE TABLE focus_sessions (id INTEGER PRIMARY KEY, state TEXT NOT NULL, points INTEGER NOT NULL)",
    );
    await db.execute(
      "CREATE TABLE focus_spends (id INTEGER PRIMARY KEY AUTOINCREMENT, item TEXT NOT NULL, cost INTEGER NOT NULL, at TEXT NOT NULL)",
    );
    await db.execute(
      "CREATE TABLE focus_inventory (item TEXT PRIMARY KEY, qty INTEGER NOT NULL CHECK(qty >= 0))",
    );
    await db.execute(
      "CREATE TABLE local_pet (id INTEGER PRIMARY KEY, exp INTEGER NOT NULL)",
    );
    await db.execute("INSERT INTO local_pet VALUES (1, 0)");
    await db.execute("INSERT INTO focus_sessions VALUES (1, 'completed', 5)");
    final store = FocusStore(db);
    Future<bool> attempt(Future<void> Function() action) async {
      try {
        await action();
        return true;
      } catch (_) {
        return false;
      }
    }

    final buys = await Future.wait([
      attempt(store.buySeed),
      attempt(store.buySeed),
    ]);
    expect(buys.where((v) => v), hasLength(1));
    expect(await store.growth(), {'balance': 0, 'seed': 1, 'exp': 0});
    final feeds = await Future.wait([
      attempt(store.feedSeed),
      attempt(store.feedSeed),
    ]);
    expect(feeds.where((v) => v), hasLength(1));
    expect(await store.growth(), {'balance': 0, 'seed': 0, 'exp': 5});
    await db.close();
  });
}
