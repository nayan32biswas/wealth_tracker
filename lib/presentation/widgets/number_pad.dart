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

class NumberPad extends StatelessWidget {
  const NumberPad({super.key, required this.onKey, required this.onDone, this.allowNegative = false});

  final ValueChanged<String> onKey;
  final VoidCallback onDone;
  final bool allowNegative;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['00', '0', '.'],
  ];

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in _rows)
                Row(
                  children: [
                    for (final key in row)
                      Expanded(
                        child: TextButton(
                          onPressed: () => onKey(key),
                          child: Text(key, style: style),
                        ),
                      ),
                  ],
                ),
              Row(
                // Same three columns as the digits, so each key stays put
                // whether or not +/- is shown.
                children: [
                  Expanded(
                    child: allowNegative
                        ? TextButton(
                            onPressed: () => onKey(signKey),
                            child: Text('+/-', style: style),
                          )
                        : const SizedBox(),
                  ),
                  Expanded(
                    child: IconButton(
                      tooltip: 'Backspace',
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: () => onKey(backspaceKey),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: FilledButton(onPressed: onDone, child: const Text('Done')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
