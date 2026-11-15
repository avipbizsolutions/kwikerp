/// Minimal ESC/POS encoder for 58 mm (32 column) and 80 mm (48 column)
/// thermal printers. Plain bytes, no package, so it is easy to test.
///
/// Receipt text is prepared by [receiptText] in plain ASCII. Lines that start
/// with a marker get formatting:
///   `^C` centred, `^B` bold, `^W` bold + double height (shop name, total).
class EscPos {
  static const _esc = 0x1B, _gs = 0x1D;

  static List<int> encode(String text, {int feedLines = 4, bool cut = true}) {
    final out = <int>[_esc, 0x40]; // initialise
    for (final raw in text.split('\n')) {
      var line = raw;
      var center = false, bold = false, big = false;
      while (line.startsWith('^') && line.length >= 2) {
        switch (line[1]) {
          case 'C':
            center = true;
          case 'B':
            bold = true;
          case 'W':
            bold = true;
            big = true;
        }
        line = line.substring(2);
      }
      out.addAll([_esc, 0x61, center ? 1 : 0]); // align
      out.addAll([_esc, 0x45, bold ? 1 : 0]); // bold
      out.addAll([_gs, 0x21, big ? 0x01 : 0x00]); // double height
      out.addAll(ascii(line).codeUnits);
      out.add(0x0A);
    }
    out.addAll([_esc, 0x61, 0, _esc, 0x45, 0, _gs, 0x21, 0]);
    out.addAll([_esc, 0x64, feedLines]); // feed so the receipt clears the tear bar
    if (cut) out.addAll([_gs, 0x56, 0x42, 0x00]); // partial cut; ignored by printers without a cutter
    return out;
  }

  /// Printers use a single-byte code page, so anything outside ASCII is replaced.
  static String ascii(String s) => s
      .replaceAll('₹', 'Rs')
      .replaceAll('−', '-')
      .replaceAll('–', '-')
      .replaceAll('·', '-')
      .replaceAll('×', 'x')
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
}
