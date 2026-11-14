import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/categories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/services/money.dart';
import 'package:wealthtracker/presentation/features/transactions/transaction_draft.dart';
import 'package:wealthtracker/presentation/widgets/calculator.dart';
import 'package:wealthtracker/presentation/widgets/number_pad.dart';

void main() {
  group('number pad input', () {
    String type(List<String> keys, {int decimals = 2}) =>
        keys.fold('', (text, key) => padInput(text, key, decimals: decimals));

    test('builds a number from digits', () {
      expect(type(['6', '5', '0']), '650');
    });

    test('allows only one decimal point', () {
      expect(type(['1', '.', '5', '.']), '1.5');
    });

    test('stops at the currency decimal places', () {
      expect(type(['1', '.', '2', '3', '4']), '1.23');
      expect(type(['1', '.', '5'], decimals: 0), '15');
    });

    test('a leading point becomes 0.', () {
      expect(type(['.', '5']), '0.5');
    });

    test('no leading zeros', () {
      expect(type(['0', '0', '7']), '7');
      expect(type(['00']), '');
      expect(type(['0', '.', '0', '5']), '0.05');
    });

    test('double zero key respects the decimal limit', () {
      expect(type(['5', '00']), '500');
      expect(type(['5', '.', '1', '00']), '5.10');
      expect(type(['5', '.', '1', '2', '00']), '5.12');
    });

    test('backspace removes the last character', () {
      expect(type(['1', '2', '.', backspaceKey]), '12');
      expect(type([backspaceKey]), '');
    });

    test('caps very long amounts', () {
      expect(type(List.filled(20, '9')).length, maxWholeDigits);
    });
  });

  group('calculator', () {
    String type(List<String> keys) => keys.fold('', calcInput);
    const money = MoneyFormat(symbol: '', decimals: 2);
    int value(String text) => evaluateSum(text, money).value;

    test('a second operator replaces the first, and only − may start a sum', () {
      expect(type(['+', '1', '2', '+', '×', '3']), '12×3');
      expect(type(['−', '+', '7', '5', '0']), '−750');
    });

    test('each number takes any decimals, one point and the whole-digit cap', () {
      expect(type(['1', '.', '5', '+', '2', '.', '2', '5', '9', '.']), '1.5+2.259');
      expect(type(['5', '+', '.', '5']), '5+0.5');
      expect(type(['1', '+', ...List.filled(20, '9')]), '1+${'9' * maxWholeDigits}');
    });

    test('0 can follow an operator', () {
      expect(type(['5', '×', '0']), '5×0');
      expect(type(['5', '×', '00']), '5×0');
      expect(type(['1', '+', '0', '5']), '1+5');
      expect(type(['0', '5']), '5');
      expect(value('5×0'), 0);
    });

    test('backspace removes an operator too, and C clears', () {
      expect(type(['1', '2', '+', backspaceKey, '3']), '123');
      expect(type(['1', '+', '2', clearKey]), '');
    });

    test('% only follows a number, once, and nothing but an operator follows it', () {
      expect(type([percentKey, '5', '+', percentKey, '1', '0', percentKey, percentKey, '5', '.']), '5+10%');
      expect(type(['5', percentKey, '×', '2']), '5%×2');
    });

    test('works out × and ÷ before + and −', () {
      expect(value('10+2×3'), 1600);
      expect(value('10−4÷2'), 800);
      expect(value('50−80'), -3000);
      expect(value('−750+50'), -70000);
    });

    test('a percent after + or − is of everything before it, anywhere else it is divided by 100', () {
      expect(value('200+10%'), 22000);
      expect(value('200−10%'), 18000);
      expect(value('750×3+10%'), 247500);
      expect(value('200×10%'), 2000);
      expect(value('50%'), 50);
      expect(value('−100+10%'), -11000);
    });

    test('rounds once at the end, not after each step', () {
      expect(value('100÷3×3'), 10000);
      expect(value('1÷3×3'), 100);
      expect(value('100÷3+100÷3+100÷3'), 10000);
      expect(evaluateSum('10÷4×4', const MoneyFormat(symbol: '', decimals: 0)).value, 10);
    });

    test('× and ÷ round half up to the smallest unit', () {
      expect(value('10÷3'), 333);
      expect(value('2÷3'), 67);
      expect(value('1.25×0.5'), 63);
      expect(value('10−3÷0.08'), -2750);
    });

    test('works with any decimals and rounds only the result to the currency', () {
      expect(value('1.005×2'), 201);
      expect(value('0.125×8'), 100);
      expect(value('1.23456'), 123);
      expect(value('0.333+0.333+0.334'), 100);
      expect(value('100×12.5%'), 1250);
      expect(value('3.'), 300);
      const rupees = MoneyFormat(symbol: '', decimals: 0);
      expect(calcInput('2', '.'), '2.');
      expect(evaluateSum('2.5×4', rupees).value, 10);
      expect(evaluateSum('0.5', rupees).value, 1);
    });

    test('a trailing operator is ignored', () {
      expect(value('120+'), 12000);
      expect(value(''), 0);
    });

    test('dividing by 0 or a huge result is an error', () {
      expect(evaluateSum('5÷0.0', money), (value: 0, error: "Can't divide by 0"));
      expect(evaluateSum('${'9' * maxWholeDigits}×10', money), (value: 0, error: 'Too large'));
    });
  });

  group('transaction draft', () {
    const food = Category(id: 3, name: 'Food', type: CategoryType.expense);
    final now = DateTime(2026, 9, 23, 10);

    TransactionDraft draft() => TransactionDraft.create(TransactionType.expense, now, assetId: 10);

    test('a repeating entry keeps its rule while it stays on its day', () {
      final entry = Transaction(
        id: 5,
        type: TransactionType.expense,
        amount: 100,
        assetId: 10,
        categoryId: 3,
        dateTime: DateTime(2026, 9, 1, 9),
        recurringRuleId: 7,
      );

      final sameDay = TransactionDraft.edit(entry).withDateTime(DateTime(2026, 9, 1, 18));
      final otherDay = TransactionDraft.edit(entry).withDateTime(DateTime(2026, 9, 3, 9));

      expect(sameDay.toTransaction().recurringRuleId, 7);
      expect(otherDay.toTransaction().recurringRuleId, isNull);
    });

    test('a ticked fee needs an amount and a category; unticked, nothing is saved', () {
      final base = draft().withCategory(food).withAmount(100);
      final ticked = base.withHasFee(true);

      expect(ticked.problem, 'Enter the fee, or untick Add a fee or tax');
      expect(ticked.withFee(5).problem, 'Choose a category for the fee');
      final fee = ticked.withFee(5).withFeeCategory(9).toFee()!;
      expect((fee.amount, fee.categoryId), (5, 9));
      final unticked = ticked.withFee(5).withFeeCategory(9).withHasFee(false);
      expect(unticked.problem, isNull);
      expect(unticked.toFee(), isNull);
      // Ticking again brings back what was typed.
      expect(unticked.withHasFee(true).toFee()?.amount, 5);
    });

    test('editing an entry starts with its fee', () {
      final entry = Transaction(
        id: 5,
        type: TransactionType.income,
        amount: 100,
        assetId: 10,
        categoryId: 2,
        dateTime: now,
      );
      final fee = const Fee(amount: 7, categoryId: 9).entryFor(entry, id: 6);

      final d = TransactionDraft.edit(entry, fee: fee);
      expect((d.hasFee, d.fee, d.feeCategoryId), (true, 7, 9));
      expect(TransactionDraft.edit(entry).hasFee, isFalse);
    });

    test('needs an account and a category; the amount may be 0', () {
      expect(draft().problem, 'Choose a category');
      expect(draft().withCategory(food).problem, isNull);
      expect(draft().withAmount(100).problem, 'Choose a category');
      expect(draft().withAmount(100).withCategory(food).problem, isNull);
      expect(draft().withAmount(100).withCategory(food).withAccount(null).problem, 'Choose an account');
    });

    test('any amount can be negative: income, expense, a transfer and a fee', () {
      expect(draft().withAmount(-100).withCategory(food).problem, isNull);

      final t = TransactionDraft.create(TransactionType.transfer, now, assetId: 10).withToAccount(11);
      expect(t.withAmount(-100).problem, isNull);

      final withFee = draft().withAmount(100).withCategory(food).withHasFee(true).withFeeCategory(9);
      expect(withFee.withFee(-5).problem, isNull);
      expect(withFee.withFee(0).problem, 'Enter the fee, or untick Add a fee or tax');
    });

    test('a transfer needs two different accounts and no category', () {
      final t = TransactionDraft.create(TransactionType.transfer, now, assetId: 10).withAmount(100);

      expect(t.problem, 'Choose where the money goes');
      expect(t.withToAccount(10).problem, 'Choose two different accounts');
      expect(t.withToAccount(11).problem, isNull);
    });

    test('switching type clears a category of the wrong kind', () {
      final d = draft().withCategory(food).withType(TransactionType.income);

      expect(d.categoryId, isNull);
    });

    test('builds the transaction to save, keeping the id when editing', () {
      final existing = Transaction(
        id: 7,
        type: TransactionType.expense,
        amount: 100,
        assetId: 10,
        categoryId: 3,
        note: 'tea',
        dateTime: now,
      );
      final t = TransactionDraft.edit(existing).withAmount(200).withNote('  ').toTransaction();

      expect(t.id, 7);
      expect(t.amount, 200);
      expect(t.note, isNull);
    });
  });
}
