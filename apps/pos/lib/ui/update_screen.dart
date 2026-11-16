import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_version.dart';
import '../core/pos_state.dart';
import 'theme.dart';

/// Shown instead of billing when the server has a newer app. Billing comes
/// back only after the new version is installed.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  String? _note;

  Future<void> _download() async {
    final s = context.read<PosState>();
    await s.sync?.syncNow(); // send bills first, so nothing waits on the old app
    final ok = await launchUrl(Uri.parse(s.updateUrl), mode: LaunchMode.externalApplication);
    if (mounted) {
      setState(() => _note = ok
          ? 'Downloading. When it finishes, tap the downloaded file and choose Update.'
          : 'Could not open the browser. Open ${s.updateUrl} in Chrome.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PosState>();
    final sync = s.sync;
    return Scaffold(
      body: Center(
        child: Container(
          width: 500,
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.system_update, size: 56, color: Kc.navy),
            const SizedBox(height: 12),
            const Text('Update required',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Kc.navy)),
            const SizedBox(height: 8),
            Text('A new version of KwikERP POS (build ${s.requiredBuild}) is ready. This tablet has $appVersionLabel. '
                'Billing continues after updating.',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text('Bills, login and settings stay on the tablet. Do not uninstall: choose Update.',
                textAlign: TextAlign.center, style: TextStyle(color: Kc.muted)),
            if (sync != null) ...[
              const SizedBox(height: 14),
              ListenableBuilder(
                listenable: sync,
                builder: (context, _) => Text(
                    sync.pending == 0 ? 'All bills are on the server.' : '${sync.pending} bills still to send; they go first.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: sync.pending == 0 ? Kc.greenInk : Kc.amberInk, fontWeight: FontWeight.w600)),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
                height: 56,
                child: FilledButton.icon(
                    onPressed: _download, icon: const Icon(Icons.download), label: const Text('Download update'))),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(_note!, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 8),
            TextButton(onPressed: s.checkForUpdate, child: const Text('Check again')),
          ]),
        ),
      ),
    );
  }
}
