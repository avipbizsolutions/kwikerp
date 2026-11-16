import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_version.dart';
import '../core/pos_state.dart';
import 'theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await context.read<PosState>().login(_phone.text, _pin.text);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 440,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('KwikERP', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Kc.navy)),
                const SizedBox(height: 4),
                const Text('Log in to start billing', style: TextStyle(color: Kc.muted)),
                if (context.watch<PosState>().logoutReason != null) ...[
                  const SizedBox(height: 10),
                  Text('Logged out: ${context.watch<PosState>().logoutReason}',
                      style: const TextStyle(color: Kc.red, fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Mobile number'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: 'PIN', counterText: ''),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _busy ? null : _login, child: Text(_busy ? 'Logging in…' : 'Log in')),
                const SizedBox(height: 8),
                const Text('The first login needs internet.', style: TextStyle(color: Kc.muted, fontSize: 13)),
                const SizedBox(height: 4),
                Text('Server ${context.read<PosState>().serverUrl ?? ''} · $appVersionLabel',
                    style: const TextStyle(color: Kc.muted, fontSize: 12)),
                TextButton(
                  onPressed: () => context.read<PosState>().resetSetup(),
                  child: const Text('Change server or tablet code'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
