import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/catalog.dart';
import '../core/pos_state.dart';
import 'theme.dart';

// ------------------------------------------------------------------ weight

/// Asks for a weight in kg. Returns null if cancelled.
Future<double?> askWeight(BuildContext context, Item item, double ratePerKg, double? current) {
  return showDialog<double>(
    context: context,
    builder: (_) => _WeightDialog(item: item, rate: ratePerKg, initial: current ?? 0.25),
  );
}

class _WeightDialog extends StatefulWidget {
  const _WeightDialog({required this.item, required this.rate, required this.initial});
  final Item item;
  final double rate;
  final double initial;

  @override
  State<_WeightDialog> createState() => _WeightDialogState();
}

class _WeightDialogState extends State<_WeightDialog> {
  late final _grams = TextEditingController(text: (widget.initial * 1000).round().toString());

  double get _kg => (double.tryParse(_grams.text) ?? 0) / 1000;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item.name),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${money(widget.rate).replaceAll('.00', '')} per kg', style: const TextStyle(color: Kc.muted)),
          const SizedBox(height: 12),
          TextField(
            controller: _grams,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(labelText: 'Weight in grams', suffixText: 'g'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(children: [
            for (final g in [100, 250, 500, 1000]) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _grams.text = '$g'),
                  child: Text(g < 1000 ? '$g g' : '1 kg'),
                ),
              ),
              if (g != 1000) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 12),
          Text('Amount: ${money(r2(widget.rate * _kg))}',
              textAlign: TextAlign.right, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Kc.navy)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, 0.0), child: const Text('Remove')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _kg <= 0 ? null : () => Navigator.pop(context, _kg),
          style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
          child: const Text('Add to bill'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- customer

Future<Customer?> pickCustomer(BuildContext context) =>
    showDialog<Customer>(context: context, builder: (_) => const _CustomerDialog());

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog();

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final cat = s.catalog!;
    final q = _q.trim().toLowerCase();
    final list = cat.customers.values
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || (c.phone ?? '').contains(q))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return AlertDialog(
      title: const Text('Choose customer'),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Name or mobile', prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final c = list[i];
                final type = cat.customerCategories[c.categoryId]?['name'] ?? '';
                final out = cat.outstanding[c.id] ?? 0;
                return ListTile(
                  title: Text(c.name),
                  subtitle: Text('$type${c.phone == null ? '' : ' · ${c.phone}'}'),
                  trailing: out == 0 ? null : Text('Due ${money(out, paise: false)}'),
                  onTap: () => Navigator.pop(context, c),
                );
              },
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        OutlinedButton.icon(
          icon: const Icon(Icons.person_add),
          label: const Text('New customer'),
          onPressed: () async {
            final c = await showDialog<Customer>(context: context, builder: (_) => _NewCustomerDialog(name: _q));
            if (c != null && context.mounted) Navigator.pop(context, c);
          },
        ),
      ],
    );
  }
}

class _NewCustomerDialog extends StatefulWidget {
  const _NewCustomerDialog({required this.name});
  final String name;

  @override
  State<_NewCustomerDialog> createState() => _NewCustomerDialogState();
}

class _NewCustomerDialogState extends State<_NewCustomerDialog> {
  late final _name = TextEditingController(text: widget.name);
  final _phone = TextEditingController();
  String? _categoryId;

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final cats = s.catalog!.customerCategories.values.toList();
    _categoryId ??= cats.where((c) => c['code'] == 'CONSUMER').firstOrNull?['id'] as String? ??
        (cats.isEmpty ? null : cats.first['id'] as String);
    return AlertDialog(
      title: const Text('New customer'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 10),
          TextField(
              controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final c in cats) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
          onPressed: () async {
            if (_name.text.trim().isEmpty || _categoryId == null) return;
            final c = await s.addCustomer(_name.text, _phone.text, _categoryId!);
            if (context.mounted) Navigator.pop(context, c);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- payment

/// Payment, then either the receipt or the approval wait.
Future<void> startPayment(BuildContext context) async {
  final result = await showDialog<Object>(context: context, builder: (_) => const _PaymentDialog());
  if (!context.mounted || result == null) return;
  if (result is PendingApproval) {
    final saved = await showDialog<SavedBill>(
        context: context, barrierDismissible: false, builder: (_) => _ApprovalDialog(pending: result));
    if (saved != null && context.mounted) await showReceipt(context, saved);
  } else if (result is SavedBill) {
    await showReceipt(context, result);
  }
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog();

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _mode = 'cash';
  bool _busy = false;
  CreditCheck? _check;

  Future<void> _pickMode(String m) async {
    setState(() => _mode = m);
    if (m == 'credit') {
      final s = context.read<PosState>();
      final c = await s.creditCheckFor(s.bill.totals(s.companyState).total);
      if (mounted) setState(() => _check = c);
    }
  }

  Future<void> _confirm() async {
    final s = context.read<PosState>();
    setState(() => _busy = true);
    try {
      final r = _mode == 'credit' ? await s.payOnCredit() : await s.payNow(_mode);
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final t = s.bill.totals(s.companyState);
    final modes = [
      ('cash', 'Cash'),
      ('upi', 'UPI'),
      ('card', 'Card'),
      if (s.bill.customer != null) ('credit', 'Credit'),
    ];
    final check = _check;
    final needsApproval = _mode == 'credit' && check != null && !check.allowed;
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text('Payment · ${s.bill.customer?.name ?? 'Walk-in'}')),
        Text(money(t.total, paise: false), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Kc.navy)),
      ]),
      content: SizedBox(
        width: 540,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            for (final m in modes) ...[
              Expanded(
                child: _mode == m.$1
                    ? FilledButton.tonal(onPressed: () => _pickMode(m.$1), child: Text(m.$2))
                    : OutlinedButton(onPressed: () => _pickMode(m.$1), child: Text(m.$2)),
              ),
              if (m != modes.last) const SizedBox(width: 8),
            ],
          ]),
          if (_mode == 'upi') ...[
            const SizedBox(height: 14),
            const Text('Customer pays to the outlet UPI. Confirm once the payment message arrives.',
                style: TextStyle(color: Kc.muted)),
          ],
          if (_mode == 'credit' && check != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: needsApproval ? Kc.amberBg : Kc.greenBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                needsApproval
                    ? 'Needs manager approval: ${check.explain()}.'
                    : 'Within limit. Outstanding after this bill: ${money(check.after, paise: false)}.',
                style: TextStyle(color: needsApproval ? Kc.amberInk : Kc.greenInk, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(220, 56)),
          onPressed: _busy || (_mode == 'credit' && check == null) ? null : _confirm,
          child: Text(needsApproval
              ? 'Send for approval'
              : _mode == 'credit'
                  ? 'Save on credit'
                  : 'Paid · save bill'),
        ),
      ],
    );
  }
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.pending});
  final PendingApproval pending;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _code = TextEditingController();
  String _status = 'pending';
  bool _busy = false;

  Future<void> _checkAgain() async {
    final s = context.read<PosState>();
    setState(() => _busy = true);
    final st = await s.approvalStatus(widget.pending);
    if (!mounted) return;
    setState(() {
      _status = st;
      _busy = false;
    });
    if (st == 'approved') {
      final saved = await s.finaliseApproved(widget.pending);
      if (mounted) Navigator.pop(context, saved);
    }
  }

  Future<void> _applyCode() async {
    final s = context.read<PosState>();
    if (!s.checkOfflineCode(widget.pending, _code.text)) {
      showError(context, 'That code does not match this bill');
      return;
    }
    final saved = await s.finaliseApproved(widget.pending, offlineCode: _code.text.trim());
    if (mounted) Navigator.pop(context, saved);
  }

  Future<void> _giveUp({required bool pay}) async {
    final s = context.read<PosState>();
    await s.cancelPending(widget.pending,
        reason: pay ? 'Paid instead of credit' : 'Credit not approved', takePaymentInstead: pay);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final p = widget.pending;
    return AlertDialog(
      title: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: _status == 'rejected' ? const Color(0xFFFBE4E4) : Kc.amberBg, borderRadius: BorderRadius.circular(999)),
          child: Text(_status == 'rejected' ? 'Rejected' : 'Pending approval',
              style: TextStyle(
                  color: _status == 'rejected' ? Kc.red : Kc.amberInk, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 10),
        const Text('Credit limit exceeded'),
      ]),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${p.bill.customer?.name} · bill ${money(p.amount, paise: false)}. ${p.check.explain()}.',
              style: const TextStyle(fontSize: 15, height: 1.5)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Kc.ground, borderRadius: BorderRadius.circular(12)),
            child: Text(
              'The request has gone to managers in the KwikERP app. No internet? Read this out to the manager on the phone:\n'
              '${s.device!.locationCode}-${s.device!.code} · code ${p.requestCode} · amount ${money(p.amount, paise: false)}',
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: '6-digit approval code', counterText: ''),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(140, 56)),
                onPressed: _applyCode,
                child: const Text('Apply code')),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => _giveUp(pay: false), child: const Text('Cancel bill')),
        OutlinedButton(onPressed: () => _giveUp(pay: true), child: const Text('Take cash / UPI instead')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(180, 52)),
          onPressed: _busy ? null : _checkAgain,
          child: Text(_busy ? 'Checking…' : 'Check for approval'),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- receipt

/// Receipt text as it will print on a 3-inch (48 column) thermal printer.
String receiptText(PosState s, SavedBill b) {
  const w = 48;
  String line([String c = '-']) => c * w;
  String lr(String l, String r) {
    final space = w - l.length - r.length;
    return space > 0 ? '$l${' ' * space}$r' : '${l.substring(0, (w - r.length - 1).clamp(0, l.length))} $r';
  }

  final co = s.catalog!.companies[s.device!.companyId];
  final out = StringBuffer()
    ..writeln((co?['legal_name'] ?? '').toString())
    ..writeln(s.device!.locationName)
    ..writeln(co?['gstin'] == null ? '' : 'GSTIN ${co!['gstin']}')
    ..writeln(line())
    ..writeln(lr('Bill ${b.docNo}', (b.invoice['doc_date'] ?? '').toString()))
    ..writeln(b.customerName)
    ..writeln(line());
  for (final l in b.lines) {
    out.writeln(l.item.name);
    out.writeln(lr('  ${qtyText(l.qty, l.item.soldByWeight)} x ${money(l.rate)}', money(l.amount)));
  }
  out
    ..writeln(line())
    ..writeln(lr('Taxable', money(b.totals.taxable)))
    ..writeln(lr('GST', money(b.totals.gst)))
    ..writeln(lr('Round off', money(b.totals.roundOff)))
    ..writeln(lr('TOTAL', money(b.totals.total, paise: false)))
    ..writeln(b.payLabel)
    ..writeln(line())
    ..writeln((co?['invoice_footer'] ?? 'Thank you!').toString());
  return out.toString();
}

Future<void> showReceipt(BuildContext context, SavedBill b) {
  final s = context.read<PosState>();
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('Bill ${b.docNo} saved'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFFFAFAF7),
            child: Text(receiptText(s, b), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
      ),
      actions: [
        const Text('Thermal printing is connected in the next update.  ', style: TextStyle(color: Kc.muted)),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(160, 52)),
          onPressed: () => Navigator.pop(context),
          child: const Text('New bill'),
        ),
      ],
    ),
  );
}
