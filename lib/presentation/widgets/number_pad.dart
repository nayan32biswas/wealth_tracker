import 'package:flutter/material.dart';

import '../../domain/services/money.dart';

const backspaceKey = '⌫';

/// Applies one number-pad key to the typed amount text.
String padInput(String text, String key, {required int decimals}) {
  if (key == backspaceKey) return text.isEmpty ? text : text.substring(0, text.length - 1);
  if (key == '.') {
    if (decimals == 0 || text.contains('.')) return text;
    return text.isEmpty ? '0.' : '$text.';
  }
  return key.split('').fold(text, (t, digit) => _addDigit(t, digit, decimals));
}

String _addDigit(String text, String digit, int decimals) {
  final dot = text.indexOf('.');
  if (dot >= 0) return text.length - dot - 1 >= decimals ? text : '$text$digit';
  if (text.isEmpty || text == '0') return digit == '0' ? '' : digit;
  return text.length >= maxWholeDigits ? text : '$text$digit';
}

const signKey = '±';
const calculatorKey = 'calc';
const doneKey = 'done';

class NumberPad extends StatelessWidget {
  const NumberPad({
    super.key,
    required this.onKey,
    required this.onDone,
    required this.onCalculator,
    this.allowNegative = false,
  });

  final ValueChanged<String> onKey;
  final VoidCallback onDone;
  final VoidCallback onCalculator;

  /// Without it +/- stays in place but greyed out, so no key ever moves.
  final bool allowNegative;

  static const _rows = [
    ['1', '2', '3', signKey],
    ['4', '5', '6', calculatorKey],
    ['7', '8', '9', backspaceKey],
    ['00', '0', '.', doneKey],
  ];

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            for (final row in _rows)
              Row(spacing: 8, children: [for (final key in row) Expanded(child: _key(context, key))]),
          ],
        ),
      ),
    ),
  );

  Widget _key(BuildContext context, String key) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final action = !RegExp(r'^[\d.]+$').hasMatch(key);
    final enabled = key != signKey || allowNegative;
    final foreground = !enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : (action ? colors.onSecondaryContainer : colors.onSurface);
    Text text(String label) => Text(label, style: theme.textTheme.titleLarge?.copyWith(color: foreground));
    final (VoidCallback onTap, Widget label, String? tooltip) = switch (key) {
      signKey => (() => onKey(key), text('+/-'), null),
      calculatorKey => (onCalculator, Icon(Icons.calculate_outlined, color: foreground), 'Calculator'),
      backspaceKey => (() => onKey(key), Icon(Icons.backspace_outlined, color: foreground), 'Backspace'),
      doneKey => (onDone, Icon(Icons.check, color: foreground), 'Done'),
      _ => (() => onKey(key), text(key), null),
    };
    final button = SizedBox(
      height: 48,
      child: Material(
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        color: !enabled
            ? colors.onSurface.withValues(alpha: 0.08)
            : (action ? colors.secondaryContainer : colors.surfaceContainerHighest),
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Center(child: label),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
