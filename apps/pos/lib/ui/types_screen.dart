import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/pos_state.dart';
import 'theme.dart';

/// Customer types for owners and managers: rates each type bills at and its
/// default credit. Saved on the server (needs internet).
class CustomerTypesScreen extends StatefulWidget {
  const CustomerTypesScreen({super.key});

  @override
  State<CustomerTypesScreen> createState() => _CustomerTypesScreenState();
}

class _CustomerTypesScreenState extends State<CustomerTypesScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await context.read<PosState>().onlineApi.getJson('/customer-types');
      if (mounted) setState(() => _data = Map<String, dynamic>.from(d as Map));
    } catch (e) {
      final m = e.toString();
      if (mounted) {
        setState(() => _error = m.contains('Socket') || m.contains('Timeout') || m.contains('ClientException')
            ? 'No internet. Customer types need a connection.'
            : m);
      }
    }
  }

  String _credit(Map t) {
    if (t['credit_allowed'] != true) return 'no credit';
    final m = t['max_outstanding'];
    final d = t['max_days'];
    return '${m == null ? 'no amount limit' : money((m as num).toDouble(), paise: false)}${d == null ? '' : ' · $d days'}';
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer types'),
        backgroundColor: Kc.navy,
        foregroundColor: Colors.white,
        actions: [
          if (d != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Kc.navy),
                onPressed: () => _edit(null),
                child: const Text('+ Add'),
              ),
            ),
        ],
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
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final t in (d['types'] as List).cast<Map>())
                Card(
                  child: ListTile(
                    minVerticalPadding: 14,
                    title: Text('${t['name']}${t['is_active'] == true ? '' : '  (switched off)'}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    subtitle: Text('${t['price_level']} rates · ${_credit(t)} · ${t['customers']} customers'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _edit(t),
                  ),
                ),
            ]),
    );
  }

  Future<void> _edit(Map? t) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<PosState>(),
        child: _TypeForm(type: t, levels: (_data!['levels'] as List).cast<Map>()),
      ),
    );
    if (saved == true) {
      await _load();
      if (mounted) context.read<PosState>().sync?.syncNow();
    }
  }
}

class _TypeForm extends StatefulWidget {
  const _TypeForm({required this.type, required this.levels});
  final Map? type;
  final List<Map> levels;

  @override
  State<_TypeForm> createState() => _TypeFormState();
}

class _TypeFormState extends State<_TypeForm> {
  late final _name = TextEditingController(text: widget.type?['name'] as String? ?? '');
  late final _code = TextEditingController(text: widget.type?['code'] as String? ?? '');
  late final _limit = TextEditingController(
      text: widget.type == null ? '0' : (widget.type!['max_outstanding'] == null ? '' : '${(widget.type!['max_outstanding'] as num).round()}'));
  late final _days = TextEditingController(text: widget.type?['max_days']?.toString() ?? '');
  late String? _level = widget.type?['price_level_id'] as String? ?? widget.levels.first['id'] as String?;
  late bool _credit = widget.type?['credit_allowed'] as bool? ?? true;
  late bool _cap = widget.type?['cap_to_security'] as bool? ?? false;
  late bool _active = widget.type?['is_active'] as bool? ?? true;
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<PosState>().onlineApi.postJson('/customer-types', {
        if (widget.type != null) 'id': widget.type!['id'],
        'name': _name.text,
        'code': _code.text.isEmpty ? _name.text : _code.text,
        'priceLevelId': _level,
        'creditAllowed': _credit,
        'capToSecurity': _cap,
        'isActive': _active,
        'maxOutstanding': _limit.text.trim().isEmpty ? null : double.tryParse(_limit.text.replaceAll(',', '')),
        'maxDays': _days.text.trim().isEmpty ? null : int.tryParse(_days.text),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.type;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t == null ? 'New customer type' : 'Edit ${t['name']}',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(flex: 3, child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name *'))),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: TextField(controller: _code, decoration: const InputDecoration(labelText: 'Short code'))),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _level,
            decoration: const InputDecoration(labelText: 'Bill at these rates *'),
            items: [
              for (final l in widget.levels) DropdownMenuItem(value: l['id'] as String, child: Text(l['name'] as String)),
            ],
            onChanged: (v) => setState(() => _level = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Credit allowed', style: TextStyle(fontWeight: FontWeight.w600)),
            value: _credit,
            onChanged: (v) => setState(() => _credit = v),
          ),
          if (_credit) ...[
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _limit,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Credit limit (₹)', hintText: 'no amount limit'))),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: _days,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Oldest unpaid bill (days)', hintText: 'any age'))),
            ]),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Never above the security amount held'),
              value: _cap,
              onChanged: (v) => setState(() => _cap = v ?? false),
            ),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Active (shown when adding a customer)'),
            value: _active,
            onChanged: (v) => setState(() => _active = v ?? true),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: const TextStyle(color: Kc.red, fontWeight: FontWeight.w600)),
            ),
          SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : 'SAVE', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Saved on the server straight away; other tablets get it at their next sync.',
              style: TextStyle(color: Kc.muted, fontSize: 13)),
        ]),
      ),
    );
  }
}
