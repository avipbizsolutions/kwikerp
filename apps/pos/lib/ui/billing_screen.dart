import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/catalog.dart';
import '../core/pos_state.dart';
import 'dialogs.dart';
import 'shift_screens.dart';
import 'theme.dart';

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  String? _categoryId;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final usedCategories = cat.categories.where((c) => cat.items.values.any((i) => i.onPos && i.categoryId == c.id)).toList();
    _categoryId ??= usedCategories.isEmpty ? null : usedCategories.first.id;

    final q = _search.trim().toLowerCase();
    final items = cat.items.values
        .where((i) => i.onPos && (q.isNotEmpty ? i.name.toLowerCase().contains(q) || i.code == q : i.categoryId == _categoryId))
        .toList()
      ..sort((a, b) => a.posSort.compareTo(b.posSort));

    return Scaffold(
      body: Column(children: [
        _TopBar(),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextField(
                    decoration: const InputDecoration(hintText: 'Search item or type item code', prefixIcon: Icon(Icons.search)),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final c in usedCategories)
                      ChoiceChip(
                        label: Text(c.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        selected: q.isEmpty && c.id == _categoryId,
                        onSelected: (_) => setState(() => _categoryId = c.id),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220, mainAxisExtent: 118, crossAxisSpacing: 12, mainAxisSpacing: 12),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _ItemTile(item: items[i]),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 420, child: _CartPanel()),
          ]),
        ),
      ]),
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    return Container(
      height: 56,
      color: Kc.navy,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        const Text('KwikERP', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(width: 16),
        Expanded(
          child: Text('${s.device!.locationName} · Tablet ${s.device!.code} · ${s.user!['name']}',
              style: const TextStyle(color: Color(0xFFC9D6E6), fontSize: 14), overflow: TextOverflow.ellipsis),
        ),
        ListenableBuilder(
          listenable: s.sync!,
          builder: (context, _) {
            final sync = s.sync!;
            final ok = sync.online && sync.pending == 0;
            final text = sync.online
                ? (sync.pending == 0 ? 'Online · all synced' : 'Online · ${sync.pending} to sync')
                : 'Offline · ${sync.pending} waiting to sync';
            return InkWell(
              onTap: sync.syncNow,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: ok ? Kc.greenBg : Kc.amberBg, borderRadius: BorderRadius.circular(999)),
                child: Text(text,
                    style: TextStyle(color: ok ? Kc.greenInk : Kc.amberInk, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onSelected: (v) {
            if (v == 'close') {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloseShiftScreen()));
            } else if (v == 'logout') {
              s.logout();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'close', child: Text('Close shift')),
            PopupMenuItem(value: 'logout', child: Text('Log out')),
          ],
        ),
      ]),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final Item item;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final price = cat.price(item.id, item.baseUnitId, s.bill.levelId);
    final line = s.bill.lineFor(item.id, item.baseUnitId);
    final colour = Kc.hex(cat.categories.where((c) => c.id == item.categoryId).firstOrNull?.colour);
    return Material(
      color: colour,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: line != null ? Kc.blue : const Color(0x14000000), width: line != null ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: price == null
            ? null
            : () async {
                try {
                  if (item.soldByWeight) {
                    final kg = await askWeight(context, item, price, line?.qty);
                    if (kg != null) s.addItem(item, kg, replace: true);
                  } else {
                    s.addItem(item, 1);
                  }
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.2)),
            Text(item.soldByWeight ? 'By weight' : cat.unitCode(item.baseUnitId).toLowerCase(),
                style: const TextStyle(fontSize: 13, color: Kc.muted)),
            const Spacer(),
            Row(children: [
              Expanded(
                child: Text(
                    price == null ? 'No price' : '${money(price).replaceAll('.00', '')}${item.soldByWeight ? '/kg' : ''}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: price == null ? Kc.red : Kc.navy)),
              ),
              if (line != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                  decoration: BoxDecoration(color: Kc.blue, borderRadius: BorderRadius.circular(999)),
                  child: Text(qtyText(line.qty, item.soldByWeight),
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _CartPanel extends StatelessWidget {
  const _CartPanel();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final bill = s.bill;
    final t = bill.totals(s.companyState);
    final cust = bill.customer;
    final rule = cust == null ? null : cat.creditRule(cust);
    final out = cust == null ? 0.0 : (cat.outstanding[cust.id] ?? 0);

    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: Color(0xFFD5DCE3)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text(cust?.name ?? 'Walk-in customer',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: Kc.blueTint, borderRadius: BorderRadius.circular(6)),
                child: Text('${cat.levelName(bill.levelId)} rates',
                    style: const TextStyle(color: Kc.navy, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.person_search),
                  label: const Text('Customer'),
                  onPressed: () async {
                    final c = await pickCustomer(context);
                    if (c != null) s.setCustomer(c);
                  },
                ),
              ),
              if (cust != null) ...[
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => s.setCustomer(null), child: const Text('Walk-in')),
              ],
            ]),
            if (cust != null && rule != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: Kc.ground, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  'Outstanding ${money(out, paise: false)} · '
                  '${rule.maxOutstanding == null ? 'no amount limit' : 'limit ${money(rule.maxOutstanding!, paise: false)}'}'
                  ' (${rule.source == 'customer' ? 'own limit' : rule.source == 'category' ? 'category limit' : 'no limit set'})',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF33414F)),
                ),
              ),
            ],
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: bill.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Tap items to start a bill', style: TextStyle(color: Kc.muted, fontSize: 15)),
                    if (s.held.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      for (final h in s.held)
                        TextButton(
                          onPressed: () => s.resumeBill(h),
                          child: Text('Resume held bill · ${h.customer?.name ?? 'Walk-in'} · ${h.lines.length} items'),
                        ),
                    ],
                  ]),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: bill.lines.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _CartLine(line: bill.lines[i]),
                ),
        ),
        Container(
          color: const Color(0xFFF8FAFB),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _sumRow('Items ${bill.lines.length} · Taxable', money(t.taxable)),
            _sumRow(t.igst > 0 ? 'IGST' : 'CGST + SGST', money(t.gst)),
            _sumRow('Round off', '${t.roundOff >= 0 ? '+' : ''}${money(t.roundOff)}'),
            const SizedBox(height: 4),
            Row(children: [
              const Expanded(child: Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
              Text(money(t.total, paise: false),
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Kc.navy)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(
                width: 110,
                child: OutlinedButton(onPressed: bill.isEmpty ? null : s.holdBill, child: const Text('Hold')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: bill.isEmpty ? null : () => startPayment(context),
                  child: Text('Pay ${money(t.total, paise: false)}'),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _sumRow(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(a, style: const TextStyle(color: Kc.muted, fontSize: 14))),
          Text(b, style: const TextStyle(color: Kc.muted, fontSize: 14)),
        ]),
      );
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.line});
  final BillLine line;

  @override
  Widget build(BuildContext context) {
    final s = context.read<PosState>();
    final byWeight = line.item.soldByWeight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line.item.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
                '${money(line.rate)}${byWeight ? ' per kg' : ' each'} · '
                '${line.item.gstRate == 0 ? 'GST nil' : 'GST ${line.item.gstRate.toStringAsFixed(0)}%'}',
                style: const TextStyle(fontSize: 13, color: Kc.muted)),
          ]),
        ),
        if (byWeight)
          OutlinedButton(
            onPressed: () async {
              final kg = await askWeight(context, line.item, line.listRate, line.qty);
              if (kg != null) s.addItem(line.item, kg, replace: true);
            },
            child: Text(qtyText(line.qty, true)),
          )
        else
          Row(children: [
            _qtyButton('−', () => s.addItem(line.item, -1)),
            SizedBox(
                width: 36,
                child: Text(qtyText(line.qty, false),
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            _qtyButton('+', () => s.addItem(line.item, 1)),
          ]),
        SizedBox(
          width: 88,
          child: Text(money(line.amount),
              textAlign: TextAlign.right, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  Widget _qtyButton(String label, VoidCallback onTap) => SizedBox(
        width: 44,
        height: 44,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(44, 44)),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 20)),
        ),
      );
}
