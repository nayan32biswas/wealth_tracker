import 'package:flutter/material.dart';

import '../../domain/services/money.dart';
import 'number_pad.dart';

const clearKey = 'C';
const percentKey = '%';
const operatorKeys = ['÷', '×', '−', '+'];

final _operator = RegExp('[${operatorKeys.join()}]');

/// Applies one calculator key to the typed sum, such as "750×3+10%".
/// Digits and the point go to the last number through [padInput].
String calcInput(String text, String key, {required int decimals}) {
  if (key == clearKey) return '';
  if (key == backspaceKey) return text.isEmpty ? text : text.substring(0, text.length - 1);
  final last = text.isEmpty ? '' : text[text.length - 1];
  if (operatorKeys.contains(key)) {
    // Only "−" may start a sum, so it can be negative.
    if (text.isEmpty || text == '−') return key == '−' ? '−' : text;
    return operatorKeys.contains(last) ? '${text.substring(0, text.length - 1)}$key' : '$text$key';
  }
  if (key == percentKey) return RegExp(r'[\d.]').hasMatch(last) ? '$text%' : text;
  if (last == percentKey) return text;
  final start = text.lastIndexOf(_operator) + 1;
  // The amount pad drops a leading 0, but after an operator it is a real
  // number: 5×0 is 0.
  if (start > 0 && start == text.length && (key == '0' || key == '00')) return '${text}0';
  return text.substring(0, start) + padInput(text.substring(start), key, decimals: decimals);
}

/// Works out a typed sum in the smallest unit, × and ÷ before + and −, so
/// "10+2×3" is 16. A percent after + or − is of everything before it, so
/// "200+10%" is 220; anywhere else it is just divided by 100. The sum is kept
/// exact and rounded half up once at the end, like percent fees, so 100÷3×3
/// is 100. A trailing operator is ignored. On an error the value is 0.
({int value, String? error}) evaluateSum(String text, MoneyFormat money) {
  final tokens = [for (final m in _token.allMatches(text)) m[0]!];
  if (tokens.isNotEmpty && operatorKeys.contains(tokens.last)) tokens.removeLast();
  final first = tokens.isNotEmpty && tokens.first == '−' ? 1 : 0;
  final scale = BigInt.from(money.parse('1')!);
  final hundred = BigInt.from(100);
  var total = _Fraction.zero;
  var term = _Fraction.zero;
  // Terms stay positive with the sign kept apart.
  var negative = first == 1;
  for (var i = first; i < tokens.length; i += 2) {
    final percent = tokens[i].endsWith(percentKey);
    final n = BigInt.from(money.parse(tokens[i].replaceAll(percentKey, '')) ?? 0);
    final unit = percent ? scale * hundred : scale;
    switch (i == first ? null : tokens[i - 1]) {
      case '×':
        term = term.times(n, unit);
      case '÷':
        if (n == BigInt.zero) return (value: 0, error: "Can't divide by 0");
        term = term.times(unit, n);
      case null:
        term = _Fraction(n, percent ? hundred : BigInt.one);
      case final op:
        total = total.plus(term, negative: negative);
        negative = op == '−';
        if (percent && total.top.isNegative) negative = !negative;
        term = percent ? _Fraction(total.top.abs(), total.bottom).times(n, unit) : _Fraction(n, BigInt.one);
    }
  }
  total = total.plus(term, negative: negative);
  final rounded = (total.top.abs() * BigInt.two + total.bottom) ~/ (total.bottom * BigInt.two);
  if (rounded >= BigInt.from(10).pow(maxWholeDigits) * scale) return (value: 0, error: 'Too large');
  return (value: (total.top.isNegative ? -rounded : rounded).toInt(), error: null);
}

final _token = RegExp('${_operator.pattern}|[^${operatorKeys.join()}]+');

class _Fraction {
  factory _Fraction(BigInt top, BigInt bottom) {
    final g = top.gcd(bottom);
    return _Fraction._(top ~/ g, bottom ~/ g);
  }

  const _Fraction._(this.top, this.bottom);

  static final zero = _Fraction._(BigInt.zero, BigInt.one);

  final BigInt top;
  final BigInt bottom;

  _Fraction times(BigInt top, BigInt bottom) => _Fraction(this.top * top, this.bottom * bottom);

  _Fraction plus(_Fraction other, {required bool negative}) =>
      _Fraction(top * other.bottom + (negative ? -other.top : other.top) * bottom, bottom * other.bottom);
}

/// Opens the calculator on [start], in the smallest unit. Returns the result,
/// or null when it is closed without Done.
Future<int?> openCalculator(
  BuildContext context, {
  required int start,
  required MoneyFormat money,
  required bool allowNegative,
}) => Navigator.push<int>(
  context,
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => CalculatorScreen(start: start, money: money, allowNegative: allowNegative),
  ),
);

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key, required this.start, required this.money, required this.allowNegative});

  final int start;
  final MoneyFormat money;
  final bool allowNegative;

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  late String _text = '${widget.start < 0 ? '−' : ''}${widget.money.editText(widget.start.abs())}';

  static const _rows = [
    [clearKey, backspaceKey, percentKey, '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '−'],
    ['1', '2', '3', '+'],
    ['00', '0', '.', 'Done'],
  ];

  ({int value, String? error}) get _result {
    final r = evaluateSum(_text, widget.money);
    if (r.error == null && r.value < 0 && !widget.allowNegative) return (value: 0, error: "Can't be negative");
    return r;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final result = _result;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Keys fit the width and at most 60% of the height, so a short or
            // landscape screen still shows every key.
            final size = [
              (constraints.maxWidth - 32 - 3 * 16) / 4,
              (constraints.maxHeight * 0.6 - 16 - 4 * 12) / 5,
              80.0,
            ].reduce((a, b) => a < b ? a : b);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.bottomRight,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              children: [
                                Text(_text, style: theme.textTheme.displayMedium),
                                Container(
                                  width: 3,
                                  height: 56,
                                  margin: const EdgeInsets.only(left: 2),
                                  color: colors.primary,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            result.error ?? widget.money.format(result.value),
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: result.error == null ? colors.onSurfaceVariant : colors.error,
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
                Align(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 440),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      spacing: 12,
                      children: [
                        for (final row in _rows)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [for (final key in row) _key(key, size, result.error == null)],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _key(String key, double size, bool canFinish) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final done = key == 'Done';
    final operator = operatorKeys.contains(key) || key == percentKey;
    final red = key == clearKey || key == backspaceKey;
    final foreground = done ? colors.onPrimary : (red ? colors.error : colors.onSurface);
    final onTap = done
        ? (canFinish ? () => Navigator.pop(context, _result.value) : null)
        : () => setState(() => _text = calcInput(_text, key, decimals: widget.money.decimals));
    return SizedBox.square(
      dimension: size,
      child: Material(
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        color: done
            ? (canFinish ? colors.primary : colors.onSurface.withValues(alpha: 0.12))
            : (operator ? colors.surfaceContainerHighest : colors.surfaceContainerHigh),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(size * 0.2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: key == backspaceKey
                  ? Icon(Icons.backspace_outlined, color: foreground, semanticLabel: 'Backspace')
                  : Text(
                      key,
                      style: (done ? theme.textTheme.titleMedium : theme.textTheme.headlineMedium)?.copyWith(
                        color: done && !canFinish ? colors.onSurface.withValues(alpha: 0.38) : foreground,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
