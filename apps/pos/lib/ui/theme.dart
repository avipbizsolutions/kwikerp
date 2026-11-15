import 'package:flutter/material.dart';

class Kc {
  static const navy = Color(0xFF12355B);
  static const blue = Color(0xFF1E5AA8);
  static const blueTint = Color(0xFFE8F0FA);
  static const ground = Color(0xFFEEF1F4);
  static const ink = Color(0xFF17202A);
  static const muted = Color(0xFF4A5868);
  static const line = Color(0xFFC5CDD6);
  static const amberBg = Color(0xFFFFF4E0);
  static const amberInk = Color(0xFF7A4B00);
  static const greenBg = Color(0xFFE6F4EC);
  static const greenInk = Color(0xFF1F5C39);
  static const red = Color(0xFF8A1C1C);

  static Color hex(String? h, {Color fallback = const Color(0xFFF0EEE8)}) {
    if (h == null || !h.startsWith('#') || h.length != 7) return fallback;
    return Color(int.parse('FF${h.substring(1)}', radix: 16));
  }
}

ThemeData kwikTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Kc.blue, primary: Kc.blue, surface: Colors.white),
    scaffoldBackgroundColor: Kc.ground,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Kc.ink, displayColor: Kc.ink),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 52),
        foregroundColor: Kc.ink,
        side: const BorderSide(color: Kc.line),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
  );
}

/// Shows an error message at the bottom of the screen.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Kc.red),
  );
}
