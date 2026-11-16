import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api.dart';
import 'catalog.dart';
import 'local_db.dart';

/// Product photos on this tablet: the company photo for each item (downloaded
/// once, kept for offline use, refreshed when head office changes it) and the
/// tablet's own photo where a cashier set one. Kept in memory for fast tiles.
class PhotoStore extends ChangeNotifier {
  PhotoStore(this.db);
  final LocalDb db;

  final Map<String, Uint8List> _company = {};
  final Map<String, Uint8List> _local = {};
  bool hidden = false; // "Hide photos on this tablet"
  bool _busy = false;
  late final Future<Directory> _dir = () async {
    final d = Directory(p.join(await getDatabasesPath(), 'photos'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }();

  Future<File> _file(String kind, String itemId) async => File(p.join((await _dir).path, '${kind}_$itemId.jpg'));

  /// The photo to show for an item: this tablet's own, else the company's.
  Uint8List? photoFor(String itemId) => _local[itemId] ?? _company[itemId];
  bool hasOwn(String itemId) => _local.containsKey(itemId);
  bool hasCompany(String itemId) => _company.containsKey(itemId);

  Future<void> load() async {
    hidden = (await db.get('photos_hidden')) == '1';
    final d = await _dir;
    for (final f in d.listSync().whereType<File>()) {
      final name = p.basenameWithoutExtension(f.path);
      final i = name.indexOf('_');
      if (i < 0) continue;
      final kind = name.substring(0, i), id = name.substring(i + 1);
      try {
        (kind == 'l' ? _local : _company)[id] = await f.readAsBytes();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> setHidden(bool v) async {
    hidden = v;
    await db.set('photos_hidden', v ? '1' : '0');
    notifyListeners();
  }

  /// Brings company photos in line with the item master (after each sync).
  Future<void> refresh(Catalog cat, Api api) async {
    if (_busy) return;
    _busy = true;
    var changed = false;
    try {
      for (final item in cat.items.values) {
        final v = item.row['image_version'] as String?;
        final have = await db.get('photo_v_${item.id}');
        if (v == null) {
          if (have != null || _company.containsKey(item.id)) {
            _company.remove(item.id);
            final f = await _file('c', item.id);
            if (await f.exists()) await f.delete();
            await db.set('photo_v_${item.id}', null);
            changed = true;
          }
          continue;
        }
        if (have == v && _company.containsKey(item.id)) continue;
        final bytes = await api.getBytes('/items/${item.id}/photo');
        if (bytes == null) continue;
        await (await _file('c', item.id)).writeAsBytes(bytes, flush: true);
        _company[item.id] = Uint8List.fromList(bytes);
        await db.set('photo_v_${item.id}', v);
        changed = true;
      }
    } catch (_) {
      // Offline or server busy: try again after the next sync.
    } finally {
      _busy = false;
      if (changed) notifyListeners();
    }
  }

  /// A cashier's own photo for an item, on this tablet only.
  Future<void> setOwn(String itemId, Uint8List bytes) async {
    await (await _file('l', itemId)).writeAsBytes(bytes, flush: true);
    _local[itemId] = bytes;
    notifyListeners();
  }

  Future<void> clearOwn(String itemId) async {
    final f = await _file('l', itemId);
    if (await f.exists()) await f.delete();
    _local.remove(itemId);
    notifyListeners();
  }
}
