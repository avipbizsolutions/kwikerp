import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/pos_state.dart';
import 'theme.dart';

/// Shown until the first download of items and prices has finished.
class FirstSyncScreen extends StatelessWidget {
  const FirstSyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final sync = s.sync!;
    return Scaffold(
      body: Center(
        child: ListenableBuilder(
          listenable: sync,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 48, height: 48, child: CircularProgressIndicator()),
              const SizedBox(height: 20),
              const Text('Downloading items and prices…', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              if (sync.lastError != null) ...[
                const SizedBox(height: 12),
                Text('No connection: ${sync.lastError}', style: const TextStyle(color: Kc.red)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: sync.syncNow, child: const Text('Try again')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class OpenShiftScreen extends StatefulWidget {
  const OpenShiftScreen({super.key});

  @override
  State<OpenShiftScreen> createState() => _OpenShiftScreenState();
}

class _OpenShiftScreenState extends State<OpenShiftScreen> {
  final _cash = TextEditingController(text: '0');

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    return Scaffold(
      body: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Open shift · ${s.device!.locationName}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Cashier: ${s.user!['name']}', style: const TextStyle(color: Kc.muted)),
              const SizedBox(height: 20),
              TextField(
                controller: _cash,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                decoration: const InputDecoration(labelText: 'Cash in drawer now (₹)'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => s.openShift(double.tryParse(_cash.text.replaceAll(',', '')) ?? 0),
                child: const Text('Start billing'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: s.logout, child: const Text('Log out')),
            ],
          ),
        ),
      ),
    );
  }
}

class CloseShiftScreen extends StatefulWidget {
  const CloseShiftScreen({super.key});

  @override
  State<CloseShiftScreen> createState() => _CloseShiftScreenState();
}

class _CloseShiftScreenState extends State<CloseShiftScreen> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  Map<String, double>? _sum;

  @override
  void initState() {
    super.initState();
    context.read<PosState>().shiftSummary().then((v) => setState(() => _sum = v));
  }

  Widget _row(String label, double v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w700 : null))),
          Text(money(v), style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final sum = _sum;
    final counted = double.tryParse(_counted.text.replaceAll(',', ''));
    final diff = (sum == null || counted == null) ? null : r2(counted - sum['expected_cash']!);
    return Scaffold(
      appBar: AppBar(title: const Text('Close shift'), backgroundColor: Kc.navy, foregroundColor: Colors.white),
      body: sum == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Sales this shift', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(money(sum['sales']!, paise: false),
                            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: Kc.navy)),
                        Text('${sum['bills']!.toInt()} bills', style: const TextStyle(color: Kc.muted)),
                        const Divider(height: 28),
                        _row('Cash', sum['cash']!),
                        _row('UPI', sum['upi']!),
                        _row('Card', sum['card']!),
                        _row('Credit', sum['credit']!),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('Cash in drawer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        _row('Opening cash', sum['opening']!),
                        _row('Cash sales', sum['cash']!),
                        _row('Expected in drawer', sum['expected_cash']!, bold: true),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _counted,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                          decoration: const InputDecoration(labelText: 'Cash counted (₹)'),
                          onChanged: (_) => setState(() {}),
                        ),
                        if (diff != null && diff != 0) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: Kc.amberBg, borderRadius: BorderRadius.circular(10)),
                            child: Text('${diff < 0 ? 'Short' : 'Excess'} by ${money(diff.abs())} · reason needed',
                                style: const TextStyle(color: Kc.amberInk, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _note,
                            decoration: const InputDecoration(labelText: 'Reason'),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: counted == null || (diff != 0 && _note.text.trim().isEmpty)
                              ? null
                              : () async {
                                  await s.closeShift(counted, _note.text);
                                  if (context.mounted) Navigator.of(context).pop();
                                },
                          child: const Text('Close shift'),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
    );
  }
}
