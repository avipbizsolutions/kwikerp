import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'app_version.dart';
import 'billing.dart';
import 'catalog.dart';
import 'local_db.dart';
import 'offline_code.dart';
import 'receipt.dart';
import 'sync_service.dart';

class DeviceInfo {
  DeviceInfo(this.m);
  final Map<String, dynamic> m;
  String get id => m['id'] as String;
  String get code => m['code'] as String;
  String get locationId => m['locationId'] as String;
  String get locationCode => m['locationCode'] as String;
  String get locationName => m['locationName'] as String;
  String get companyId => m['companyId'] as String;
  String get defaultLevelId => m['defaultPriceLevelId'] as String;
  String get approvalKey => m['approvalKey'] as String;
}

class SavedBill {
  SavedBill({required this.invoice, required this.docNo, required this.totals, required this.lines,
      required this.customerName, required this.payLabel});
  final Map<String, dynamic> invoice;
  final String? docNo;
  final Totals totals;
  final List<BillLine> lines;
  final String customerName;
  final String payLabel;
}

class PendingApproval {
  PendingApproval({required this.invoice, required this.approval, required this.bill, required this.check});
  final Map<String, dynamic> invoice;
  final Map<String, dynamic> approval;
  final Bill bill;
  final CreditCheck check;
  String get requestCode => approval['offline_request_code'] as String;
  double get amount => (invoice['total'] as num).toDouble();
}

/// App-wide state for the counter tablet.
class PosState extends ChangeNotifier {
  PosState(this.db);
  final LocalDb db;

  String? serverUrl;
  String? tenantCode;
  String? deviceId;
  String? token;
  Map<String, dynamic>? user;
  DeviceInfo? device;
  Catalog? catalog;
  SyncService? sync;
  String? shiftId;
  Map<String, dynamic>? shift;

  late Bill bill;
  final List<Bill> held = [];

  bool get isSetUp => serverUrl != null && tenantCode != null && deviceId != null;
  bool get isLoggedIn => token != null && device != null && user != null;
  bool get hasCatalog => catalog != null && catalog!.items.isNotEmpty;
  String get companyState =>
      (catalog?.companies[device?.companyId]?['state_code'] as String?)?.trim() ?? '10';

  Future<void> init() async {
    final savedUrl = await db.get('server_url');
    serverUrl = savedUrl == null ? null : normaliseServerUrl(savedUrl);
    if (serverUrl != savedUrl) await db.set('server_url', serverUrl);
    tenantCode = await db.get('tenant_code');
    deviceId = await db.get('device_id');
    token = await db.get('token');
    final u = await db.get('user');
    final d = await db.get('device');
    if (u != null) user = Map<String, dynamic>.from(jsonDecode(u) as Map);
    if (d != null) device = DeviceInfo(Map<String, dynamic>.from(jsonDecode(d) as Map));
    shiftId = await db.get('shift_id');
    if (shiftId != null) shift = await db.doc('shift', shiftId!);
    if (isLoggedIn) await _startSession();
    startUpdateChecks();
    notifyListeners();
  }

  Future<void> saveSetup(String url, String tenant, String devId) async {
    serverUrl = normaliseServerUrl(url);
    tenantCode = tenant.trim().toUpperCase();
    deviceId = devId.trim();
    await db.set('server_url', serverUrl);
    await db.set('tenant_code', tenantCode);
    await db.set('device_id', deviceId);
    startUpdateChecks();
    notifyListeners();
  }

  /// Back to the setup screen (wrong server address or tablet code).
  /// Bills already on the tablet and waiting to sync are kept.
  Future<void> resetSetup() async {
    serverUrl = null;
    deviceId = null;
    await db.set('server_url', null);
    await db.set('device_id', null);
    notifyListeners();
  }

  /// PIN login. Needs internet the first time; afterwards the saved session
  /// keeps working offline until it expires.
  Future<void> login(String phone, String pin) async {
    final api = Api(serverUrl!);
    final res = await api.login(tenantCode: tenantCode!, phone: phone.trim(), pin: pin.trim(), deviceId: deviceId!);
    token = res['token'] as String;
    logoutReason = null;
    user = Map<String, dynamic>.from(res['user'] as Map);
    device = DeviceInfo(Map<String, dynamic>.from(res['device'] as Map));
    // Setup may have used the short tablet code (DD3-T1); keep the full id from now on.
    final fullId = device!.m['id'] as String?;
    if (fullId != null && fullId != deviceId) {
      deviceId = fullId;
      await db.set('device_id', deviceId);
    }
    await db.set('token', token);
    await db.set('user', jsonEncode(user));
    await db.set('device', jsonEncode(device!.m));
    await _startSession();
    if (!hasCatalog) await sync!.syncNow();
    notifyListeners();
  }

  Future<void> logout() async {
    sync?.dispose();
    sync = null;
    token = null;
    user = null;
    await db.set('token', null);
    await db.set('user', null);
    notifyListeners();
  }

  Future<void> _startSession() async {
    sync?.dispose();
    final s = SyncService(db, Api(serverUrl!, token: token));
    s.onMastersChanged = reloadCatalog;
    s.onLoggedOut = (m) async {
      logoutReason = m;
      await logout();
    };
    sync = s;
    await reloadCatalog();
    bill = Bill(levelId: device!.defaultLevelId);
    _billReady = true;
    s.start();
  }

  // ------------------------------------------------------- mandatory update

  bool _billReady = false;

  /// Why the tablet was logged out by the server, shown on the login screen.
  String? logoutReason;
  Timer? _updateTimer;

  /// Build number the server says is current, when it is newer than this app.
  int? requiredBuild;
  bool get updateRequired => requiredBuild != null;

  /// A bill in progress or on hold must be finished before updating.
  bool get billInProgress => (_billReady && !bill.isEmpty) || held.isNotEmpty;

  /// Asks the server for the newest app now and every 10 minutes.
  void startUpdateChecks() {
    _updateTimer?.cancel();
    checkForUpdate();
    _updateTimer = Timer.periodic(const Duration(minutes: 10), (_) => checkForUpdate());
  }

  Future<void> checkForUpdate() async {
    if (serverUrl == null || appBuild == 0) return;
    try {
      final v = await Api(serverUrl!).appVersion();
      final latest = (v['versionCode'] as num?)?.toInt() ?? 0;
      final need = latest > appBuild ? latest : null;
      if (need != requiredBuild) {
        requiredBuild = need;
        notifyListeners();
      }
    } catch (_) {
      // Offline: keep working with this version; check again later.
    }
  }

  String get updateUrl => '${serverUrl!.replaceAll(RegExp(r'/+$'), '')}/download/pos.apk';

  Future<void> reloadCatalog() async {
    catalog = await Catalog.load(db, device?.locationId);
    await refreshBestSellers();
    notifyListeners();
  }

  /// Items this tablet sold most often in the last 30 days (by number of bills).
  List<String> bestSellers = [];

  Future<void> refreshBestSellers() async {
    final since = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    final count = <String, int>{};
    for (final l in await db.docs('sales_invoice_line', since: since)) {
      final id = l['item_id'] as String?;
      if (id != null) count[id] = (count[id] ?? 0) + 1;
    }
    final ids = count.keys.where((id) => catalog?.items[id]?.onPos ?? false).toList()
      ..sort((a, b) => count[b]!.compareTo(count[a]!));
    bestSellers = ids.take(16).toList();
  }

  // ---------------------------------------------------------------- shift

  bool get shiftOpen => shift != null && shift!['closed_at'] == null;

  Future<void> openShift(double openingCash) async {
    final id = newId();
    shift = {
      'id': id,
      'location_id': device!.locationId,
      'device_id': device!.id,
      'user_id': user!['id'],
      'opened_at': DateTime.now().toUtc().toIso8601String(),
      'opening_cash': openingCash,
    };
    shiftId = id;
    await db.saveDocs({'shift': [shift!]});
    await db.set('shift_id', id);
    await sync?.refreshPending();
    notifyListeners();
  }

  /// Totals for the open shift, from this tablet's own records.
  Future<Map<String, double>> shiftSummary() async {
    final byMode = <String, double>{'cash': 0, 'upi': 0, 'card': 0, 'credit': 0};
    var bills = 0.0, sales = 0.0;
    for (final r in await db.docs('receipt')) {
      if (r['shift_id'] != shiftId || r['status'] != 'final') continue;
      final m = r['mode'] as String;
      byMode[m] = (byMode[m] ?? 0) + (r['amount'] as num).toDouble();
    }
    for (final i in await db.docs('sales_invoice')) {
      if (i['shift_id'] != shiftId || i['status'] != 'final') continue;
      bills += 1;
      sales += (i['total'] as num).toDouble();
      byMode['credit'] = byMode['credit']! + (i['balance'] as num).toDouble();
    }
    final opening = ((shift?['opening_cash'] ?? 0) as num).toDouble();
    return {...byMode, 'bills': bills, 'sales': sales, 'opening': opening, 'expected_cash': opening + byMode['cash']!};
  }

  Future<void> closeShift(double counted, String note) async {
    final sum = await shiftSummary();
    shift = {
      ...shift!,
      'closed_at': DateTime.now().toUtc().toIso8601String(),
      'counted_cash': counted,
      'expected_cash': sum['expected_cash'],
      'note': note.isEmpty ? null : note,
    };
    await db.saveDocs({'shift': [shift!]});
    await db.set('shift_id', null);
    shiftId = null;
    await sync?.syncNow();
    notifyListeners();
  }

  // ---------------------------------------------------------------- billing

  void addItem(Item item, double qty, {bool replace = false}) {
    final cat = catalog!;
    final line = bill.lineFor(item.id, item.baseUnitId);
    if (line != null) {
      line.qty = replace ? qty : line.qty + qty;
      if (line.qty <= 0) bill.lines.remove(line);
    } else if (qty > 0) {
      final p = cat.price(item.id, item.baseUnitId, bill.levelId);
      if (p == null) throw StateError('No ${cat.levelName(bill.levelId)} price for ${item.name}');
      bill.lines.add(BillLine(item: item, unitId: item.baseUnitId, factor: 1, qty: qty, listRate: p));
    }
    notifyListeners();
  }

  void setCustomer(Customer? c) {
    bill.customer = c;
    bill.levelId = catalog!.levelForCustomer(c, device!.defaultLevelId);
    bill.reprice(catalog!);
    notifyListeners();
  }

  void holdBill() {
    if (bill.isEmpty) return;
    held.add(bill);
    bill = Bill(levelId: device!.defaultLevelId);
    notifyListeners();
  }

  void resumeBill(Bill b) {
    if (!bill.isEmpty) held.add(bill);
    held.remove(b);
    bill = b;
    notifyListeners();
  }

  void clearBill() {
    bill = Bill(levelId: device!.defaultLevelId);
    notifyListeners();
  }

  Future<Customer> addCustomer(String name, String phone, String categoryId) async {
    final row = {
      'id': newId(),
      'name': name.trim(),
      'phone': phone.trim().isEmpty ? null : phone.trim(),
      'category_id': categoryId,
      'home_location_id': device!.locationId,
      'is_active': true,
    };
    await db.saveDocs({'customer': [row]});
    final c = Customer(row);
    catalog!.customers[c.id] = c;
    await sync?.refreshPending();
    notifyListeners();
    return c;
  }

  /// Credit given on this tablet since the last outstanding snapshot.
  Future<double> localUnsyncedCredit(String customerId) async {
    final since = await db.get('outstanding_at');
    var sum = 0.0;
    for (final i in await db.docs('sales_invoice', since: since)) {
      if (i['customer_id'] == customerId && (i['status'] == 'final' || i['status'] == 'pending_approval')) {
        sum += (i['balance'] as num).toDouble();
      }
    }
    return sum;
  }

  Future<CreditCheck> creditCheckFor(double balance) async {
    final c = bill.customer!;
    return checkCredit(
        cat: catalog!, customer: c, billBalance: balance, localUnsyncedCredit: await localUnsyncedCredit(c.id));
  }

  Future<String> _nextDocNo() async {
    final fy = finYear(DateTime.now());
    final key = 'seq_INV_$fy';
    var last = int.tryParse(await db.get(key) ?? '0') ?? 0;
    // After a reinstall, continue from what the server last saw
    for (final s in await db.masters('doc_series')) {
      if (s['doc_type'] == 'INV' && s['fin_year'] == fy) {
        final n = (s['last_no'] as num).toInt();
        if (n > last) last = n;
      }
    }
    last += 1;
    await db.set(key, '$last');
    return '${device!.locationCode}-${device!.code}-$fy-${last.toString().padLeft(6, '0')}';
  }

  Map<String, dynamic> _invoiceRow(Bill b, Totals t, String status, double paid) {
    final now = DateTime.now();
    return {
      'id': b.id,
      'company_id': device!.companyId,
      'location_id': device!.locationId,
      'device_id': device!.id,
      'shift_id': shiftId,
      'doc_type': 'INV',
      'doc_no': null,
      'doc_date': now.toIso8601String().substring(0, 10),
      'status': status,
      'customer_id': b.customer?.id,
      'price_level_id': b.levelId,
      'place_of_supply': b.customer?.stateCode ?? companyState,
      'subtotal': t.subtotal,
      'discount': 0,
      'taxable': t.taxable,
      'cgst': t.cgst,
      'sgst': t.sgst,
      'igst': t.igst,
      'cess': 0,
      'round_off': t.roundOff,
      'total': t.total,
      'paid': paid,
      'balance': r2(t.total - paid),
      'created_by': user!['id'],
    };
  }

  List<Map<String, dynamic>> _lineRows(Bill b) {
    final inter = b.interState(companyState);
    var n = 0;
    return b.lines.map((l) {
      n += 1;
      final s = splitTax(l.amount, l.item.gstRate, inter);
      return {
        'id': '${b.id.substring(0, 24)}${n.toString().padLeft(12, '0')}',
        'invoice_id': b.id,
        'line_no': n,
        'item_id': l.item.id,
        'unit_id': l.unitId,
        'qty': l.qty,
        'factor': l.factor,
        'rate': l.rate,
        'list_rate': l.listRate,
        'rate_overridden_by': l.rateOverriddenBy,
        'discount': 0,
        'hsn': l.item.hsn,
        'gst_rate': l.item.gstRate,
        'taxable': s.taxable,
        'cgst': s.cgst,
        'sgst': s.sgst,
        'igst': s.igst,
        'cess': 0,
        'amount': l.amount,
      };
    }).toList();
  }

  /// Final bill: number, receipts for what was paid, stock out.
  Future<SavedBill> _finalise(Bill b, Totals t, Map<String, dynamic> invoice, String mode, double paid,
      {Map<String, dynamic>? approval}) async {
    final docNo = await _nextDocNo();
    final now = DateTime.now();
    final inv = {...invoice, 'status': 'final', 'doc_no': docNo, 'finalised_at': now.toUtc().toIso8601String()};
    final receipts = <Map<String, dynamic>>[];
    if (paid > 0) {
      receipts.add({
        'id': newId(),
        'location_id': device!.locationId,
        'device_id': device!.id,
        'shift_id': shiftId,
        'doc_date': inv['doc_date'],
        'customer_id': b.customer?.id,
        'invoice_id': b.id,
        'mode': mode,
        'amount': paid,
        'created_by': user!['id'],
        'status': 'final',
      });
    }
    final moves = b.lines
        .map((l) => {
              'id': newId(),
              'location_id': device!.locationId,
              'item_id': l.item.id,
              'qty': -r2(l.qty * l.factor * 1000) / 1000,
              'move_type': 'sale',
              'doc_id': b.id,
              'move_date': inv['doc_date'],
              'created_by': user!['id'],
            })
        .toList();
    await db.saveDocs({
      'sales_invoice': [inv],
      'sales_invoice_line': _lineRows(b),
      'receipt': receipts,
      'stock_move': moves,
      if (approval != null) 'credit_approval': [approval],
    });
    await sync?.refreshPending();
    sync?.syncNow();
    return SavedBill(
        invoice: inv,
        docNo: docNo,
        totals: t,
        lines: List.of(b.lines),
        customerName: b.customer?.name ?? 'Walk-in customer',
        payLabel: paid > 0 ? 'Paid by ${mode.toUpperCase()}' : 'On credit');
  }

  // -------------------------------------------------------------------- KOT

  /// What each bill's last KOT contained, to mark a changed one UPDATED.
  final Map<String, String> _kots = {};

  String _kotItems(List<BillLine> lines) => lines.map((l) => '${l.item.id}:${l.qty}').join('|');

  /// KOT text for a bill (saved or not).
  String kotFor(String billId, List<BillLine> lines, {required int width, bool reprint = false}) {
    final items = _kotItems(lines);
    final before = _kots[billId];
    final updated = before != null && before != items;
    _kots[billId] = items;
    return buildKot(this, lines: lines, width: width, updated: updated, reprint: reprint && !updated);
  }

  /// True when a KOT already went out for exactly these items.
  bool kotUpToDate(String billId, List<BillLine> lines) => _kots[billId] == _kotItems(lines);

    // ------------------------------------------------------------ bill history

  /// Bills made on this tablet, newest first.
  Future<List<Map<String, dynamic>>> billHistory() async {
    final all = await db.docs('sales_invoice');
    return all.reversed.toList();
  }

  /// Rebuilds a stored bill for the receipt screen and reprinting.
  Future<SavedBill> savedBillFrom(Map<String, dynamic> inv) async {
    final cat = catalog!;
    final lines = <BillLine>[];
    for (final l in await db.invoiceLines(inv['id'] as String)) {
      final item = cat.items[l['item_id']] ??
          Item({'id': l['item_id'], 'name': 'Item no longer listed', 'code': '', 'category_id': '', 'base_unit_id': l['unit_id']});
      final bl = BillLine(
          item: item,
          unitId: l['unit_id'] as String,
          factor: (l['factor'] as num).toDouble(),
          qty: (l['qty'] as num).toDouble(),
          listRate: (l['list_rate'] as num).toDouble());
      bl.rate = (l['rate'] as num).toDouble();
      lines.add(bl);
    }
    double n(String k) => ((inv[k] ?? 0) as num).toDouble();
    final t = Totals(n('subtotal'), n('taxable'), n('cgst'), n('sgst'), n('igst'), n('round_off'), n('total'));
    final receipts = (await db.docs('receipt')).where((r) => r['invoice_id'] == inv['id']).toList();
    final modes = receipts.map((r) => (r['mode'] as String).toUpperCase()).toSet().join(' + ');
    final status = inv['status'] as String;
    return SavedBill(
      invoice: inv,
      docNo: inv['doc_no'] as String?,
      totals: t,
      lines: lines,
      customerName: inv['customer_id'] == null
          ? 'Walk-in customer'
          : (cat.customers[inv['customer_id']]?.name ?? 'Customer'),
      payLabel: status == 'cancelled'
          ? 'CANCELLED: ${inv['cancel_reason'] ?? ''}'
          : n('paid') > 0
              ? 'Paid by $modes${n('balance') > 0 ? ', ${money(n('balance'), paise: false)} on credit' : ''}'
              : 'On credit',
    );
  }

  bool _can(String perm) {
    final p = (user?['permissions'] as List?)?.cast<String>() ?? const [];
    return p.contains('*') || p.contains(perm);
  }

  /// Rate chart and customer types: owners and managers.
  bool get canManageRates => _can('rates.manage');

  /// Online calls for the manager screens.
  Api get onlineApi => Api(serverUrl!, token: token);

  bool get canCancelBills {
    final p = (user?['permissions'] as List?)?.cast<String>() ?? const [];
    return p.contains('*') || p.contains('bill.cancel');
  }

  /// Cancels a final bill on the server (needs internet), then here.
  /// A cashier without the permission gives a manager's mobile + PIN.
  Future<String> cancelBill(Map<String, dynamic> inv, String reason, {String? approverPhone, String? approverPin}) async {
    await sync?.syncNow(); // the bill must be on the server first
    final api = Api(serverUrl!, token: token);
    final r = await api.cancelBill(inv['id'] as String,
        reason: reason.trim(), approverPhone: approverPhone?.trim(), approverPin: approverPin?.trim());
    await db.patchDoc('sales_invoice', inv['id'] as String, {
      'status': 'cancelled',
      'cancelled_by': r['cancelledBy'],
      'cancel_reason': reason.trim(),
    });
    for (final id in (r['receiptIds'] as List? ?? const [])) {
      await db.patchDoc('receipt', id as String, {'status': 'cancelled'});
    }
    // Receipts the server had not seen yet are cancelled here too
    for (final rc in (await db.docs('receipt')).where((x) => x['invoice_id'] == inv['id'])) {
      await db.patchDoc('receipt', rc['id'] as String, {'status': 'cancelled'});
    }
    notifyListeners();
    return r['cancelledByName'] as String? ?? '';
  }

  /// Pay in full by cash / UPI / card.
  Future<SavedBill> payNow(String mode) async {
    final t = bill.totals(companyState);
    final saved = await _finalise(bill, t, _invoiceRow(bill, t, 'final', t.total), mode, t.total);
    clearBill();
    return saved;
  }

  /// Credit bill: final if within limit, else saved as pending approval.
  Future<Object> payOnCredit() async {
    final t = bill.totals(companyState);
    final check = await creditCheckFor(t.total);
    if (check.allowed) {
      final saved = await _finalise(bill, t, _invoiceRow(bill, t, 'final', 0), 'credit', 0);
      clearBill();
      return saved;
    }
    final invoice = _invoiceRow(bill, t, 'pending_approval', 0);
    final approval = {
      'id': newId(),
      'invoice_id': bill.id,
      'customer_id': bill.customer!.id,
      'location_id': device!.locationId,
      'requested_by': user!['id'],
      'requested_at': DateTime.now().toUtc().toIso8601String(),
      'reasons': check.reasons.where((r) => r != 'not_allowed').isEmpty ? ['amount'] : check.reasons.where((r) => r != 'not_allowed').toList(),
      'outstanding': check.outstanding,
      'bill_amount': t.total,
      'limit_amount': check.limit,
      'oldest_due_days': check.oldestDays,
      'status': 'pending',
      'offline_request_code': OfflineCode.newRequestCode(),
    };
    await db.saveDocs({'sales_invoice': [invoice], 'sales_invoice_line': _lineRows(bill), 'credit_approval': [approval]});
    await sync?.refreshPending();
    sync?.syncNow();
    final p = PendingApproval(invoice: invoice, approval: approval, bill: bill, check: check);
    bill = Bill(levelId: device!.defaultLevelId);
    notifyListeners();
    return p;
  }

  /// Has the manager decided? Looks at what the last sync brought back.
  Future<String> approvalStatus(PendingApproval p) async {
    await sync?.syncNow();
    for (final a in await db.masters('credit_approval')) {
      if (a['id'] == p.approval['id']) return a['status'] as String;
    }
    return 'pending';
  }

  Future<SavedBill> finaliseApproved(PendingApproval p, {String? offlineCode}) async {
    final t = p.bill.totals(companyState);
    Map<String, dynamic>? approval;
    if (offlineCode != null) {
      approval = {
        ...p.approval,
        'status': 'approved',
        'decision': 'once',
        'decided_at': DateTime.now().toUtc().toIso8601String(),
        'decision_note': 'Offline approval code $offlineCode',
      };
    }
    return _finalise(p.bill, t, p.invoice, 'credit', 0, approval: approval);
  }

  bool checkOfflineCode(PendingApproval p, String code) =>
      OfflineCode.check(device!.approvalKey, p.requestCode, p.amount, code);

  /// Rejected or abandoned: keep the bill as cancelled so the trail stays.
  Future<void> cancelPending(PendingApproval p, {required String reason, bool takePaymentInstead = false}) async {
    await db.saveDocs({
      'sales_invoice': [
        {...p.invoice, 'status': 'cancelled', 'cancel_reason': reason, 'cancelled_by': user!['id']}
      ],
      'credit_approval': [
        {...p.approval, 'status': 'withdrawn'}
      ],
    });
    if (takePaymentInstead) {
      // Put the same items back on the counter as a new bill
      final b = Bill(levelId: p.bill.levelId)..customer = p.bill.customer;
      for (final l in p.bill.lines) {
        b.lines.add(BillLine(item: l.item, unitId: l.unitId, factor: l.factor, qty: l.qty, listRate: l.listRate));
      }
      bill = b;
    }
    await sync?.refreshPending();
    notifyListeners();
  }
}

/// Turns whatever was typed into `https://host/api`:
/// "api.kwikerp.cloud", "https://https//api.kwikerp.cloud/api/" and the like.
String normaliseServerUrl(String typed) {
  var u = typed.trim().replaceAll(' ', '');
  // Drop any number of leading schemes, including broken ones like "https//".
  final scheme = RegExp(r'^(https?(:/*|//+))+', caseSensitive: false);
  final hadHttpOnly = RegExp(r'^http:', caseSensitive: false).hasMatch(u) && !u.toLowerCase().startsWith('https');
  u = u.replaceFirst(scheme, '');
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  if (!u.toLowerCase().endsWith('/api')) u = '$u/api';
  return '${hadHttpOnly ? 'http' : 'https'}://$u';
}
