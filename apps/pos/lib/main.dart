import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/local_db.dart';
import 'core/pos_state.dart';
import 'core/printer.dart';
import 'ui/billing_screen.dart';
import 'ui/login_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/shift_screens.dart';
import 'ui/theme.dart';
import 'ui/update_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Counters keep the tablet upright; sideways also works.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  final db = await LocalDb.open();
  final state = PosState(db);
  await state.init();
  final printer = PrinterService(db);
  await printer.load();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider.value(value: printer),
    ],
    child: const KwikPosApp(),
  ));
}

class KwikPosApp extends StatelessWidget {
  const KwikPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KwikERP POS',
      debugShowCheckedModeBanner: false,
      theme: kwikTheme(),
      home: const _Root(),
    );
  }
}

/// Shows the right screen for where the tablet is in its setup.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    // A newer app on the server must be installed first; a bill being made
    // or on hold is finished before the update screen takes over.
    if (s.updateRequired && !s.billInProgress) return const UpdateScreen();
    if (!s.isSetUp) return const SetupScreen();
    if (!s.isLoggedIn) return const LoginScreen();
    if (!s.hasCatalog) return const FirstSyncScreen();
    if (!s.shiftOpen) return const OpenShiftScreen();
    return const BillingScreen();
  }
}
