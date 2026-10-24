import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/categories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/services/money.dart';

void main() {
  group('MoneyFormat', () {
    const taka = MoneyFormat(symbol: '৳', decimals: 2);

    test('formats minor units with grouping and symbol', () {
      expect(taka.format(65000), '৳650.00');
      expect(taka.format(123456789), '৳1,234,567.89');
      expect(taka.format(5), '৳0.05');
      expect(taka.format(-203000), '-৳2,030.00');
    });

    test('can leave out the symbol', () {
      expect(taka.format(150050, withSymbol: false), '1,500.50');
      expect(taka.plain(150050), '1500.50');
    });

    test('supports currencies without decimals', () {
      const yen = MoneyFormat(symbol: '¥', decimals: 0);
      expect(yen.format(1500), '¥1,500');
      expect(yen.parse('1500'), 1500);
    });

    test('parses typed amounts into minor units', () {
      expect(taka.parse('650'), 65000);
      expect(taka.parse('650.5'), 65050);
      expect(taka.parse('0.05'), 5);
      expect(taka.parse('1,234.56'), 123456);
      expect(taka.parse('.5'), 50);
    });

    test('a comma is only accepted as a thousands separator', () {
      expect(taka.parse('1,234,567.89'), 123456789);
      expect(taka.parse('1,00,000'), 10000000);
      expect(taka.parse('12,50'), isNull);
      expect(taka.parse('1,5'), isNull);
      expect(taka.parse('1,2345'), isNull);
    });

    test('amounts longer than 12 whole digits are rejected, not crashed on', () {
      expect(taka.parse('9' * 12), 99999999999900);
      expect(taka.parse('9' * 13), isNull);
      expect(taka.parse('9' * 25), isNull);
    });

    test('rejects text that is not an amount', () {
      expect(taka.parse(''), isNull);
      expect(taka.parse('abc'), isNull);
      expect(taka.parse('1.234'), isNull);
      expect(taka.parse('1.2.3'), isNull);
      expect(taka.parse('-5'), isNull);
    });

    test('edit text drops trailing zeros for the number pad', () {
      expect(taka.editText(65000), '650');
      expect(taka.editText(65050), '650.5');
      expect(taka.editText(5), '0.05');
      expect(taka.editText(0), '');
    });
  });

  group('FeeCalculator', () {
    Category category(FeeType type, int value) =>
        Category(id: 1, name: 'x', type: CategoryType.expense, feeType: type, feeValue: value);

    test('no category or no fee means zero', () {
      expect(defaultFee(null, 10000), 0);
      expect(defaultFee(category(FeeType.none, 500), 10000), 0);
    });

    test('fixed fee ignores the amount', () {
      expect(defaultFee(category(FeeType.fixed, 1000), 123), 1000);
    });

    test('percent fee uses basis points', () {
      expect(defaultFee(category(FeeType.percent, 185), 100000), 1850);
    });

    test('percent fee rounds half up to the smallest unit', () {
      expect(defaultFee(category(FeeType.percent, 150), 100), 2);
      expect(defaultFee(category(FeeType.percent, 149), 100), 1);
      expect(defaultFee(category(FeeType.percent, 185), 1), 0);
    });
  });
}
