import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kwikerp_pos/core/billing.dart';
import 'package:kwikerp_pos/core/escpos.dart';
import 'package:kwikerp_pos/core/offline_code.dart';
import 'package:kwikerp_pos/core/pos_state.dart';

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

  test('ESC/POS encoding', () {
    expect(EscPos.ascii('₹12,34,567.50 · −₹60 पनीर'), 'Rs12,34,567.50 - -Rs60 ????');
    final bytes = EscPos.encode('^C^WShop\nPlain', cut: false);
    expect(bytes.sublist(0, 2), [0x1B, 0x40]);
    // centred, bold, double height before "Shop"
    final shop = bytes.indexOf('S'.codeUnitAt(0));
    expect(bytes.sublist(shop - 9, shop), [0x1B, 0x61, 1, 0x1B, 0x45, 1, 0x1D, 0x21, 1]);
    // plain line resets formatting
    final plain = bytes.indexOf('P'.codeUnitAt(0));
    expect(bytes.sublist(plain - 9, plain), [0x1B, 0x61, 0, 0x1B, 0x45, 0, 0x1D, 0x21, 0]);
    expect(bytes.every((b) => b >= 0 && b < 256), isTrue);
  });

  test('server address is cleaned up', () {
    const ok = 'https://api.kwikerp.cloud/api';
    expect(normaliseServerUrl('https://https//api.kwikerp.cloud/api'), ok);
    expect(normaliseServerUrl('https://https://api.kwikerp.cloud/api/'), ok);
    expect(normaliseServerUrl(' api.kwikerp.cloud '), ok);
    expect(normaliseServerUrl('HTTPS://api.kwikerp.cloud'), ok);
    expect(normaliseServerUrl('http://192.168.1.5:3100'), 'http://192.168.1.5:3100/api');
    expect(normaliseServerUrl('httpbin.example.in/api'), 'https://httpbin.example.in/api');
  });

  test('logo prints as a raster image', () {
    final b64 = base64.encode([0xff, 0x00, 0x0f, 0xf0]);
    final bytes = EscPos.encode('^G16,2,$b64\nHi', cut: false);
    final i = bytes.indexOf(0x76);
    expect(bytes.sublist(i - 1, i + 7), [0x1D, 0x76, 0x30, 0x00, 2, 0, 2, 0]);
    expect(bytes.sublist(i + 7, i + 11), [0xff, 0x00, 0x0f, 0xf0]);
    // a broken logo line is skipped, not printed
    expect(String.fromCharCodes(EscPos.encode('^G9,9,xx\nHi', cut: false)).contains('9,9'), isFalse);
  });

  test('top and bottom spacing', () {
    final b = EscPos.encode('^T3\nHi\n^F2', cut: false);
    expect(b.sublist(2, 5), [0x1B, 0x64, 3], reason: 'top feed right after init');
    expect(b.sublist(b.length - 3), [0x1B, 0x64, 2], reason: 'bottom feed at the end');
    final none = EscPos.encode('Hi\n^F0', cut: false);
    expect(none.sublist(none.length - 3).contains(0x64), isFalse);
  });
}
