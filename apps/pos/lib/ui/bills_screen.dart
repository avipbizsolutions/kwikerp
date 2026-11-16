import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/pos_state.dart';
import '../core/printer.dart';
import 'dialogs.dart';
import 'theme.dart';

/// Bills made on this tablet: find, reprint, cancel.
class BillsScreen extends StatefulWidget {
  const BillsScreen({super.key});

  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  String _range = 'today';
  String _q = '';
  List<Map<String, dynamic>>? _bills;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await context.read<PosState>().billHistory();
    if (mounted) setState(() => _bills = all);
  }

  String _day(int back) => DateTime.now().subtract(Duration(days: back)).toIso8601String().substring(0, 10);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final today = _day(0), yesterday = _day(1), weekAgo = _day(6);
    final q = _q.trim().toLowerCase();
    final list = (_bills ?? []).where((b) {
      final d = (b['doc_date'] ?? '') as String;
      final inRange = switch (_range) {
        'today' => d == today,
        'yesterday' => d == yesterday,
        'week' => d.compareTo(weekAgo) >= 0,
        _ => true,
      };
      if (!inRange) return false;
      if (q.isEmpty) return true;
      final name = b['customer_id'] == null ? 'walk-in' : (cat.customers[b['customer_id']]?.name ?? '').toLowerCase();
      return ((b['doc_no'] ?? '') as String).toLowerCase().contains(q) || name.contains(q);
    }).toList();
    final total = list.where((b) => b['status'] == 'final').fold<double>(0, (a, b) => a + (b['total'] as num).toDouble());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bills'),
        backgroundColor: Kc.navy,
        foregroundColor: Colors.white,
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
                hintText: 'Bill number (last digits) or customer', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.zero),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(spacing: 8, children: [
            for (final r in const [('today', 'Today'), ('yesterday', 'Yesterday'), ('week', 'Last 7 days'), ('all', 'All')])
              ChoiceChip(
                label: Text(r.$2),
                selected: _range == r.$1,
                showCheckmark: false,
                onSelected: (_) => setState(() => _range = r.$1),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text('${list.length} bills · sales ${money(total, paise: false)} (cancelled bills not counted)',
              style: const TextStyle(color: Kc.muted)),
        ),
        Expanded(
          child: _bills == null
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const Center(child: Text('No bills', style: TextStyle(color: Kc.muted)))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) => _BillRow(bill: list[i], onChanged: _load),
                    ),
        ),
      ]),
    );
  }
}

class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill, required this.onChanged});
  final Map<String, dynamic> bill;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final status = bill['status'] as String;
    final cust = bill['customer_id'] == null ? 'Walk-in' : (s.catalog!.customers[bill['customer_id']]?.name ?? 'Customer');
    final time = DateTime.tryParse((bill['finalised_at'] ?? '') as String)?.toLocal();
    final (label, bg, fg) = switch (status) {
      'final' => ((bill['balance'] as num) > 0 ? 'Credit' : 'Paid', Kc.greenBg, Kc.greenInk),
      'cancelled' => ('Cancelled', const Color(0xFFFBE9E9), Kc.red),
      'pending_approval' => ('Waiting approval', Kc.amberBg, Kc.amberInk),
      _ => (status, Kc.ground, Kc.muted),
    };
    return ListTile(
      onTap: status == 'final' || status == 'cancelled' ? () => _open(context) : null,
      title: Text('${bill['doc_no'] ?? 'No number yet'} · $cust',
          style: TextStyle(
              fontWeight: FontWeight.w600, decoration: status == 'cancelled' ? TextDecoration.lineThrough : null)),
      subtitle: Text('${bill['doc_date']}${time == null ? '' : ' ${TimeOfDay.fromDateTime(time).format(context)}'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
          child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Text(money((bill['total'] as num).toDouble(), paise: false),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Kc.navy)),
      ]),
    );
  }

  Future<void> _open(BuildContext context) async {
    final s = context.read<PosState>();
    final p = context.read<PrinterService>();
    final saved = await s.savedBillFrom(bill);
    if (!context.mounted) return;
    final cancelled = bill['status'] == 'cancelled';
    String? status;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Bill ${saved.docNo ?? ''}${cancelled ? ' · CANCELLED' : ''}'),
          content: SizedBox(
            width: 460,
            height: 440,
            child: SingleChildScrollView(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: cancelled ? const Color(0xFFFBE9E9) : const Color(0xFFFAFAF7),
                child: Text(receiptText(s, saved), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ),
          actions: [
            if (status != null) Text('$status  ', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (!cancelled)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Kc.red),
                onPressed: () async {
                  final done = await _askCancel(dialogContext, saved.docNo ?? '');
                  if (done && dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                    onChanged();
                  }
                },
                child: const Text('Cancel bill'),
              ),
            if (!cancelled)
              OutlinedButton(
                onPressed: () async {
                  if (!p.configured) {
                    await showPrinterSetup(dialogContext);
                    if (!p.configured) return;
                  }
                  setState(() => status = 'Printing KOT…');
                  final kot = await s.kotFor(saved.invoice['id'] as String, saved.lines,
                      docNo: saved.docNo, customer: saved.customerName, width: p.columns, reprint: true);
                  final r = await p.print(kot, remember: false);
                  setState(() => status = r ?? 'KOT printed');
                },
                child: const Text('KOT'),
              ),
            if (!cancelled)
              OutlinedButton.icon(
                icon: const Icon(Icons.print),
                label: const Text('Reprint'),
                onPressed: () async {
                  if (!p.configured) {
                    await showPrinterSetup(dialogContext);
                    if (!p.configured) return;
                  }
                  setState(() => status = 'Printing…');
                  final r = await p.print(receiptText(s, saved, width: p.columns, forPrint: true, duplicate: true),
                      remember: false);
                  setState(() => status = r ?? 'Printed');
                },
              ),
            FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  /// Returns true once the bill is cancelled.
  Future<bool> _askCancel(BuildContext context, String docNo) async {
    final s = context.read<PosState>();
    final reason = TextEditingController();
    final phone = TextEditingController();
    final pin = TextEditingController();
    final needsManager = !s.canCancelBills;
    String? error;
    var busy = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Cancel bill $docNo?'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('The bill keeps its number and shows as cancelled. Its payment is taken off the shift '
                  'and the stock goes back. Needs internet.', style: TextStyle(color: Kc.muted)),
              const SizedBox(height: 12),
              TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason *')),
              if (needsManager) ...[
                const SizedBox(height: 12),
                const Text('Manager approval', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: "Manager's mobile")),
                const SizedBox(height: 8),
                TextField(
                    controller: pin,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: "Manager's PIN", counterText: '')),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(color: Kc.red, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Keep bill')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Kc.red),
              onPressed: busy
                  ? null
                  : () async {
                      if (reason.text.trim().length < 3) {
                        setState(() => error = 'Write a reason');
                        return;
                      }
                      if (needsManager && (phone.text.trim().isEmpty || pin.text.trim().isEmpty)) {
                        setState(() => error = "Manager's mobile and PIN are needed");
                        return;
                      }
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await s.cancelBill(bill, reason.text,
                            approverPhone: needsManager ? phone.text : null, approverPin: needsManager ? pin.text : null);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        final msg = e.toString();
                        setState(() {
                          busy = false;
                          error = msg.contains('SocketException') || msg.contains('TimeoutException') || msg.contains('ClientException')
                              ? 'No internet. Try again when the tablet is online.'
                              : msg;
                        });
                      }
                    },
              child: Text(busy ? 'Cancelling…' : 'Cancel bill'),
            ),
          ],
        ),
      ),
    );
    return ok ?? false;
  }
}
