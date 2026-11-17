import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/catalog.dart';
import '../core/pos_state.dart';
import 'theme.dart';

/// Stock at this outlet: receive goods from the plant, send returns, ask for
/// adjustments (approved at head office) and count stock.
class StockScreen extends StatelessWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final tabs = <(String, Widget)>[
      if (s.can('stock.receive')) ('Incoming', const _IncomingTab()),
      ('Stock', const _StockTab()),
      if (s.can('stock.receive')) ('Return to plant', const _ReturnTab()),
      if (s.can('stock.count')) ('Count stock', const _CountTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Stock · ${s.device?.locationCode ?? ''}'),
          backgroundColor: Kc.navy,
          foregroundColor: Colors.white,
          bottom: TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: const Color(0xFFC9D6E6),
            indicatorColor: Colors.white,
            tabs: [for (final t in tabs) Tab(text: t.$1)],
          ),
        ),
        body: Column(children: [
          if (s.stockQueued > 0 || s.stockQueueError != null)
            Container(
              width: double.infinity,
              color: s.stockQueueError != null ? const Color(0xFFFBE9E9) : Kc.amberBg,
              padding: const EdgeInsets.all(10),
              child: Text(
                s.stockQueueError != null
                    ? 'Not accepted by head office: ${s.stockQueueError}'
                    : '${s.stockQueued} stock request(s) waiting for internet. They go with the next sync.',
                style: TextStyle(color: s.stockQueueError != null ? Kc.red : Kc.amberInk, fontWeight: FontWeight.w600),
              ),
            ),
          Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
        ]),
      ),
    );
  }
}

String _qty(num q) => q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(3);

String _netError(Object e) {
  final m = e.toString();
  return m.contains('Socket') || m.contains('Timeout') || m.contains('ClientException') || m.contains('Failed host')
      ? 'No internet. Try again when the tablet is online.'
      : m;
}

Widget _errorBox(String msg, VoidCallback retry) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: Kc.red, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: retry, child: const Text('Try again')),
        ]),
      ),
    );

List<Item> _items(PosState s, String q) {
  final list = s.catalog!.items.values.where((i) => i.row['is_active'] == true).toList();
  final query = q.trim().toLowerCase();
  final out = query.isEmpty
      ? list
      : list.where((i) => i.name.toLowerCase().contains(query) || i.code.toLowerCase() == query).toList();
  out.sort((a, b) => a.fullName.compareTo(b.fullName));
  return out;
}

Widget _search(ValueChanged<String> onChanged) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search), hintText: 'Find item', border: OutlineInputBorder(), isDense: true),
        onChanged: onChanged,
      ),
    );

// ------------------------------------------------------------------ incoming

class _IncomingTab extends StatefulWidget {
  const _IncomingTab();
  @override
  State<_IncomingTab> createState() => _IncomingTabState();
}

class _IncomingTabState extends State<_IncomingTab> {
  List<Map<String, dynamic>>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await context.read<PosState>().onlineApi.getJson('/stock/transfers?incoming=1');
      if (mounted) setState(() => _list = (d as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      if (mounted) setState(() => _error = _netError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _errorBox(_error!, _load);
    final list = _list;
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [
          Padding(padding: EdgeInsets.all(32), child: Text('Nothing on the way to this outlet.', textAlign: TextAlign.center)),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        for (final t in list)
          Card(
            child: ListTile(
              title: Text('From ${t['from_name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              subtitle: Text('${t['doc_no'] ?? ''} · ${t['lines']} items · ${_qty(t['sent'] as num)} pieces'
                  '${t['vehicle'] != null ? ' · ${t['vehicle']}' : ''}${t['driver'] != null ? ' · ${t['driver']}' : ''}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final done = await Navigator.of(context)
                    .push<bool>(MaterialPageRoute(builder: (_) => _ReceiveScreen(id: t['id'] as String)));
                if (done == true) _load();
              },
            ),
          ),
      ]),
    );
  }
}

class _ReceiveScreen extends StatefulWidget {
  const _ReceiveScreen({required this.id});
  final String id;
  @override
  State<_ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<_ReceiveScreen> {
  Map<String, dynamic>? _t;
  String? _error;
  final Map<String, TextEditingController> _got = {};
  final Map<String, String> _why = {};
  bool _busy = false;

  static const _reasons = [('short', 'Short'), ('damaged', 'Damaged'), ('extra', 'Extra'), ('wrong', 'Wrong item')];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _got.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = Map<String, dynamic>.from(await context.read<PosState>().onlineApi.getJson('/stock/transfers/${widget.id}') as Map);
      for (final l in (d['lines'] as List).cast<Map>()) {
        _got[l['id'] as String] = TextEditingController(text: _qty(l['qty_sent'] as num));
      }
      if (mounted) setState(() => _t = d);
    } catch (e) {
      if (mounted) setState(() => _error = _netError(e));
    }
  }

  double _sent(Map l) => (l['qty_sent'] as num).toDouble();
  double? _gotOf(Map l) => double.tryParse(_got[l['id']]!.text.trim());

  Future<void> _confirm() async {
    final t = _t!;
    final lines = (t['lines'] as List).cast<Map>();
    final body = <Map<String, dynamic>>[];
    for (final l in lines) {
      final g = _gotOf(l);
      if (g == null || g < 0) { showError(context, 'Check the number for ${l['name']}'); return; }
      final differs = (g - _sent(l)).abs() > 0.0005;
      if (differs && _why[l['id']] == null) { showError(context, 'Say why ${l['name']} is different'); return; }
      body.add({'id': l['id'], 'received': g, if (differs) 'reason': _why[l['id']]});
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<PosState>().sendStock(
          '/stock/transfers/${widget.id}/receive', {'lines': body}, 'Receipt ${t['doc_no']}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == null ? 'Saved. It goes to head office when the tablet is online.' : 'Received. Stock added.')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: const Text('Receive goods'), backgroundColor: Kc.navy, foregroundColor: Colors.white),
      body: _error != null
          ? _errorBox(_error!, _load)
          : t == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Expanded(
                    child: ListView(padding: const EdgeInsets.all(12), children: [
                      Card(
                        child: ListTile(
                          title: Text('From ${t['from_name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                          subtitle: Text('${t['doc_no']} · sent by ${t['sent_by'] ?? ''}'
                              '${t['vehicle'] != null ? ' · ${t['vehicle']}' : ''}${t['driver'] != null ? ' · ${t['driver']}' : ''}'),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Count what has arrived. Change the number only where it differs and choose why. '
                            'Do not count damaged pieces as received; give them back to the vehicle.',
                            style: TextStyle(color: Kc.muted)),
                      ),
                      for (final l in (t['lines'] as List).cast<Map>()) _line(l),
                    ]),
                  ),
                  SafeArea(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(child: Text(_summary(t), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(200, 56)),
                          onPressed: _busy ? null : _confirm,
                          child: const Text('Confirm receipt', style: TextStyle(fontSize: 17)),
                        ),
                      ]),
                    ),
                  ),
                ]),
    );
  }

  String _summary(Map t) {
    var sent = 0.0, got = 0.0;
    for (final l in (t['lines'] as List).cast<Map>()) {
      sent += _sent(l);
      got += _gotOf(l) ?? 0;
    }
    return 'Received ${_qty(got)} of ${_qty(sent)} pieces';
  }

  Widget _line(Map l) {
    final g = _gotOf(l);
    final differs = g != null && (g - _sent(l)).abs() > 0.0005;
    final pack = l['pack_factor'] == null ? '' : ' · ${(l['pack_name'] ?? 'pack').toString().toLowerCase()} of ${_qty(l['pack_factor'] as num)}';
    return Card(
      color: differs ? const Color(0xFFFFF8EF) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l['name'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                Text('Sent ${_qty(l['qty_sent'] as num)}$pack', style: const TextStyle(color: Kc.muted)),
              ]),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _got[l['id']],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                decoration: const InputDecoration(labelText: 'Received', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          if (differs) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _reasons)
                ChoiceChip(
                  label: Text(r.$2),
                  selected: _why[l['id']] == r.$1,
                  onSelected: (_) => setState(() => _why[l['id'] as String] = r.$1),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

// --------------------------------------------------------------------- stock

class _StockTab extends StatefulWidget {
  const _StockTab();
  @override
  State<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends State<_StockTab> {
  Map<String, double> _have = {};
  Map<String, double> _sold = {};
  String? _asOf;
  bool _offline = false;
  String _q = '';
  List<Map<String, dynamic>> _requests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _apply(Map d) {
    _have = {};
    _sold = {};
    for (final r in (d['items'] as List).cast<Map>()) {
      _have[r['item_id'] as String] = (r['qty'] as num?)?.toDouble() ?? 0;
      _sold[r['item_id'] as String] = (r['sold_today'] as num?)?.toDouble() ?? 0;
    }
    _asOf = d['asOf'] as String?;
  }

  Future<void> _load() async {
    final s = context.read<PosState>();
    try {
      final d = Map<String, dynamic>.from(await s.onlineApi.getJson('/stock/here') as Map);
      await s.db.set('stock_here', jsonEncode(d));
      List<Map<String, dynamic>> req = [];
      if (s.can('stock.adjust.request')) {
        req = ((await s.onlineApi.getJson('/stock/adjustments?status=all&days=7')) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      if (mounted) {
        setState(() {
          _apply(d);
          _requests = req;
          _offline = false;
        });
      }
    } catch (_) {
      final raw = await s.db.get('stock_here');
      if (mounted) {
        setState(() {
          if (raw != null) _apply(jsonDecode(raw) as Map);
          _offline = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final items = _items(s, _q);
    final asOf = _asOf == null ? null : DateTime.tryParse(_asOf!)?.toLocal();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        _search((v) => setState(() => _q = v)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Text(
            '${_offline ? 'Offline. ' : ''}${asOf == null ? 'Stock not loaded yet.' : 'As of ${TimeOfDay.fromDateTime(asOf).format(context)}, ${asOf.day}/${asOf.month}.'}'
            '${s.can('stock.adjust.request') ? ' Tap an item to report wastage, expiry, breakage or a count difference.' : ''}',
            style: const TextStyle(color: Kc.muted),
          ),
        ),
        if (_requests.isNotEmpty)
          Card(
            margin: const EdgeInsets.all(12),
            child: ExpansionTile(
              title: Text('My requests this week (${_requests.where((r) => r['status'] == 'pending').length} waiting)'),
              children: [
                for (final r in _requests)
                  ListTile(
                    dense: true,
                    title: Text('${r['item_name']} ${(r['qty'] as num) > 0 ? '+' : ''}${_qty(r['qty'] as num)}'),
                    subtitle: Text('${r['reason']}${r['decision_note'] != null ? ' · ${r['decision_note']}' : ''}'),
                    trailing: Text(
                      {'pending': 'Waiting', 'approved': 'Approved', 'rejected': 'Rejected'}[r['status']] ?? '${r['status']}',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: r['status'] == 'approved' ? Kc.greenInk : r['status'] == 'rejected' ? Kc.red : Kc.amberInk),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: const Row(children: [
            Expanded(child: Text('Item', style: TextStyle(fontWeight: FontWeight.w700, color: Kc.muted))),
            SizedBox(width: 90, child: Text('In stock', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: Kc.muted))),
            SizedBox(width: 90, child: Text('Sold today', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: Kc.muted))),
          ]),
        ),
        for (final i in items)
          Material(
            color: Colors.white,
            child: InkWell(
              onTap: s.can('stock.adjust.request') ? () => _adjust(i) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE3E8EE)))),
                child: Row(children: [
                  Expanded(child: Text(i.fullName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  SizedBox(
                    width: 90,
                    child: Text(_qty(_haveOf(i.id)),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700, color: _haveOf(i.id) < 0 ? Kc.red : Kc.ink)),
                  ),
                  SizedBox(width: 90, child: Text(_qty(_sold[i.id] ?? 0), textAlign: TextAlign.right)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  double _haveOf(String id) => _have[id] ?? 0;

  Future<void> _adjust(Item i) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AdjustSheet(item: i, inStock: _haveOf(i.id)),
    );
    if (sent == true) _load();
  }
}

class _AdjustSheet extends StatefulWidget {
  const _AdjustSheet({required this.item, required this.inStock});
  final Item item;
  final double inStock;
  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  static const _reasons = [
    ('wastage', 'Wastage / spoilt'),
    ('expired', 'Expired'),
    ('broken', 'Broken / leaked'),
    ('count', 'Count is different'),
    ('sample', 'Free sample / staff'),
    ('other', 'Other'),
  ];
  String _reason = 'wastage';
  bool _add = false; // only for "count is different"
  final _qtyC = TextEditingController();
  final _noteC = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _qtyC.dispose();
    _noteC.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final q = double.tryParse(_qtyC.text.trim());
    if (q == null || q <= 0) { showError(context, 'Enter how many pieces'); return; }
    if (_reason == 'other' && _noteC.text.trim().isEmpty) { showError(context, 'Write a note for "Other"'); return; }
    setState(() => _busy = true);
    try {
      final r = await context.read<PosState>().sendStock('/stock/adjustments', {
        'id': newId(),
        'itemId': widget.item.id,
        'qty': (_add && _reason == 'count') ? q : -q,
        'reason': _reason,
        'note': _noteC.text.trim(),
      }, 'Adjustment ${widget.item.name}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == null
              ? 'Saved. It goes for approval when the tablet is online.'
              : 'Sent for approval. Stock changes once a manager approves.')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: Text('Adjust: ${widget.item.fullName}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
              Text('In stock ${_qty(widget.inStock)}', style: const TextStyle(color: Kc.muted)),
            ]),
            const SizedBox(height: 12),
            const Text('Why is stock changing?', style: TextStyle(color: Kc.muted)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _reasons)
                ChoiceChip(label: Text(r.$2), selected: _reason == r.$1, onSelected: (_) => setState(() => _reason = r.$1)),
            ]),
            if (_reason == 'count') ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Fewer than the system')),
                  ButtonSegment(value: true, label: Text('More than the system')),
                ],
                selected: {_add},
                onSelectionChanged: (v) => setState(() => _add = v.first),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _qtyC,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                      labelText: (_add && _reason == 'count') ? 'Pieces to add' : 'Pieces to remove',
                      border: const OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                    controller: _noteC, decoration: const InputDecoration(labelText: 'Note', border: OutlineInputBorder())),
              ),
            ]),
            const SizedBox(height: 10),
            const Text('Stock does not change until an Owner or Manager approves.', style: TextStyle(color: Kc.muted)),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : _send,
              child: const Text('Send for approval', style: TextStyle(fontSize: 17)),
            ),
          ]),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- return

class _ReturnTab extends StatefulWidget {
  const _ReturnTab();
  @override
  State<_ReturnTab> createState() => _ReturnTabState();
}

class _RetLine {
  _RetLine(this.item);
  final Item item;
  final qty = TextEditingController();
  String reason = 'damaged';
}

class _ReturnTabState extends State<_ReturnTab> {
  String _id = newId();
  String _q = '';
  final List<_RetLine> _lines = [];
  final _noteC = TextEditingController();
  bool _busy = false;
  static const _reasons = [('damaged', 'Damaged'), ('expired', 'Expired'), ('unsold', 'Unsold'), ('other', 'Other')];

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
    }
    _noteC.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final q = double.tryParse(l.qty.text.trim());
      if (q == null || q <= 0) { showError(context, 'Enter the quantity for ${l.item.name}'); return; }
      body.add({'itemId': l.item.id, 'qty': q, 'reason': l.reason});
    }
    if (body.isEmpty) { showError(context, 'Add the items you are sending back'); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send back to the plant?'),
        content: Text('${body.length} items leave this outlet\'s stock now. The plant confirms what it gets.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await context
          .read<PosState>()
          .sendStock('/stock/returns', {'id': _id, 'lines': body, 'note': _noteC.text.trim()}, 'Return to plant');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == null
              ? 'Saved. It goes to head office when the tablet is online.'
              : 'Sent: ${(r as Map)['docNo']}. Hand the goods over with the vehicle.')));
      setState(() {
        _lines.clear();
        _noteC.clear();
        _id = newId();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final found = _q.trim().length < 2 ? <Item>[] : _items(s, _q).take(8).toList();
    return Column(children: [
      Expanded(
        child: ListView(children: [
          _search((v) => setState(() => _q = v)),
          for (final i in found)
            ListTile(
              title: Text(i.fullName),
              trailing: const Icon(Icons.add),
              onTap: () => setState(() {
                if (!_lines.any((l) => l.item.id == i.id)) _lines.add(_RetLine(i));
              }),
            ),
          if (_lines.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Find the items you are sending back and add them.', textAlign: TextAlign.center, style: TextStyle(color: Kc.muted)),
            ),
          for (final l in _lines)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(l.item.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: l.qty,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(labelText: 'Pieces', border: OutlineInputBorder()),
                      ),
                    ),
                    IconButton(
                        tooltip: 'Remove',
                        onPressed: () => setState(() => _lines.remove(l)),
                        icon: const Icon(Icons.close)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    for (final r in _reasons)
                      ChoiceChip(label: Text(r.$2), selected: l.reason == r.$1, onSelected: (_) => setState(() => l.reason = r.$1)),
                  ]),
                ]),
              ),
            ),
          if (_lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(controller: _noteC, decoration: const InputDecoration(labelText: 'Note', border: OutlineInputBorder())),
            ),
        ]),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _busy || _lines.isEmpty ? null : _send,
            child: const Text('Send back to plant', style: TextStyle(fontSize: 17)),
          ),
        ),
      ),
    ]);
  }
}

// --------------------------------------------------------------------- count

class _CountTab extends StatefulWidget {
  const _CountTab();
  @override
  State<_CountTab> createState() => _CountTabState();
}

class _CountTabState extends State<_CountTab> {
  String _id = newId();
  String? _startedAt;
  final Map<String, String> _counted = {};
  final Map<String, TextEditingController> _c = {};
  String _q = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Numbers typed so far survive leaving the screen or the app closing.
  Future<void> _restore() async {
    final raw = await context.read<PosState>().db.get('count_draft');
    if (raw == null || !mounted) return;
    final d = jsonDecode(raw) as Map;
    setState(() {
      _id = d['id'] as String;
      _startedAt = d['startedAt'] as String?;
      _counted.addAll(Map<String, String>.from(d['qty'] as Map));
    });
  }

  Future<void> _save() =>
      context.read<PosState>().db.set('count_draft', jsonEncode({'id': _id, 'startedAt': _startedAt, 'qty': _counted}));

  TextEditingController _ctl(String id) => _c.putIfAbsent(id, () => TextEditingController(text: _counted[id] ?? ''));

  Future<void> _finish() async {
    final s = context.read<PosState>();
    final lines = <Map<String, dynamic>>[];
    for (final e in _counted.entries) {
      final q = double.tryParse(e.value);
      if (q == null || q < 0) { showError(context, 'Counts must be numbers, 0 or more'); return; }
      lines.add({'itemId': e.key, 'counted': q});
    }
    if (lines.isEmpty) { showError(context, 'Type the count for at least one item'); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Finish the count?'),
        content: Text('${lines.length} items counted. Bills are sent first, then you see the differences.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Finish')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await s.sync?.syncNow(); // bills made during the count must reach the server first
      if (s.sync != null && s.sync!.pending > 0) {
        throw Exception('Some bills are not sent yet. Finish the count when the tablet is online; your numbers are kept.');
      }
      final r = Map<String, dynamic>.from(
          await s.onlineApi.postJson('/stock/counts', {'id': _id, 'startedAt': _startedAt, 'lines': lines}) as Map);
      await s.db.set('count_draft', null);
      if (!mounted) return;
      setState(() {
        _counted.clear();
        for (final c in _c.values) {
          c.clear();
        }
        _id = newId();
        _startedAt = null;
      });
      await _showResult(r);
    } catch (e) {
      if (mounted) showError(context, _netError(e).replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showResult(Map<String, dynamic> r) {
    final diffs = (r['lines'] as List).cast<Map>().where((l) => (l['diff'] as num) != 0).toList();
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(diffs.isEmpty ? 'Everything matches' : '${diffs.length} differences'),
        content: SizedBox(
          width: 480,
          child: diffs.isEmpty
              ? const Text('The count matches the system.')
              : ListView(shrinkWrap: true, children: [
                  for (final l in diffs)
                    ListTile(
                      dense: true,
                      title: Text(l['name'] as String),
                      subtitle: Text('Counted ${_qty(l['counted'] as num)} · system ${_qty(l['system_qty'] as num)}'),
                      trailing: Text('${(l['diff'] as num) > 0 ? '+' : ''}${_qty(l['diff'] as num)}',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: (l['diff'] as num) < 0 ? Kc.red : Kc.greenInk)),
                    ),
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Each difference has gone for approval. Stock changes once approved.',
                        style: TextStyle(color: Kc.muted)),
                  ),
                ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final items = _items(s, _q);
    return Column(children: [
      _search((v) => setState(() => _q = v)),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Text('Count what is on the shelf and type the number. The system quantity stays hidden until you finish. '
            'Leave an item empty if you did not count it.',
            style: TextStyle(color: Kc.muted)),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (_, n) {
            final i = items[n];
            final pf = s.packFactor(i);
            return Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(i.fullName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text('${i.soldByWeight ? 'kg' : 'pieces'}${pf > 0 ? ' · pack of ${_qty(pf)}' : ''}',
                        style: const TextStyle(color: Kc.muted, fontSize: 13)),
                  ]),
                ),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _ctl(i.id),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(hintText: '–', border: OutlineInputBorder(), isDense: true),
                    onChanged: (v) {
                      setState(() {
                        if (v.trim().isEmpty) {
                          _counted.remove(i.id);
                        } else {
                          _counted[i.id] = v.trim();
                        }
                        _startedAt ??= DateTime.now().toUtc().toIso8601String();
                      });
                      _save();
                    },
                  ),
                ),
              ]),
            );
          },
        ),
      ),
      SafeArea(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: Text('Counted ${_counted.length} items', style: const TextStyle(fontWeight: FontWeight.w700))),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(220, 56)),
              onPressed: _busy ? null : _finish,
              child: const Text('Finish and see differences', style: TextStyle(fontSize: 16)),
            ),
          ]),
        ),
      ),
    ]);
  }
}
