import 'billing.dart';
import 'escpos.dart';
import 'pos_state.dart';

/// Builds the receipt from the layout head office set (Settings > Receipt).
///
/// [width] is 48 columns for 80 mm paper, 32 for 58 mm. With [forPrint] the
/// text is ASCII with the EscPos markers (^C centre, ^B bold, ^W big, ^G logo);
/// otherwise it is for the screen.
String buildReceipt(PosState s, SavedBill b, {int width = 48, bool forPrint = false, bool duplicate = false}) {
  final cat = s.catalog!;
  final r = cat.receipt;
  bool opt(String k) => r[k] is bool ? r[k] as bool : true;
  String text(String k, String fallback) => r[k] is String ? r[k] as String : fallback;

  final w = width;
  String t(String v) => forPrint ? EscPos.ascii(v) : v;
  String m(double v, {bool paise = true}) =>
      forPrint ? EscPos.ascii(money(v, paise: paise)).replaceAll('Rs', '') : money(v, paise: paise);
  String n2(double v) => v.toStringAsFixed(2);
  String fit(String v) => v.length <= w ? v : v.substring(0, w);
  String line([String c = '-']) => c * w;
  String lr(String l, String rt) {
    final space = w - l.length - rt.length;
    return space > 0 ? '$l${' ' * space}$rt' : '${l.substring(0, (w - rt.length - 1).clamp(0, l.length))} $rt';
  }

  final c = forPrint ? '^C' : '';
  final bold = forPrint ? '^B' : '';
  final big = forPrint ? '^W' : '';

  // Fields for {placeholders}
  final co = cat.companies[s.device!.companyId] ?? const {};
  final loc = cat.locations[s.device!.locationId] ?? const {};
  String? f(Object? v) => (v == null || v.toString().trim().isEmpty) ? null : v.toString().trim();
  final fields = <String, String?>{
    'company': f(co['legal_name']),
    'outlet': f(loc['name']) ?? s.device!.locationName,
    'outlet_address': f(loc['address']),
    'address': f(co['address']),
    'gstin': f(co['gstin']),
    'phone': f(loc['phone']) ?? f(co['phone']),
    'email': f(co['email']),
    'fssai': f(loc['fssai_no']) ?? f(co['fssai_no']),
  };
  // A line whose {fields} are all empty is left out ("GSTIN: {gstin}" with no GSTIN).
  List<String> expand(String template) {
    final out = <String>[];
    for (final raw in template.split('\n')) {
      final names = RegExp(r'\{(\w+)\}').allMatches(raw).map((x) => x.group(1)!).toList();
      if (names.isNotEmpty && names.every((k) => fields[k] == null)) continue;
      final v = raw.replaceAllMapped(RegExp(r'\{(\w+)\}'), (x) => fields[x.group(1)] ?? '').trim();
      if (v.isNotEmpty) out.add(v);
    }
    return out;
  }

  // Long text over several lines, broken at spaces.
  List<String> wrap(String v, int cols) {
    final words = v.split(RegExp(r'\s+'));
    final out = <String>[];
    var cur = '';
    for (final word in words) {
      final piece = word.length > cols ? word.substring(0, cols) : word;
      if (cur.isEmpty) {
        cur = piece;
      } else if (cur.length + 1 + piece.length <= cols) {
        cur = '$cur $piece';
      } else {
        out.add(cur);
        cur = piece;
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  int lines(String k, int d) => r[k] is num ? (r[k] as num).toInt().clamp(0, 10) : d;
  final out = StringBuffer();
  if (forPrint) out.writeln('^T${lines('billTop', 0)}');
  final logo = r['logo'];
  if (forPrint && logo is Map && logo['data'] is String) {
    out.writeln('^G${logo['width']},${logo['height']},${logo['data']}');
  }
  if (duplicate) out.writeln('$c${bold}DUPLICATE');
  final title = expand(text('title', '{company}'));
  for (final l in title) {
    for (final p in wrap(t(l), forPrint ? w ~/ 2 * 2 : w)) {
      out.writeln('$c$big$p');
    }
  }
  for (final l in expand(text('header', '{outlet}\n{outlet_address}\nGSTIN: {gstin}\nPhone: {phone}\n{email}'))) {
    for (final p in wrap(t(l), w)) {
      out.writeln('$c$p');
    }
  }
  out.writeln(line());

  final finalisedAt = DateTime.tryParse((b.invoice['finalised_at'] ?? '').toString())?.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final dateText = finalisedAt == null
      ? (b.invoice['doc_date'] ?? '').toString()
      : '${two(finalisedAt.day)}/${two(finalisedAt.month)}/${finalisedAt.year % 100}'
          '${opt('showTime') ? ' ${two(finalisedAt.hour % 12 == 0 ? 12 : finalisedAt.hour % 12)}:${two(finalisedAt.minute)} ${finalisedAt.hour < 12 ? 'AM' : 'PM'}' : ''}';
  if (w >= 40) {
    out.writeln('$bold${lr('Bill ${b.docNo ?? ''}', dateText)}');
  } else {
    out.writeln('${bold}Bill ${b.docNo ?? ''}');
    out.writeln(dateText);
  }
  if (opt('showCustomer')) out.writeln(fit('Bill to: ${t(b.customerName)}'));
  out.writeln(line());

  // Items
  final table = opt('itemTable');
  const qW = 5, rW = 9, aW = 10;
  final nameW = w - qW - rW - aW;
  String qty(BillLine l) =>
      l.item.soldByWeight ? l.qty.toStringAsFixed(3) : l.qty.toStringAsFixed(l.qty % 1 == 0 ? 0 : 3);
  if (table && w >= 40) {
    out.writeln('$bold${'Item'.padRight(nameW)}${'Qty'.padLeft(qW)}${'Rate'.padLeft(rW)}${'Total'.padLeft(aW)}');
  }
  var count = 0.0;
  for (final l in b.lines) {
    final name = t(l.item.fullName) + (l.item.soldByWeight ? ' (kg)' : '');
    count += l.item.soldByWeight ? 1 : l.qty;
    if (table && w >= 40) {
      final parts = wrap(name, nameW - 1);
      for (var i = 0; i < parts.length; i++) {
        if (i == 0) {
          out.writeln('${parts[0].padRight(nameW)}${qty(l).padLeft(qW)}${n2(l.rate).padLeft(rW)}${n2(l.amount).padLeft(aW)}');
        } else {
          out.writeln(parts[i]);
        }
      }
    } else {
      for (final p in wrap(name, w)) {
        out.writeln(p);
      }
      out.writeln(lr('  ${qty(l)} x ${n2(l.rate)}', n2(l.amount)));
    }
  }
  out.writeln(line());
  if (opt('showCounts')) {
    final q = count % 1 == 0 ? count.toStringAsFixed(0) : count.toStringAsFixed(3);
    out.writeln(lr('Items ${b.lines.length}', 'Qty $q'));
  }

  // Taxes and total
  final tt = b.totals;
  out.writeln(lr('Taxable', m(tt.taxable)));
  if (opt('splitGst') && tt.igst == 0) {
    out.writeln(lr('CGST', m(tt.cgst)));
    out.writeln(lr('SGST', m(tt.sgst)));
  } else if (tt.igst > 0) {
    out.writeln(lr('IGST', m(tt.igst)));
  } else {
    out.writeln(lr('GST', m(tt.gst)));
  }
  if (tt.roundOff != 0) out.writeln(lr('Round off', m(tt.roundOff)));
  out.writeln('$big${lr(forPrint ? 'TOTAL Rs' : 'TOTAL', m(tt.total, paise: false))}');
  out.writeln(t(b.payLabel));
  final paid = ((b.invoice['paid'] ?? 0) as num).toDouble();
  if (paid > 0 && b.invoice['status'] != 'cancelled') out.writeln(lr('Received', m(paid)));

  // Saving against MRP (e.g. retailer or staff rates)
  if (opt('showSavings')) {
    var saving = 0.0;
    for (final l in b.lines) {
      final mrp = cat.price(l.item.id, l.unitId, s.device!.defaultLevelId);
      if (mrp != null && mrp > l.rate) saving += (mrp - l.rate) * l.qty;
    }
    if (saving >= 1) out.writeln('$c${bold}You saved ${forPrint ? 'Rs ' : ''}${m(r2(saving), paise: false)}');
  }
  out.writeln(line());
  for (final l in expand(text('footer', 'Thank You! Visit Again!'))) {
    for (final p in wrap(t(l), w)) {
      out.writeln('$c$p');
    }
  }
  if (forPrint) out.writeln('^F${lines('billBottom', 4)}');
  return out.toString();
}


/// KOT for the service team: items and quantities only (no prices, numbers
/// or bill details). [updated] marks a KOT printed again after the items
/// changed; [reprint] a copy of one already printed.
String buildKot(PosState s, {required List<BillLine> lines, int width = 48, bool updated = false, bool reprint = false}) {
  final w = width;
  String lr(String l, String r) {
    final space = w - l.length - r.length;
    return space > 0 ? '$l${' ' * space}$r' : '${l.substring(0, (w - r.length - 1).clamp(0, l.length))} $r';
  }

  final line = '-' * w;
  final r = s.catalog!.receipt;
  int sp(String k, int d) => r[k] is num ? (r[k] as num).toInt().clamp(0, 10) : d;
  final out = StringBuffer()
    ..writeln('^T${sp('tokenTop', 0)}')
    ..writeln('^C^BToken');
  if (updated) out.writeln('^C^BUPDATED - replaces the earlier token');
  if (reprint) out.writeln('^C^BREPRINT');
  out.writeln(line);
  var count = 0.0;
  for (final l in lines) {
    final q = l.item.soldByWeight
        ? (l.qty < 1 ? '${(l.qty * 1000).round()} g' : '${l.qty.toStringAsFixed(3)} kg')
        : '${l.qty.toStringAsFixed(l.qty % 1 == 0 ? 0 : 3)} x';
    count += l.item.soldByWeight ? 1 : l.qty;
    final qcol = q.padRight(8);
    final room = w - qcol.length;
    var rest = EscPos.ascii(l.item.fullName);
    var first = true;
    while (rest.isNotEmpty) {
      var cut = rest.length <= room ? rest.length : rest.lastIndexOf(' ', room);
      if (cut <= 0) cut = rest.length < room ? rest.length : room;
      out.writeln('^W${first ? qcol : ' ' * qcol.length}${rest.substring(0, cut).trim()}');
      rest = rest.substring(cut).trim();
      first = false;
    }
  }
  final qn = count % 1 == 0 ? count.toStringAsFixed(0) : count.toStringAsFixed(3);
  out
    ..writeln(line)
    ..writeln(lr('Items ${lines.length}', 'Qty $qn'))
    ..writeln('^F${sp('tokenBottom', 4)}');
  return out.toString();
}
