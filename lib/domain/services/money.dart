import '../models/app_settings.dart';
import '../models/categories.dart';
import '../models/enums.dart';

/// Keeps every amount far inside a 64-bit integer.
const maxWholeDigits = 12;

class MoneyFormat {
  const MoneyFormat({required this.symbol, required this.decimals});

  MoneyFormat.of(AppSettings settings) : this(symbol: settings.currencySymbol, decimals: settings.decimals);

  final String symbol;
  final int decimals;

  int get _scale {
    var s = 1;
    for (var i = 0; i < decimals; i++) {
      s *= 10;
    }
    return s;
  }

  String format(int minor, {bool withSymbol = true}) {
    final abs = minor.abs();
    final whole = _group('${abs ~/ _scale}');
    final fraction = decimals == 0 ? '' : '.${'${abs % _scale}'.padLeft(decimals, '0')}';
    return '${minor < 0 ? '-' : ''}${withSymbol ? symbol : ''}$whole$fraction';
  }

  /// Fixed decimals, no symbol or grouping: the form used in CSV files.
  String plain(int minor) => format(minor, withSymbol: false).replaceAll(',', '');

  /// Plain text for editing: no symbol, no grouping, no trailing zeros.
  String editText(int minor) {
    if (minor == 0) return '';
    final text = format(minor, withSymbol: false).replaceAll(',', '');
    return decimals == 0 ? text : text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// Commas are only allowed as thousands separators (1,234 or Indian
  /// 1,00,000), so a decimal comma like "12,50" is rejected, never read as 1250.
  int? parse(String input) {
    final match = RegExp(r'^(\d*|\d{1,3}(?:,\d{2,3})*,\d{3})(?:\.(\d*))?$').firstMatch(input.trim());
    if (match == null) return null;
    final whole = match.group(1)!.replaceAll(',', '');
    if (whole.length > maxWholeDigits) return null;
    final fraction = match.group(2) ?? '';
    if (whole.isEmpty && fraction.isEmpty) return null;
    if (fraction.length > decimals) return null;
    return int.parse(whole.isEmpty ? '0' : whole) * _scale + int.parse(fraction.padRight(decimals, '0').ifEmpty('0'));
  }

  static String _group(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// The fee a category suggests for [amount]. The user can still change it
/// on each transaction. Percent fees round half up to the smallest unit.
int defaultFee(Category? category, int amount) => switch (category?.feeType) {
  FeeType.percent => (amount * category!.feeValue + 5000) ~/ 10000,
  FeeType.fixed => category!.feeValue,
  FeeType.none || null => 0,
};
