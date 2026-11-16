import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/catalog.dart';
import '../core/escpos.dart';
import '../core/pos_state.dart';
import '../core/printer.dart';
import '../core/receipt.dart';
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
Future<void> startPayment(BuildContext context, {String mode = 'cash'}) async {
  final result = await showDialog<Object>(context: context, builder: (_) => _PaymentDialog(initialMode: mode));
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
  const _PaymentDialog({this.initialMode = 'cash'});
  final String initialMode;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _mode = 'cash';
  bool _busy = false;
  CreditCheck? _check;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    if (_mode == 'credit') WidgetsBinding.instance.addPostFrameCallback((_) => _pickMode('credit'));
  }

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

/// Receipt text, laid out as head office set it (see core/receipt.dart).
String receiptText(PosState s, SavedBill b, {int width = 48, bool forPrint = false, bool duplicate = false}) =>
    buildReceipt(s, b, width: width, forPrint: forPrint, duplicate: duplicate);

Future<void> showReceipt(BuildContext context, SavedBill b) async {
  final s = context.read<PosState>();
  final p = context.read<PrinterService>();
  String printable({bool duplicate = false}) => receiptText(s, b, width: p.columns, forPrint: true, duplicate: duplicate);
  // Remembered for "Reprint last bill" even when no printer is set up yet.
  p.lastReceipt = receiptText(s, b, width: p.columns, forPrint: true, duplicate: true);
  String? status;
  if (p.configured && p.autoPrint) {
    status = await p.print(printable(), remember: false);
    status ??= 'Printed';
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
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
          if (status != null)
            Text('$status  ',
                style: TextStyle(color: status == 'Printed' ? Kc.greenInk : Kc.red, fontWeight: FontWeight.w600)),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(130, 52)),
            icon: const Icon(Icons.print),
            label: Text(status == null ? 'Print' : 'Print again'),
            onPressed: () async {
              if (!p.configured) {
                await showPrinterSetup(dialogContext);
                if (!p.configured) return;
              }
              final again = status == 'Printed';
              setState(() => status = 'Printing…');
              final r = await p.print(printable(duplicate: again), remember: false);
              setState(() => status = r ?? 'Printed');
            },
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 52)),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('New bill'),
          ),
        ],
      ),
    ),
  );
}

// ----------------------------------------------------------------- printer

/// Choose the paired Bluetooth printer and paper width.
Future<void> showPrinterSetup(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _PrinterDialog());

class _PrinterDialog extends StatefulWidget {
  const _PrinterDialog();

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  List<PairedPrinter>? _list;
  String? _error;
  String? _mac;
  String? _name;
  late int _cols;
  late bool _auto;
  String? _test;

  @override
  void initState() {
    super.initState();
    final p = context.read<PrinterService>();
    _mac = p.mac;
    _name = p.name;
    _cols = p.columns;
    _auto = p.autoPrint;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _list = null;
    });
    try {
      final l = await context.read<PrinterService>().paired();
      if (mounted) setState(() => _list = l);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save() => context.read<PrinterService>().save(mac: _mac, name: _name, columns: _cols, autoPrint: _auto);

  Future<void> _testPrint() async {
    await _save();
    if (!mounted) return;
    final p = context.read<PrinterService>();
    setState(() => _test = 'Printing…');
    final ruler = List.generate(_cols, (i) => '${(i + 1) % 10}').join();
    final r = await p.print(
        '^C^WKwikERP test print\n^C${_name ?? ''}\n$ruler\nThe line of digits above should fit on one line.\n',
        remember: false);
    if (mounted) setState(() => _test = r ?? 'Test page sent');
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return AlertDialog(
      title: const Text('Receipt printer'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Pair the printer first in Android Settings > Bluetooth (PIN is usually 0000 or 1234), '
              'then pick it here.', style: TextStyle(color: Kc.muted)),
          const SizedBox(height: 12),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Kc.red)),
            const SizedBox(height: 8),
          ],
          if (list == null && _error == null) const Center(child: CircularProgressIndicator()),
          if (list != null && list.isEmpty) const Text('No paired Bluetooth devices found.'),
          if (list != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(shrinkWrap: true, children: [
                for (final d in list)
                  ListTile(
                    leading: Icon(d.mac == _mac ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: d.mac == _mac ? Kc.navy : Kc.muted),
                    title: Text(d.name.isEmpty ? '(no name)' : d.name),
                    subtitle: Text(d.mac),
                    onTap: () => setState(() {
                      _mac = d.mac;
                      _name = d.name;
                    }),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Paper  '),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 32, label: Text('58 mm (2 inch)')),
                ButtonSegment(value: 48, label: Text('80 mm (3 inch)')),
              ],
              selected: {_cols},
              onSelectionChanged: (v) => setState(() => _cols = v.first),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Print every bill automatically'),
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
          ),
          if (_test != null) Text(_test!, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
      actions: [
        TextButton(onPressed: _load, child: const Text('Refresh list')),
        OutlinedButton(onPressed: _mac == null ? null : _testPrint, child: const Text('Test print')),
        FilledButton(
          onPressed: _mac == null
              ? null
              : () async {
                  await _save();
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
