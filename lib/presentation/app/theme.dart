import 'package:flutter/material.dart';

const _seed = Color(0xFF3D6B73);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
  return ThemeData(
    colorScheme: scheme,
    // Phones are short on height: tighter rows and spacing everywhere.
    // Tap targets keep their 48 px minimum.
    visualDensity: VisualDensity.compact,
    // Material's default sizes read large on a phone: every text style is
    // 10% smaller. The phone's own text size setting still applies on top.
    textTheme: _smallerText,
    primaryTextTheme: _smallerText,
    // Compact density draws buttons only 32 px tall, which looks cramped on a
    // real phone. Every button keeps Material's standard 40 px; the main
    // action at the bottom of a screen is 48 (see BottomActionButton).
    filledButtonTheme: const FilledButtonThemeData(style: _standardButton),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: _standardButton),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: _standardButton),
    textButtonTheme: const TextButtonThemeData(style: _standardButton),
    segmentedButtonTheme: const SegmentedButtonThemeData(style: _standardButton),
    navigationBarTheme: const NavigationBarThemeData(height: 64),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}

const _standardButton = ButtonStyle(visualDensity: VisualDensity.standard);

final _smallerText = Typography.englishLike2021.apply(fontSizeFactor: 0.9);

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
