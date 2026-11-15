import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Offline credit approval, matching apps/api/src/offline-code.ts.
///
/// The tablet shows a request code; the manager's app turns request code +
/// bill amount into a 6-digit code with this tablet's key; the tablet checks it
/// here without internet.
class OfflineCode {
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I

  static String newRequestCode() {
    final r = Random.secure();
    return List.generate(4, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
  }

  static String approvalCode(String deviceKeyHex, String requestCode, num amountRupees) {
    final key = _hexToBytes(deviceKeyHex);
    final msg = '${requestCode.trim().toUpperCase()}|${amountRupees.round()}';
    final digest = Hmac(sha256, key).convert(msg.codeUnits).bytes;
    final n = ByteData.sublistView(Uint8List.fromList(digest)).getUint32(0) % 1000000;
    return n.toString().padLeft(6, '0');
  }

  static bool check(String deviceKeyHex, String requestCode, num amountRupees, String entered) {
    final clean = entered.replaceAll(RegExp(r'\D'), '');
    return clean.length == 6 && clean == approvalCode(deviceKeyHex, requestCode, amountRupees);
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}
