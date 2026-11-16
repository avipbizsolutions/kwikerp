import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/pos_state.dart';
import 'theme.dart';

/// Rate chart for owners and managers: one column per rate list, one chart for
/// all outlets. Saved on the server (needs internet); every tablet gets the
/// new rates at its next sync. Trays and boxes follow piece rate x pack size.
class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key});

  @override
  State<RatesScreen> createState() => _RatesScreenState();
}

class _RatesScreenState extends State<RatesScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  String? _catId;
  String _q = '';
  late DateTime _from = DateTime.now().add(const Duration(days: 1));
  final Map<String, double> _edits = {}; // "item|level" -> new rate
  final Map<String, Map<String, dynamic>> _prices = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = Map<String, dynamic>.from(await context.read<PosState>().onlineApi.getJson('/rates') as Map);
      _prices.clear();
      for (final p in d['prices'] as List) {
        _prices['${p['item_id']}|${p['price_level_id']}'] = Map<String, dynamic>.from(p as Map);
      }
      for (final c in _ctl.values) {
        c.dispose();
      }
      _ctl.clear();
      _edits.clear();
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    }
  }

  String _friendly(Object e) {
    final m = e.toString();
    return m.contains('Socket') || m.contains('Timeout') || m.contains('ClientException')
        ? 'No internet. The rate chart needs a connection.'
        : m;
  }

  double? _current(String k) => (_prices[k]?['price'] as num?)?.toDouble();

  TextEditingController _controller(String k) => _ctl.putIfAbsent(k, () {
        final v = _edits[k] ?? _current(k);
        return TextEditingController(text: v == null ? '' : v.toStringAsFixed(2));
      });

  void _changed(String k, String text) {
    final v = double.tryParse(text.trim().replaceAll(',', ''));
    setState(() {
      if (v == null || v < 0 || (v - (_current(k) ?? -1)).abs() < 0.001) {
        _edits.remove(k);
      } else {
        _edits[k] = (v * 100).roundToDouble() / 100;
      }
    });
  }

  bool _bigJump(String k) {
    final was = _current(k);
    final v = _edits[k];
    return was != null && was > 0 && v != null && (v - was).abs() / was > 0.3;
  }

  String _day(DateTime d) => d.toIso8601String().substring(0, 10);
  String _show(DateTime d) =>
      '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.year}';

  Future<void> _save() async {
    final jumps = _edits.keys.where(_bigJump).length;
    if (jumps > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Check these rates'),
          content: Text('$jumps rate(s) changed by more than 30% (shown in red). Save anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Go back')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _saving = true);
    try {
      final s = context.read<PosState>();
      final changes = _edits.entries.map((e) {
        final parts = e.key.split('|');
        return {'itemId': parts[0], 'levelId': parts[1], 'price': e.value};
      }).toList();
      final r = await s.onlineApi.postJson('/rates', {'effectiveFrom': _day(_from), 'changes': changes});
      await _load();
      s.sync?.syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Saved ${r['saved']} rates from ${_show(_from)}.'), backgroundColor: Kc.greenInk));
      }
    } catch (e) {
      if (mounted) showError(context, _friendly(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rate chart'),
        backgroundColor: Kc.navy,
        foregroundColor: Colors.white,
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Reload')],
      ),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, style: const TextStyle(color: Kc.red, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('Try again')),
                    ]))
          : _body(d),
      bottomNavigationBar: d == null ? null : _bar(),
    );
  }

  Widget _body(Map<String, dynamic> d) {
    final levels = (d['levels'] as List).cast<Map>();
    final items = (d['items'] as List).cast<Map>();
    final cats = <String, String>{};
    for (final i in items) {
      cats[(i['category_id'] ?? '') as String] = (i['category'] ?? 'No group') as String;
    }
    _catId ??= cats.keys.isEmpty ? null : cats.keys.first;
    final q = _q.trim().toLowerCase();
    final shown = items
        .where((i) => q.isNotEmpty
            ? (i['name'] as String).toLowerCase().contains(q) || '${i['code']}' == q
            : (i['category_id'] ?? '') == _catId)
        .toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          decoration: const InputDecoration(
              hintText: 'Search item or code', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.zero),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final c in cats.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ChoiceChip(
                label: Text(c.value),
                selected: q.isEmpty && c.key == _catId,
                showCheckmark: false,
                onSelected: (_) => setState(() {
                  _catId = c.key;
                  _q = '';
                }),
              ),
            ),
        ]),
      ),
      Container(
        color: const Color(0xFFF6F8FA),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          const SizedBox(width: 200, child: Text('Item', style: TextStyle(fontWeight: FontWeight.w700, color: Kc.muted))),
          for (final l in levels)
            Expanded(
              child: Text(l['name'] as String,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Kc.navy)),
            ),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          itemCount: shown.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, n) {
            final i = shown[n];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                SizedBox(
                  width: 200,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i['name']}${(i['pack_size'] ?? '') == '' ? '' : ' ${i['pack_size']}'}',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    Text('per ${(i['unit'] as String).toLowerCase()}${i['packs'] == null ? '' : ' · ${(i['packs'] as String).toLowerCase()}'}',
                        style: const TextStyle(fontSize: 12, color: Kc.muted)),
                  ]),
                ),
                for (final l in levels) Expanded(child: _cell('${i['id']}|${l['id']}')),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  Widget _cell(String k) {
    final edited = _edits.containsKey(k);
    final big = _bigJump(k);
    final next = _prices[k]?['next_price'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 44,
          child: TextField(
            controller: _controller(k),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 15, fontFeatures: [FontFeature.tabularFigures()]),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              filled: edited,
              fillColor: big ? const Color(0xFFFBE9E9) : Kc.amberBg,
            ),
            onChanged: (v) => _changed(k, v),
          ),
        ),
        if (next != null)
          Text('${(next as num).toStringAsFixed(2)} next',
              style: const TextStyle(fontSize: 10, color: Kc.blue), overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Widget _bar() => SafeArea(
        child: Container(
          decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Kc.line))),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text(_edits.isEmpty ? 'Tap a rate to change it' : '${_edits.length} rates changed',
                    style: TextStyle(fontWeight: FontWeight.w600, color: _edits.isEmpty ? Kc.muted : Kc.amberInk)),
              ),
              const Text('Apply from  ', style: TextStyle(color: Kc.muted)),
              OutlinedButton(
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(
                      context: context, initialDate: _from, firstDate: DateTime(now.year, now.month, now.day),
                      lastDate: now.add(const Duration(days: 365)));
                  if (d != null) setState(() => _from = d);
                },
                child: Text(_show(_from)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(
                width: 130,
                height: 56,
                child: OutlinedButton(
                  onPressed: _edits.isEmpty
                      ? null
                      : () => setState(() {
                            _edits.clear();
                            for (final c in _ctl.values) {
                              c.dispose();
                            }
                            _ctl.clear();
                          }),
                  child: const Text('Discard'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _edits.isEmpty || _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'SAVE ${_edits.length} CHANGES',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      );
}
