import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'local_db.dart';

/// Keeps the tablet and the server in step. Billing never waits for it.
///
/// Every [interval] (and on demand) it pushes unsynced documents, then pulls
/// changes since the last cursor. Failures just leave things queued.
class SyncService extends ChangeNotifier {
  SyncService(this.db, this.api, {this.interval = const Duration(seconds: 45)});

  final LocalDb db;
  final Api api;
  final Duration interval;

  /// Called after a pull that changed masters, so the catalog can reload.
  Future<void> Function()? onMastersChanged;
  /// Called when the server refuses this login (expired, or switched off by head office).
  Future<void> Function(String message)? onLoggedOut;

  Timer? _timer;
  bool _running = false;
  bool online = false;
  int pending = 0;
  DateTime? lastSync;
  String? lastError;

  // Must match the server's push order (foreign keys).
  static const pushOrder = [
    'customer', 'shift', 'sales_invoice', 'sales_invoice_line', 'receipt', 'stock_move', 'credit_approval',
  ];

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
    syncNow();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _disposed = true;
    super.dispose();
  }

  // A sync already running when the session ends (e.g. logged out by the
  // server) must not notify a disposed listener.
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> refreshPending() async {
    pending = await db.pendingCount();
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (_running) return;
    _running = true;
    try {
      await _pushAll();
      final changed = await _pull();
      online = true;
      lastError = null;
      lastSync = DateTime.now();
      if (changed && onMastersChanged != null) await onMastersChanged!();
    } catch (e) {
      online = false;
      lastError = e.toString();
      if (e is ApiException && e.status == 401 && onLoggedOut != null) {
        // Bills not yet sent stay on the tablet and go up after the next login.
        await onLoggedOut!(e.message);
      }
    } finally {
      _running = false;
      await refreshPending();
    }
  }

  Future<void> _pushAll() async {
    while (true) {
      final (batch, maxSeq) = await db.outboxBatch();
      if (batch.isEmpty) return;
      final ordered = <String, List<Map<String, dynamic>>>{};
      for (final t in pushOrder) {
        if (batch[t] != null) ordered[t] = batch[t]!;
      }
      await api.push(ordered);
      await db.clearOutboxUpTo(maxSeq);
    }
  }

  Future<bool> _pull() async {
    final since = int.tryParse(await db.get('cursor') ?? '0') ?? 0;
    final res = await api.pull(since, settingsVersion: await db.get('settings_version'));
    var changed = false;
    // Receipt layout, only sent when head office changed it
    final settings = res['settings'];
    if (settings is Map) {
      await db.set('receipt_settings', jsonEncode(settings['receipt']));
      await db.set('settings_version', settings['version']?.toString());
      changed = true;
    }
    final tables = Map<String, dynamic>.from(res['tables'] as Map);
    for (final e in tables.entries) {
      final rows = e.value as List<dynamic>;
      if (rows.isEmpty) continue;
      changed = true;
      await db.putMasters(e.key, rows);
    }
    // Outstanding snapshot: "customerId=amount=days;..."
    final snap = (res['outstanding'] as List<dynamic>)
        .map((o) => '${o['customer_id']}=${o['outstanding']}=${o['oldest_due_days']}')
        .join(';');
    if (snap != (await db.get('outstanding'))) {
      await db.set('outstanding', snap);
      changed = true;
    }
    // Bills made after this moment are added on top of the snapshot locally.
    await db.set('outstanding_at', DateTime.now().toIso8601String());
    await db.set('cursor', '${res['cursor']}');
    return changed;
  }
}
