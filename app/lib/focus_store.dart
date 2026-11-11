import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

class _FocusEntry {
  _FocusEntry(this.db);
  final Database db;
  int references = 0;
}

/// On-device focus records and their local reward ledger.
class FocusStore {
  FocusStore(this.db) : _scope = null;
  FocusStore._shared(this.db, this._scope);
  final Database db;
  final String? _scope;
  bool _closed = false;
  static final _lock = Lock();
  static final _entries = <String, _FocusEntry>{};

  static Future<FocusStore> open({String scope = 'local'}) =>
      _lock.synchronized(() async {
        if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(scope)) {
          throw ArgumentError('无效的本地数据范围');
        }
        var entry = _entries[scope];
        if (entry == null) {
          final db = await openDatabase(
            path.join(await getDatabasesPath(), 'focus_$scope.db'),
            version: 4,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE focus_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        state TEXT NOT NULL CHECK(state IN ('running','completed','cancelled')),
        points INTEGER NOT NULL DEFAULT 0
      )''');
              await db.execute(
                "CREATE UNIQUE INDEX one_running_focus ON focus_sessions(state) WHERE state = 'running'",
              );
              await _createRewards(db);
              await _upgradePet(db);
              await _createRest(db);
            },
            onUpgrade: (db, oldVersion, _) async {
              if (oldVersion < 2) await _createRewards(db);
              if (oldVersion < 3) await _upgradePet(db);
              if (oldVersion < 4) await _createRest(db);
            },
          );
          entry = _FocusEntry(db);
          _entries[scope] = entry;
        }
        entry.references++;
        return FocusStore._shared(entry.db, scope);
      });

  Future<void> close() => _lock.synchronized(() async {
    if (_closed) return;
    _closed = true;
    if (_scope == null) {
      await db.close();
      return;
    }
    final entry = _entries[_scope];
    if (entry == null || !identical(entry.db, db))
      throw StateError('专注数据库连接状态无效');
    entry.references--;
    if (entry.references == 0) {
      _entries.remove(_scope);
      await entry.db.close();
    }
  });

  static Future<void> _createRest(DatabaseExecutor db) => db.execute(
    'CREATE TABLE focus_rest (id INTEGER PRIMARY KEY CHECK(id = 1), ends_at TEXT NOT NULL)',
  );

  Future<DateTime?> activeRest({DateTime? at}) async {
    final rows = await db.query('focus_rest', where: 'id = 1');
    if (rows.isEmpty) return null;
    final endsAt = DateTime.parse(rows.first['ends_at'] as String).toUtc();
    return (at ?? DateTime.now()).toUtc().isBefore(endsAt) ? endsAt : null;
  }

  Future<void> skipRest() async => db.delete('focus_rest', where: 'id = 1');

  static Future<void> _createRewards(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE focus_spends (id INTEGER PRIMARY KEY AUTOINCREMENT, item TEXT NOT NULL, cost INTEGER NOT NULL, at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE focus_inventory (item TEXT PRIMARY KEY, qty INTEGER NOT NULL CHECK(qty >= 0))',
    );
    await db.execute(
      'CREATE TABLE local_pet (id INTEGER PRIMARY KEY CHECK(id = 1), exp INTEGER NOT NULL)',
    );
    await db.execute('INSERT INTO local_pet (id, exp) VALUES (1, 0)');
  }

  static Future<void> _upgradePet(DatabaseExecutor db) async {
    await db.execute(
      "ALTER TABLE local_pet ADD COLUMN name TEXT NOT NULL DEFAULT '小啄'",
    );
    await db.execute(
      "ALTER TABLE local_pet ADD COLUMN avatar_key TEXT NOT NULL DEFAULT 'bird_1'",
    );
  }

  Future<Map<String, Object?>> pet() async =>
      (await db.query('local_pet', where: 'id = 1')).single;

  Future<void> customizePet(String name, String avatarKey) async {
    const avatars = {'bird_1', 'bird_mint', 'bird_blue', 'bird_rose'};
    if (name.trim().isEmpty ||
        name.trim().length > 20 ||
        !avatars.contains(avatarKey))
      throw ArgumentError('名字或配色无效');
    await db.update('local_pet', {
      'name': name.trim(),
      'avatar_key': avatarKey,
    }, where: 'id = 1');
  }

  static Future<int> _balance(DatabaseExecutor tx) async {
    final earned = Sqflite.firstIntValue(
      await tx.rawQuery(
        "SELECT COALESCE(SUM(points), 0) FROM focus_sessions WHERE state='completed'",
      ),
    )!;
    final spent = Sqflite.firstIntValue(
      await tx.rawQuery('SELECT COALESCE(SUM(cost), 0) FROM focus_spends'),
    )!;
    return earned - spent;
  }

  Future<Map<String, int>> growth() async => db.transaction((tx) async {
    final total = await _balance(tx);
    final rows = await tx.query(
      'focus_inventory',
      where: 'item = ?',
      whereArgs: ['seed'],
    );
    final exp = Sqflite.firstIntValue(
      await tx.rawQuery('SELECT exp FROM local_pet WHERE id=1'),
    )!;
    return {
      'balance': total,
      'seed': rows.isEmpty ? 0 : rows.first['qty'] as int,
      'exp': exp,
    };
  });

  Future<void> buySeed() => db.transaction((tx) async {
    if (await _balance(tx) < 5) throw StateError('积分不足');
    await tx.insert('focus_spends', {
      'item': 'seed',
      'cost': 5,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    await tx.rawInsert(
      "INSERT OR IGNORE INTO focus_inventory(item, qty) VALUES('seed', 0)",
    );
    await tx.rawUpdate(
      "UPDATE focus_inventory SET qty=qty+1 WHERE item='seed'",
    );
  });

  Future<void> feedSeed() => db.transaction((tx) async {
    final changed = await tx.rawUpdate(
      "UPDATE focus_inventory SET qty=qty-1 WHERE item='seed' AND qty>0",
    );
    if (changed != 1) throw StateError('背包中没有谷粒');
    await tx.rawUpdate('UPDATE local_pet SET exp=exp+5 WHERE id=1');
  });

  Future<Map<String, Object?>?> active() async {
    final rows = await db.query(
      'focus_sessions',
      where: 'state = ?',
      whereArgs: ['running'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> start(String category, int minutes, {DateTime? at}) async {
    if (category.trim().isEmpty ||
        category.length > 40 ||
        minutes < 1 ||
        minutes > 180) {
      throw ArgumentError('专注类别或时长无效');
    }
    final startedAt = (at ?? DateTime.now()).toUtc();
    return db.transaction((tx) async {
      final rest = await tx.query('focus_rest', where: 'id = 1');
      if (rest.isNotEmpty &&
          startedAt.isBefore(DateTime.parse(rest.first['ends_at'] as String))) {
        throw StateError('休息尚未结束，请先结束休息');
      }
      await tx.delete('focus_rest', where: 'id = 1');
      return tx.insert('focus_sessions', {
        'category': category.trim(),
        'duration_seconds': minutes * 60,
        'started_at': startedAt.toIso8601String(),
        'state': 'running',
      });
    });
  }

  /// Completion and reward are recorded atomically; repeated completion is safe.
  Future<bool> complete(int id, {DateTime? at}) async {
    final end = (at ?? DateTime.now()).toUtc();
    return db.transaction((tx) async {
      final rows = await tx.query(
        'focus_sessions',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['state'] != 'running') return false;
      final row = rows.first;
      final start = DateTime.parse(row['started_at'] as String);
      final seconds = row['duration_seconds'] as int;
      if (end.difference(start).inSeconds < seconds) return false;
      final updated = await tx.update(
        'focus_sessions',
        {
          'state': 'completed',
          // Credit the date on which the timer elapsed, even if the app was
          // reopened later and only then finalized the session.
          'ended_at': start.add(Duration(seconds: seconds)).toIso8601String(),
          'points': seconds ~/ 60,
        },
        where: 'id = ? AND state = ?',
        whereArgs: [id, 'running'],
      );
      if (updated == 1) {
        final restEnd = start.add(Duration(seconds: seconds + 5 * 60));
        if (end.isBefore(restEnd)) {
          await tx.insert('focus_rest', {
            'id': 1,
            'ends_at': restEnd.toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      return updated == 1;
    });
  }

  Future<void> cancel(int id) async => db.update(
    'focus_sessions',
    {
      'state': 'cancelled',
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    },
    where: 'id = ? AND state = ?',
    whereArgs: [id, 'running'],
  );

  Future<List<Map<String, Object?>>> completed() => db.query(
    'focus_sessions',
    where: 'state = ?',
    whereArgs: ['completed'],
    orderBy: 'ended_at DESC',
  );
}
