import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/pos_state.dart';
import 'theme.dart';

/// One-time tablet setup, done by head office when installing the tablet.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _url = TextEditingController(text: 'https://api.kwikerp.cloud/api');
  final _tenant = TextEditingController(text: 'TROIKA');
  final _device = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 520,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Set up this tablet', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Head office does this once. The tablet code is the outlet code and tablet number, e.g. DD3-T1.',
                    style: TextStyle(color: Kc.muted)),
                const SizedBox(height: 20),
                TextField(controller: _url, decoration: const InputDecoration(labelText: 'Server address (ends with /api)')),
                const SizedBox(height: 12),
                TextField(controller: _tenant, decoration: const InputDecoration(labelText: 'Company code')),
                const SizedBox(height: 12),
                TextField(controller: _device, decoration: const InputDecoration(labelText: 'Tablet code (e.g. DD3-T1)')),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    if (_url.text.length < 12 || _tenant.text.isEmpty || _device.text.trim().length < 4) {
                      showError(context, 'Fill in all three fields');
                      return;
                    }
                    context.read<PosState>().saveSetup(_url.text, _tenant.text, _device.text);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
