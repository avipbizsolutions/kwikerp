import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/billing.dart';
import '../core/catalog.dart';
import '../core/pos_state.dart';
import '../core/printer.dart';
import 'bills_screen.dart';
import 'rates_screen.dart';
import 'types_screen.dart';
import 'dialogs.dart';
import 'shift_screens.dart';
import 'theme.dart';

/// Billing screen, laid out for a tablet standing upright at the counter
/// (also works sideways): categories down the left, items in a grid that
/// doubles as the cart, and the total with Save fixed at the bottom.
const _bestSellers = '__best__';

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  String? _categoryId;
  String _search = '';
  final _searchCtl = TextEditingController();
  String _mode = 'cash';
  bool _saving = false;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.read<PosState>();
    if (s.bill.isEmpty || _saving) return;
    if (_mode == 'credit') {
      await startPayment(context, mode: 'credit');
      if (mounted) setState(() => _mode = 'cash');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await s.payNow(_mode);
      if (mounted) {
        setState(() => _mode = 'cash');
        await showReceipt(context, saved);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final best = s.bestSellers;
    final categories = cat.categories.where((c) => cat.items.values.any((i) => i.onPos && i.categoryId == c.id)).toList();
    _categoryId ??= best.isNotEmpty ? _bestSellers : (categories.isEmpty ? null : categories.first.id);
    if (_categoryId == _bestSellers && best.isEmpty) _categoryId = categories.isEmpty ? null : categories.first.id;
    if (_mode == 'credit' && s.bill.customer == null) _mode = 'cash';

    final q = _search.trim().toLowerCase();
    List<Item> items;
    if (q.isNotEmpty) {
      items = cat.items.values.where((i) => i.onPos && (i.name.toLowerCase().contains(q) || i.code == q)).toList()
        ..sort((a, b) => a.posSort.compareTo(b.posSort));
    } else if (_categoryId == _bestSellers) {
      items = [for (final id in best) cat.items[id]!];
    } else {
      items = cat.items.values.where((i) => i.onPos && i.categoryId == _categoryId).toList()
        ..sort((a, b) => a.posSort.compareTo(b.posSort));
    }

    // How many lines of the current bill fall in each category (shown on the rail).
    final inBill = <String?, int>{};
    for (final l in s.bill.lines) {
      inBill[l.item.categoryId] = (inBill[l.item.categoryId] ?? 0) + 1;
    }
    final bestInBill = s.bill.lines.where((l) => best.contains(l.item.id)).length;

    return Scaffold(
      backgroundColor: Kc.ground,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _TopBar(),
          if (s.updateRequired)
            Container(
              color: const Color(0xFFD93025),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: const Text('Update required: finish this bill and any held bills, then the update screen opens.',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          const _CustomerStrip(),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // ---- category rail
              Container(
                width: 124,
                color: const Color(0xFFE3E8EE),
                child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                  if (best.isNotEmpty)
                    _RailButton(
                      label: 'Best sellers',
                      count: bestInBill,
                      selected: q.isEmpty && _categoryId == _bestSellers,
                      highlight: const Color(0xFFFFC94D),
                      onTap: () => setState(() {
                        _categoryId = _bestSellers;
                        _clearSearch();
                      }),
                    ),
                  for (final c in categories)
                    _RailButton(
                      label: c.name,
                      count: inBill[c.id] ?? 0,
                      selected: q.isEmpty && c.id == _categoryId,
                      onTap: () => setState(() {
                        _categoryId = c.id;
                        _clearSearch();
                      }),
                    ),
                ]),
              ),
              // ---- search + item grid
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                    child: SizedBox(
                      height: 42,
                      child: TextField(
                        controller: _searchCtl,
                        decoration: InputDecoration(
                          hintText: 'Search item or code',
                          prefixIcon: const Icon(Icons.search),
                          contentPadding: EdgeInsets.zero,
                          suffixIcon: q.isEmpty
                              ? null
                              : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_clearSearch)),
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                    ),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? const Center(child: Text('No items', style: TextStyle(color: Kc.muted)))
                        : LayoutBuilder(
                            // At least 4 tiles a row on a 7-8 inch tablet held upright.
                            builder: (context, box) => GridView.builder(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: (box.maxWidth / 112).floor().clamp(3, 8),
                                  mainAxisExtent: 100,
                                  crossAxisSpacing: 6,
                                  mainAxisSpacing: 6),
                              itemCount: items.length,
                              itemBuilder: (context, i) => _ItemTile(item: items[i]),
                            ),
                          ),
                  ),
                ]),
              ),
            ]),
          ),
          const _BillLine(),
          _BottomBar(
            mode: _mode,
            saving: _saving,
            onMode: (m) => setState(() => _mode = m),
            onSave: _save,
          ),
        ]),
      ),
    );
  }

  void _clearSearch() {
    _search = '';
    _searchCtl.clear();
  }
}

// ------------------------------------------------------------------ top bar

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    return Container(
      height: 52,
      color: Kc.navy,
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(s.device!.locationName,
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis),
            Text('Tablet ${s.device!.code} · ${s.user!['name']}',
                style: const TextStyle(color: Color(0xFFC9D6E6), fontSize: 12), overflow: TextOverflow.ellipsis),
          ]),
        ),
        ListenableBuilder(
          listenable: s.sync!,
          builder: (context, _) {
            final sync = s.sync!;
            final ok = sync.online && sync.pending == 0;
            final text = sync.online
                ? (sync.pending == 0 ? 'All synced' : '${sync.pending} to sync')
                : 'Offline · ${sync.pending} waiting';
            return InkWell(
              onTap: sync.syncNow,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: ok ? Kc.greenBg : Kc.amberBg, borderRadius: BorderRadius.circular(999)),
                child: Text(text,
                    style: TextStyle(color: ok ? Kc.greenInk : Kc.amberInk, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            );
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onSelected: (v) async {
            if (v == 'rates') {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RatesScreen()));
            } else if (v == 'types') {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CustomerTypesScreen()));
            } else if (v == 'bills') {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BillsScreen()));
            } else if (v == 'printer') {
              await showPrinterSetup(context);
            } else if (v == 'reprint') {
              final p = context.read<PrinterService>();
              final last = p.lastReceipt;
              final msg = last == null ? 'No bill printed since the app was opened.' : await p.print(last, remember: false);
              if (msg != null && context.mounted) showError(context, msg);
            } else if (v == 'close') {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloseShiftScreen()));
            } else if (v == 'logout') {
              s.logout();
            }
          },
          itemBuilder: (_) => [
            if (s.canManageRates) const PopupMenuItem(value: 'rates', child: Text('Rate chart')),
            if (s.canManageRates) const PopupMenuItem(value: 'types', child: Text('Customer types')),
            const PopupMenuItem(value: 'bills', child: Text('Bills · reprint or cancel')),
            const PopupMenuItem(value: 'printer', child: Text('Printer')),
            const PopupMenuItem(value: 'reprint', child: Text('Reprint last bill')),
            const PopupMenuItem(value: 'close', child: Text('Close shift')),
            const PopupMenuItem(value: 'logout', child: Text('Log out')),
          ],
        ),
      ]),
    );
  }
}

// ------------------------------------------------------- customer and hold

class _CustomerStrip extends StatelessWidget {
  const _CustomerStrip();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final bill = s.bill;
    final cust = bill.customer;
    final rule = cust == null ? null : cat.creditRule(cust);
    final out = cust == null ? 0.0 : (cat.outstanding[cust.id] ?? 0);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: () async {
              final c = await pickCustomer(context);
              if (c != null) s.setCustomer(c);
            },
            child: Row(children: [
              const Icon(Icons.person_outline, color: Kc.muted),
              const SizedBox(width: 6),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(cust?.name ?? 'Walk-in customer · tap to choose',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                  Text(
                    cust == null
                        ? '${cat.levelName(bill.levelId)} rates'
                        : '${cat.levelName(bill.levelId)} rates · due ${money(out, paise: false)}'
                            '${rule?.maxOutstanding == null ? '' : ' · limit ${money(rule!.maxOutstanding!, paise: false)}'}',
                    style: const TextStyle(fontSize: 12, color: Kc.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
            ]),
          ),
        ),
        if (cust != null)
          IconButton(tooltip: 'Back to walk-in', icon: const Icon(Icons.close), onPressed: () => s.setCustomer(null)),
        if (s.held.isNotEmpty)
          PopupMenuButton<Bill>(
            tooltip: 'Held bills',
            onSelected: s.resumeBill,
            itemBuilder: (_) => [
              for (final h in s.held)
                PopupMenuItem(
                  value: h,
                  child: Text('${h.customer?.name ?? 'Walk-in'} · ${h.lines.length} items · '
                      '${money(h.totals(s.companyState).total, paise: false)}'),
                ),
            ],
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: Kc.amberBg, borderRadius: BorderRadius.circular(8)),
              child: Text('Held (${s.held.length})',
                  style: const TextStyle(color: Kc.amberInk, fontWeight: FontWeight.w700)),
            ),
          ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(80, 40)),
          onPressed: bill.isEmpty ? null : s.holdBill,
          child: const Text('HOLD'),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------ category rail

class _RailButton extends StatelessWidget {
  const _RailButton({required this.label, required this.count, required this.selected, required this.onTap, this.highlight});
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? (highlight ?? Kc.navy) : (count > 0 ? Kc.greenBg : Colors.white);
    final fg = selected && highlight == null ? Colors.white : Kc.ink;
    return Padding(
      padding: const EdgeInsets.fromLTRB(5, 2, 5, 2),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(count > 0 ? '$label ($count)' : label,
                style: TextStyle(fontSize: 13, color: fg, fontWeight: count > 0 || selected ? FontWeight.w700 : FontWeight.w500)),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- item tile

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final Item item;

  Future<void> _tap(BuildContext context, PosState s, double price, BillLine? line) async {
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
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final cat = s.catalog!;
    final price = cat.price(item.id, item.baseUnitId, s.bill.levelId);
    final line = s.bill.lineFor(item.id, item.baseUnitId);
    final picked = line != null;
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(
        child: Material(
          color: picked ? const Color(0xFFB9EBC4) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: picked ? const Color(0xFF2E9E4F) : const Color(0x1A000000), width: picked ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: price == null ? null : () => _tap(context, s, price, line),
            onLongPress: price == null
                ? null
                : () async {
                    if (item.soldByWeight) return _tap(context, s, price, line);
                    final q = await _askQty(context, item, line?.qty);
                    if (q != null) s.addItem(item, q, replace: true);
                  },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(item.name,
                        textAlign: TextAlign.center,
                        maxLines: item.packSize.isEmpty ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.15)),
                    if (item.packSize.isNotEmpty)
                      Text(item.packSize, style: const TextStyle(fontSize: 12, color: Kc.muted, fontWeight: FontWeight.w600)),
                  ]),
                ),
                Row(children: [
                  _box(line != null ? qtyText(line.qty, item.soldByWeight) : '0', picked),
                  const Spacer(),
                  _box(
                    price == null ? 'No price' : '${_rate(price)}${item.soldByWeight ? '/kg' : ''}',
                    false,
                    colour: price == null ? Kc.red : Kc.ink,
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
      if (picked)
        Positioned(
          top: -4,
          right: -4,
          child: GestureDetector(
            // Takes one off; a weighed item is removed entirely.
            onTap: () => item.soldByWeight ? s.addItem(item, 0, replace: true) : s.addItem(item, -1),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: const Color(0xFFD93025), borderRadius: BorderRadius.circular(6)),
              child: const Icon(Icons.remove, color: Colors.white, size: 20),
            ),
          ),
        ),
    ]);
  }

  static String _rate(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Widget _box(String text, bool strong, {Color colour = Kc.ink}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: strong ? Colors.white : null,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: strong ? const Color(0xFF2E9E4F) : Kc.line),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: colour)),
      );
}

Future<double?> _askQty(BuildContext context, Item item, double? current) {
  final ctl = TextEditingController(text: current == null ? '' : qtyText(current, false));
  return showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(item.fullName),
      content: TextField(
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        decoration: const InputDecoration(labelText: 'Quantity'),
        onSubmitted: (v) => Navigator.pop(ctx, double.tryParse(v) ?? 0),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(ctl.text) ?? 0), child: const Text('OK')),
      ],
    ),
  );
}

// ------------------------------------------- bill summary line and details

class _BillLine extends StatelessWidget {
  const _BillLine();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final bill = s.bill;
    if (bill.isEmpty) return const SizedBox.shrink();
    final text = bill.lines.map((l) => '${l.item.fullName} ×${qtyText(l.qty, l.item.soldByWeight)}').join(' · ');
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _showBillDetails(context),
        child: Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Kc.line))),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 6),
            const Text('DETAILS', style: TextStyle(color: Kc.blue, fontWeight: FontWeight.w700, fontSize: 13)),
            const Icon(Icons.expand_less, color: Kc.blue),
          ]),
        ),
      ),
    );
  }
}

Future<void> _showBillDetails(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ChangeNotifierProvider.value(
        value: context.read<PosState>(),
        child: const _BillDetails(),
      ),
    );

class _BillDetails extends StatelessWidget {
  const _BillDetails();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final bill = s.bill;
    if (bill.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox(height: 80);
    }
    final t = bill.totals(s.companyState);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('${bill.customer?.name ?? 'Walk-in customer'} · ${bill.lines.length} items',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, color: Kc.red),
              label: const Text('Clear bill', style: TextStyle(color: Kc.red)),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Clear this bill?'),
                    content: const Text('All items in the current bill will be removed.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
                    ],
                  ),
                );
                if (ok == true) s.clearBill();
              },
            ),
          ]),
          const Divider(),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: bill.lines.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _CartLine(line: bill.lines[i]),
            ),
          ),
          const Divider(),
          _sumRow('Taxable', money(t.taxable)),
          _sumRow(t.igst > 0 ? 'IGST' : 'CGST + SGST', money(t.gst)),
          _sumRow('Round off', '${t.roundOff >= 0 ? '+' : ''}${money(t.roundOff)}'),
          Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
            Text(money(t.total, paise: false),
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Kc.navy)),
          ]),
        ]),
      ),
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
            Text(line.item.fullName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
                width: 40,
                child: Text(qtyText(line.qty, false),
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            _qtyButton('+', () => s.addItem(line.item, 1)),
          ]),
        SizedBox(
          width: 92,
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

// --------------------------------------------------------------- bottom bar

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.mode, required this.saving, required this.onMode, required this.onSave});
  final String mode;
  final bool saving;
  final ValueChanged<String> onMode;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final t = s.bill.totals(s.companyState);
    final modes = [
      ('cash', 'Cash'),
      ('upi', 'UPI'),
      ('card', 'Card'),
      if (s.bill.customer != null) ('credit', 'Credit'),
    ];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('Total ', style: TextStyle(fontSize: 15, color: Colors.grey.shade700)),
          Text(money(t.total, paise: false), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Kc.navy)),
          const Spacer(),
          for (final m in modes)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(
                label: Text(m.$2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                selected: mode == m.$1,
                onSelected: (_) => onMode(m.$1),
                showCheckmark: false,
                selectedColor: const Color(0xFFC9D9F2),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(
            height: 56,
            width: 96,
            child: OutlinedButton(
              onPressed: s.bill.isEmpty ? null : () => _printCartKot(context),
              child: const Text('KOT', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: s.bill.isEmpty || saving ? null : onSave,
            child: Text(
              saving
                  ? 'Saving…'
                  : mode == 'credit'
                      ? 'SAVE ON CREDIT (${money(t.total, paise: false)})'
                      : 'SAVE (${money(t.total, paise: false)})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        )),
        ]),
      ]),
    );
  }
}

/// KOT for the bill being made, before it is saved.
Future<void> _printCartKot(BuildContext context) async {
  final s = context.read<PosState>();
  final p = context.read<PrinterService>();
  if (!p.configured) {
    await showPrinterSetup(context);
    if (!p.configured) return;
  }
  final bill = s.bill;
  final kot = s.kotFor(bill.id, List.of(bill.lines), width: p.columns);
  final r = await p.print(kot, remember: false);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r ?? 'KOT printed'),
      backgroundColor: r == null ? Kc.greenInk : Kc.red,
      duration: const Duration(seconds: 2),
    ));
  }
}
