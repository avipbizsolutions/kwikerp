import 'package:uuid/uuid.dart';

import 'catalog.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

double r2(num v) => (v * 100).roundToDouble() / 100;

String money(num v, {bool paise = true}) {
  final neg = v < 0;
  final fixed = v.abs().toStringAsFixed(paise ? 2 : 0);
  final parts = fixed.split('.');
  var whole = parts[0];
  // Indian grouping: 12,34,567
  if (whole.length > 3) {
    final last3 = whole.substring(whole.length - 3);
    var rest = whole.substring(0, whole.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    whole = '${groups.join(',')},$last3';
  }
  return '${neg ? '−' : ''}₹$whole${parts.length > 1 ? '.${parts[1]}' : ''}';
}

String qtyText(double q, bool byWeight) => byWeight ? '${q.toStringAsFixed(3)} kg' : q.toStringAsFixed(q % 1 == 0 ? 0 : 3);

/// Indian financial year code: Apr 2026 – Mar 2027 => "2627".
String finYear(DateTime d) {
  final start = d.month >= 4 ? d.year : d.year - 1;
  return '${(start % 100).toString().padLeft(2, '0')}${((start + 1) % 100).toString().padLeft(2, '0')}';
}

class BillLine {
  BillLine({required this.item, required this.unitId, required this.factor, required this.qty, required this.listRate})
      : rate = listRate;
  final Item item;
  final String unitId;
  final double factor;
  double qty;
  double listRate;
  double rate;
  String? rateOverriddenBy;

  double get amount => r2(rate * qty);
}

class Totals {
  Totals(this.subtotal, this.taxable, this.cgst, this.sgst, this.igst, this.roundOff, this.total);
  final double subtotal, taxable, cgst, sgst, igst, roundOff, total;
  double get gst => r2(cgst + sgst + igst);
}

/// A bill being built at the counter. Prices are tax-inclusive (MRP style).
class Bill {
  Bill({required this.levelId});
  final String id = newId();
  final List<BillLine> lines = [];
  Customer? customer;
  String levelId;

  bool get isEmpty => lines.isEmpty;

  BillLine? lineFor(String itemId, String unitId) {
    for (final l in lines) {
      if (l.item.id == itemId && l.unitId == unitId) return l;
    }
    return null;
  }

  /// Re-price every line after the customer (and so the price level) changes.
  void reprice(Catalog cat) {
    for (final l in lines) {
      final p = cat.price(l.item.id, l.unitId, levelId);
      if (p != null) {
        l.listRate = p;
        l.rate = p;
        l.rateOverriddenBy = null;
      }
    }
  }

  bool interState(String companyState) =>
      customer?.stateCode != null && customer!.stateCode!.isNotEmpty && customer!.stateCode != companyState;

  Totals totals(String companyState) {
    var sub = 0.0, taxable = 0.0, cgst = 0.0, sgst = 0.0, igst = 0.0;
    final inter = interState(companyState);
    for (final l in lines) {
      final s = splitTax(l.amount, l.item.gstRate, inter);
      sub += l.amount;
      taxable += s.taxable;
      cgst += s.cgst;
      sgst += s.sgst;
      igst += s.igst;
    }
    sub = r2(sub);
    final total = sub.roundToDouble();
    return Totals(sub, r2(taxable), r2(cgst), r2(sgst), r2(igst), r2(total - sub), total);
  }
}

class TaxSplit {
  TaxSplit(this.taxable, this.cgst, this.sgst, this.igst);
  final double taxable, cgst, sgst, igst;
}

TaxSplit splitTax(double amountInclTax, double gstRate, bool interState) {
  final taxable = r2(amountInclTax / (1 + gstRate / 100));
  final tax = r2(amountInclTax - taxable);
  if (interState) return TaxSplit(taxable, 0, 0, tax);
  final c = r2(tax / 2);
  return TaxSplit(taxable, c, r2(tax - c), 0);
}

/// Result of checking a credit bill against the customer's limit.
class CreditCheck {
  CreditCheck({required this.allowed, required this.reasons, required this.outstanding, required this.after,
      this.limit, required this.oldestDays, required this.rule});
  final bool allowed;
  final List<String> reasons; // 'amount', 'days', 'security', 'not_allowed'
  final double outstanding;
  final double after;
  final double? limit;
  final int oldestDays;
  final CreditRule rule;

  String explain() {
    final parts = <String>[];
    if (reasons.contains('not_allowed')) parts.add('credit is not allowed for this customer type');
    if (reasons.contains('amount')) {
      parts.add('outstanding would be ${money(after, paise: false)} against a limit of ${money(limit ?? 0, paise: false)}');
    }
    if (reasons.contains('days')) parts.add('oldest unpaid bill is $oldestDays days old (limit ${rule.maxDays})');
    if (reasons.contains('security')) parts.add('outstanding would exceed the security held');
    return parts.join('; ');
  }
}

CreditCheck checkCredit({
  required Catalog cat,
  required Customer customer,
  required double billBalance,
  required double localUnsyncedCredit,
}) {
  final rule = cat.creditRule(customer);
  final out = (cat.outstanding[customer.id] ?? 0) + localUnsyncedCredit;
  final after = out + billBalance;
  final days = cat.oldestDueDays[customer.id] ?? 0;
  final reasons = <String>[];
  if (!cat.creditAllowed(customer)) reasons.add('not_allowed');
  // No limit row at all: treat as zero limit, so it goes for approval.
  final limit = rule.source == 'none' ? 0.0 : rule.maxOutstanding;
  if (limit != null && after > limit) reasons.add('amount');
  if (rule.maxDays != null && rule.maxDays! > 0 && days > rule.maxDays!) reasons.add('days');
  if (rule.capToSecurity && after > customer.security) reasons.add('security');
  return CreditCheck(
      allowed: reasons.isEmpty, reasons: reasons, outstanding: out, after: after, limit: limit,
      oldestDays: days, rule: rule);
}
