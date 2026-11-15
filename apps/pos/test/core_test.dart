import 'package:flutter_test/flutter_test.dart';
import 'package:kwikerp_pos/core/billing.dart';
import 'package:kwikerp_pos/core/offline_code.dart';

void main() {
  test('offline approval code matches the server (apps/api/src/offline-code.ts)', () {
    const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
    // Reference values computed with the API's implementation
    expect(OfflineCode.approvalCode(key, 'k74q', 421), '790428');
    expect(OfflineCode.approvalCode(key, 'K74Q', 421.4), '790428');
    expect(OfflineCode.approvalCode(key, 'ABCD', 1000), '872072');
    expect(OfflineCode.check(key, 'K74Q', 421, '790 428'), isTrue);
    expect(OfflineCode.check(key, 'K74Q', 422, '790428'), isFalse);
  });

  test('financial year code', () {
    expect(finYear(DateTime(2026, 11, 15)), '2627');
    expect(finYear(DateTime(2027, 3, 31)), '2627');
    expect(finYear(DateTime(2027, 4, 1)), '2728');
  });

  test('tax split on tax-inclusive price', () {
    final s = splitTax(105, 5, false);
    expect(s.taxable, 100);
    expect(s.cgst, 2.5);
    expect(s.sgst, 2.5);
    final nil = splitTax(36, 0, false);
    expect(nil.taxable, 36);
    expect(nil.cgst + nil.sgst + nil.igst, 0);
  });

  test('Indian money format', () {
    expect(money(1234567.5), '₹12,34,567.50');
    expect(money(421, paise: false), '₹421');
    expect(money(-60), '−₹60.00');
  });
}
