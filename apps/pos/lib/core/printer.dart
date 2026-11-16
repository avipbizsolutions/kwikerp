import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'escpos.dart';
import 'local_db.dart';

class PairedPrinter {
  PairedPrinter(this.name, this.mac);
  final String name;
  final String mac;
}

/// The counter's Bluetooth receipt printer. The printer must first be paired
/// in Android's Bluetooth settings; here the cashier only picks it from the list.
class PrinterService extends ChangeNotifier {
  PrinterService(this.db);
  final LocalDb db;

  String? mac;
  String? name;
  int columns = 48; // 80 mm paper; 32 for 58 mm
  bool autoPrint = true;
  bool autoKot = false; // KOT for the service team with every bill
  String? lastReceipt;
  String? lastError;
  bool busy = false;

  bool get configured => mac != null;

  Future<void> load() async {
    mac = await db.get('printer_mac');
    name = await db.get('printer_name');
    columns = int.tryParse(await db.get('printer_columns') ?? '') ?? 48;
    autoPrint = (await db.get('printer_auto') ?? '1') == '1';
    autoKot = (await db.get('printer_kot') ?? '0') == '1';
    notifyListeners();
  }

  Future<void> save(
      {required String? mac, required String? name, required int columns, required bool autoPrint, bool? autoKot}) async {
    if (mac != this.mac) await _disconnect();
    this.mac = mac;
    this.name = name;
    this.columns = columns;
    this.autoPrint = autoPrint;
    if (autoKot != null) this.autoKot = autoKot;
    await db.set('printer_mac', mac);
    await db.set('printer_name', name);
    await db.set('printer_columns', '$columns');
    await db.set('printer_auto', autoPrint ? '1' : '0');
    await db.set('printer_kot', this.autoKot ? '1' : '0');
    notifyListeners();
  }

  /// Android 12+ asks the cashier once for "Nearby devices".
  Future<bool> _permission() async {
    if (await PrintBluetoothThermal.isPermissionBluetoothGranted) return true;
    final r = await Permission.bluetoothConnect.request();
    return r.isGranted || await PrintBluetoothThermal.isPermissionBluetoothGranted;
  }

  Future<List<PairedPrinter>> paired() async {
    if (!await _permission()) throw PrinterException('Allow "Nearby devices" for KwikERP POS in Android settings.');
    if (!await PrintBluetoothThermal.bluetoothEnabled) throw PrinterException('Bluetooth is off. Turn it on and try again.');
    final list = await PrintBluetoothThermal.pairedBluetooths;
    return [for (final b in list) PairedPrinter(b.name, b.macAdress)];
  }

  Future<void> _disconnect() async {
    try {
      if (await PrintBluetoothThermal.connectionStatus) await PrintBluetoothThermal.disconnect;
    } catch (_) {}
  }

  /// Prints and remembers the text for "Reprint last bill".
  /// Returns null on success, or a message the cashier can act on.
  Future<String?> print(String receipt, {bool remember = true}) async {
    if (remember) lastReceipt = receipt;
    if (mac == null) return 'No printer chosen. Menu > Printer.';
    if (busy) return 'Printer busy, try again.';
    busy = true;
    notifyListeners();
    try {
      if (!await _permission()) return 'Allow "Nearby devices" for KwikERP POS in Android settings.';
      if (!await PrintBluetoothThermal.bluetoothEnabled) return 'Bluetooth is off.';
      if (!await PrintBluetoothThermal.connectionStatus) {
        // A sleeping printer often needs a second try.
        var ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac!);
        if (!ok) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac!);
        }
        if (!ok) return 'Printer not reachable. Is it switched on and near the tablet?';
      }
      final ok = await PrintBluetoothThermal.writeBytes(EscPos.encode(receipt));
      if (!ok) {
        await _disconnect();
        return 'Printing failed. Check paper and try again.';
      }
      return null;
    } catch (e) {
      await _disconnect();
      return 'Printing failed: $e';
    } finally {
      busy = false;
      lastError = null;
      notifyListeners();
    }
  }
}

class PrinterException implements Exception {
  PrinterException(this.message);
  final String message;
  @override
  String toString() => message;
}
