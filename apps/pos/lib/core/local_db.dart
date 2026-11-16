import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local storage on the tablet.
///
/// * `master` keeps every row pulled from the server (items, prices,
///   customers, limits ...) as JSON, keyed by table and id.
/// * `doc` keeps documents made on this tablet (bills, receipts, shifts ...).
/// * `outbox` lists documents not yet accepted by the server.
/// * `kv` holds settings: server URL, device, session, sync cursor, counters.
///
/// Rows are stored whole, so a change in the server schema never needs a
/// tablet migration for masters.
class LocalDb {
  LocalDb._(this.db);
  final Database db;

  static Future<LocalDb> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'kwikerp_pos.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute(
            'CREATE TABLE master (tbl TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (tbl, id))');
        await db.execute(
            'CREATE TABLE doc (tbl TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, created_at TEXT NOT NULL, '
            'PRIMARY KEY (tbl, id))');
        await db.execute(
            'CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, tbl TEXT NOT NULL, id TEXT NOT NULL)');
        await db.execute('CREATE INDEX outbox_tbl ON outbox (tbl, id)');
      },
    );
    return LocalDb._(db);
  }

  // ---- settings ----
  Future<String?> get(String key) async {
    final r = await db.query('kv', where: 'k = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> set(String key, String? value) async {
    if (value == null) {
      await db.delete('kv', where: 'k = ?', whereArgs: [key]);
    } else {
      await db.insert('kv', {'k': key, 'v': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ---- masters ----
  Future<void> putMasters(String table, List<dynamic> rows) async {
    final batch = db.batch();
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      batch.insert('master', {'tbl': table, 'id': m['id'].toString(), 'data': jsonEncode(m)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> masters(String table) async {
    final r = await db.query('master', columns: ['data'], where: 'tbl = ?', whereArgs: [table]);
    return r
        .map((e) => Map<String, dynamic>.from(jsonDecode(e['data'] as String) as Map))
        .where((m) => m['deleted_at'] == null)
        .toList();
  }

  // ---- documents made on this tablet ----
  /// Saves a document and queues it for the server, in one transaction.
  Future<void> saveDocs(Map<String, List<Map<String, dynamic>>> docs) async {
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      for (final entry in docs.entries) {
        for (final row in entry.value) {
          final id = row['id'].toString();
          final existing = await txn.query('doc', columns: ['created_at'], where: 'tbl = ? AND id = ?',
              whereArgs: [entry.key, id]);
          await txn.insert(
              'doc',
              {
                'tbl': entry.key,
                'id': id,
                'data': jsonEncode(row),
                'created_at': existing.isEmpty ? now : existing.first['created_at'],
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          await txn.delete('outbox', where: 'tbl = ? AND id = ?', whereArgs: [entry.key, id]);
          await txn.insert('outbox', {'tbl': entry.key, 'id': id});
        }
      }
    });
  }

  Future<List<Map<String, dynamic>>> docs(String table, {String? since}) async {
    final r = await db.query('doc',
        columns: ['data'],
        where: since == null ? 'tbl = ?' : 'tbl = ? AND created_at >= ?',
        whereArgs: since == null ? [table] : [table, since],
        orderBy: 'created_at');
    return r.map((e) => Map<String, dynamic>.from(jsonDecode(e['data'] as String) as Map)).toList();
  }

  /// Lines of one bill (line ids start with the bill id's first 24 characters).
  Future<List<Map<String, dynamic>>> invoiceLines(String invoiceId) async {
    final r = await db.query('doc',
        columns: ['data'],
        where: 'tbl = ? AND id LIKE ?',
        whereArgs: ['sales_invoice_line', '${invoiceId.substring(0, 24)}%']);
    return r
        .map((e) => Map<String, dynamic>.from(jsonDecode(e['data'] as String) as Map))
        .where((m) => m['invoice_id'] == invoiceId)
        .toList()
      ..sort((a, b) => (a['line_no'] as num).compareTo(b['line_no'] as num));
  }

  /// Changes a stored document without sending it to the server again
  /// (for changes the server already made, like a cancellation).
  Future<void> patchDoc(String table, String id, Map<String, dynamic> changes) async {
    final r = await db.query('doc', columns: ['data'], where: 'tbl = ? AND id = ?', whereArgs: [table, id]);
    if (r.isEmpty) return;
    final m = Map<String, dynamic>.from(jsonDecode(r.first['data'] as String) as Map)..addAll(changes);
    await db.update('doc', {'data': jsonEncode(m)}, where: 'tbl = ? AND id = ?', whereArgs: [table, id]);
  }

  Future<Map<String, dynamic>?> doc(String table, String id) async {
    final r = await db.query('doc', columns: ['data'], where: 'tbl = ? AND id = ?', whereArgs: [table, id]);
    return r.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(r.first['data'] as String) as Map);
  }

  // ---- outbox ----
  Future<int> pendingCount() async {
    final r = await db.rawQuery('SELECT count(DISTINCT tbl || id) AS n FROM outbox');
    return (r.first['n'] as int?) ?? 0;
  }

  /// Unsynced documents grouped by table, plus the outbox seq they came from.
  Future<(Map<String, List<Map<String, dynamic>>>, int)> outboxBatch({int limit = 500}) async {
    final rows = await db.rawQuery(
        'SELECT o.seq, o.tbl, d.data FROM outbox o JOIN doc d ON d.tbl = o.tbl AND d.id = o.id '
        'ORDER BY o.seq LIMIT ?',
        [limit]);
    final out = <String, List<Map<String, dynamic>>>{};
    var maxSeq = 0;
    for (final r in rows) {
      out.putIfAbsent(r['tbl'] as String, () => []).add(
          Map<String, dynamic>.from(jsonDecode(r['data'] as String) as Map));
      final seq = r['seq'] as int;
      if (seq > maxSeq) maxSeq = seq;
    }
    return (out, maxSeq);
  }

  Future<void> clearOutboxUpTo(int seq) async {
    await db.delete('outbox', where: 'seq <= ?', whereArgs: [seq]);
  }
}
