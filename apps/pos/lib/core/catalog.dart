import 'local_db.dart';

double _num(dynamic v) => v == null ? 0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0);

class Item {
  Item(this.row);
  final Map<String, dynamic> row;
  String get id => row['id'] as String;
  String get code => row['code'].toString();
  String get name => row['name'] as String;
  String get categoryId => row['category_id'] as String;
  String get baseUnitId => row['base_unit_id'] as String;
  bool get soldByWeight => row['sold_by_weight'] == true;
  bool get onPos => row['show_on_pos'] == true && row['is_active'] == true;
  String? get hsn => row['hsn'] as String?;
  double get gstRate => _num(row['gst_rate']);
  int get posSort => (row['pos_sort'] as num?)?.toInt() ?? 0;
  /// e.g. "500 ml" when the name doesn't say it; empty otherwise.
  String get packSize => (row['pack_size'] as String?)?.trim() ?? '';
  /// Name with pack size, for receipts and the bill list.
  String get fullName => packSize.isEmpty ? name : '$name $packSize';
}

class Category {
  Category(this.row);
  final Map<String, dynamic> row;
  String get id => row['id'] as String;
  String get name => row['name'] as String;
  int get sort => (row['sort_order'] as num?)?.toInt() ?? 0;
  String? get colour => row['pos_colour'] as String?;
}

class Customer {
  Customer(this.row);
  final Map<String, dynamic> row;
  String get id => row['id'] as String;
  String get name => row['name'] as String;
  String? get phone => row['phone'] as String?;
  String get categoryId => row['category_id'] as String;
  String? get priceLevelId => row['price_level_id'] as String?;
  String? get stateCode => row['state_code'] as String?;
  double get security => _num(row['security_amount']);
}

class CreditRule {
  CreditRule({this.maxOutstanding, this.maxDays, this.capToSecurity = false, required this.source});
  final double? maxOutstanding;
  final int? maxDays;
  final bool capToSecurity;
  final String source; // 'customer', 'category' or 'none'
}

/// Everything the counter needs, held in memory (a few hundred items).
class Catalog {
  Catalog._();

  final Map<String, Item> items = {};
  final List<Category> categories = [];
  final Map<String, Map<String, dynamic>> units = {};
  final Map<String, Map<String, dynamic>> priceLevels = {};
  final Map<String, Customer> customers = {};
  final Map<String, Map<String, dynamic>> customerCategories = {};
  final Map<String, Map<String, dynamic>> companies = {};
  final Map<String, Map<String, dynamic>> users = {};
  final List<Map<String, dynamic>> _packs = [];
  final List<Map<String, dynamic>> _prices = [];
  final List<Map<String, dynamic>> _limits = [];
  final Map<String, double> outstanding = {};
  final Map<String, int> oldestDueDays = {};

  static Future<Catalog> load(LocalDb db, String? locationId) async {
    final c = Catalog._();
    for (final r in await db.masters('item')) {
      c.items[r['id'] as String] = Item(r);
    }
    c.categories.addAll((await db.masters('item_category')).map(Category.new));
    c.categories.sort((a, b) => a.sort.compareTo(b.sort));
    for (final r in await db.masters('unit')) {
      c.units[r['id'] as String] = r;
    }
    for (final r in await db.masters('price_level')) {
      c.priceLevels[r['id'] as String] = r;
    }
    for (final r in await db.masters('customer')) {
      if (r['is_active'] != false) c.customers[r['id'] as String] = Customer(r);
    }
    // Customers created on this tablet and not yet pulled back
    for (final r in await db.docs('customer')) {
      c.customers.putIfAbsent(r['id'] as String, () => Customer(r));
    }
    for (final r in await db.masters('customer_category')) {
      c.customerCategories[r['id'] as String] = r;
    }
    for (final r in await db.masters('company')) {
      c.companies[r['id'] as String] = r;
    }
    for (final r in await db.masters('app_user')) {
      c.users[r['id'] as String] = r;
    }
    c._packs.addAll(await db.masters('item_pack'));
    c._prices.addAll((await db.masters('item_price'))
        .where((p) => p['location_id'] == null || p['location_id'] == locationId));
    c._limits.addAll(await db.masters('credit_limit'));
    final snap = await db.get('outstanding');
    if (snap != null) c._applyOutstanding(snap);
    return c;
  }

  void _applyOutstanding(String encoded) {
    // stored as "customerId=amount=days;..."
    for (final part in encoded.split(';')) {
      final f = part.split('=');
      if (f.length == 3) {
        outstanding[f[0]] = double.tryParse(f[1]) ?? 0;
        oldestDueDays[f[0]] = int.tryParse(f[2]) ?? 0;
      }
    }
  }

  String unitCode(String unitId) => (units[unitId]?['code'] ?? '') as String;

  String? levelIdByCode(String code) {
    for (final e in priceLevels.entries) {
      if (e.value['code'] == code) return e.key;
    }
    return null;
  }

  String levelName(String levelId) => (priceLevels[levelId]?['name'] ?? '') as String;

  /// Units an item can be sold in at the counter: base unit first.
  List<(String unitId, double factor)> packsFor(Item item) {
    final out = <(String, double)>[(item.baseUnitId, 1)];
    for (final p in _packs) {
      if (p['item_id'] == item.id && p['unit_id'] != item.baseUnitId) {
        out.add((p['unit_id'] as String, _num(p['factor'])));
      }
    }
    return out;
  }

  /// Price in force today for item + unit + level; a location-specific row
  /// beats the all-locations row; the latest valid_from wins.
  double? price(String itemId, String unitId, String levelId, {DateTime? on}) {
    final day = (on ?? DateTime.now()).toIso8601String().substring(0, 10);
    Map<String, dynamic>? best;
    for (final p in _prices) {
      if (p['item_id'] != itemId || p['unit_id'] != unitId || p['price_level_id'] != levelId) continue;
      final from = (p['valid_from'] as String).substring(0, 10);
      if (from.compareTo(day) > 0) continue;
      if (best == null) {
        best = p;
        continue;
      }
      final bLoc = best['location_id'] != null, pLoc = p['location_id'] != null;
      final bFrom = (best['valid_from'] as String).substring(0, 10);
      if ((pLoc && !bLoc) || (pLoc == bLoc && from.compareTo(bFrom) > 0)) best = p;
    }
    return best == null ? null : _num(best['price']);
  }

  /// Price level for a customer: own level, else the category default.
  String levelForCustomer(Customer? c, String outletDefaultLevelId) {
    if (c == null) return outletDefaultLevelId;
    if (c.priceLevelId != null) return c.priceLevelId!;
    return (customerCategories[c.categoryId]?['default_price_level_id'] as String?) ?? outletDefaultLevelId;
  }

  bool creditAllowed(Customer c) => customerCategories[c.categoryId]?['credit_allowed'] != false;

  /// Customer limit valid today overrides the category limit.
  CreditRule creditRule(Customer c) {
    final day = DateTime.now().toIso8601String().substring(0, 10);
    bool valid(Map<String, dynamic> l) {
      final from = (l['valid_from'] as String).substring(0, 10);
      final to = l['valid_to'] == null ? null : (l['valid_to'] as String).substring(0, 10);
      return from.compareTo(day) <= 0 && (to == null || to.compareTo(day) >= 0);
    }

    Map<String, dynamic>? pick(bool Function(Map<String, dynamic>) f) {
      final list = _limits.where((l) => f(l) && valid(l)).toList()
        ..sort((a, b) => (b['valid_from'] as String).compareTo(a['valid_from'] as String));
      return list.isEmpty ? null : list.first;
    }

    final own = pick((l) => l['customer_id'] == c.id);
    final cat = pick((l) => l['customer_category_id'] == c.categoryId);
    final l = own ?? cat;
    if (l == null) return CreditRule(source: 'none');
    return CreditRule(
      maxOutstanding: l['max_outstanding'] == null ? null : _num(l['max_outstanding']),
      maxDays: (l['max_days'] as num?)?.toInt(),
      capToSecurity: l['cap_to_security'] == true,
      source: own != null ? 'customer' : 'category',
    );
  }
}
