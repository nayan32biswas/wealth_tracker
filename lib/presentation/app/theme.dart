import 'package:flutter/material.dart';

const _seed = Color(0xFF3D6B73);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
  return ThemeData(
    colorScheme: scheme,
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}

extension MoneyColors on ColorScheme {
  Color get income => const Color(0xFF81C784);

  Color get expense => error;
}

/// Chart series colors, checked for colour-blind separation and contrast on
/// the dark surface. Slot 1 is income, slot 2 is expense wherever they appear.
extension ChartColors on ColorScheme {
  Color get series1 => const Color(0xFF3987E5);

  Color get series2 => const Color(0xFFD95926);
}
