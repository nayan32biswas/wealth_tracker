import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/presentation/features/transactions/search_screen.dart';
import 'package:wealthtracker/presentation/features/transactions/transactions_screen.dart';
import 'package:wealthtracker/presentation/widgets/calculator.dart';
import 'package:wealthtracker/presentation/widgets/note_suggestions.dart';
import 'package:wealthtracker/presentation/widgets/number_pad.dart';

import 'harness.dart';

Future<List<Transaction>> saved(WidgetTester tester, DriftRepositories repos) async =>
    (await tester.runAsync(() => repos.transactions.find(const TransactionQuery())))!;

Future<int> idOfAsset(DriftRepositories repos, String name) async =>
    (await repos.assets.all()).firstWhere((a) => a.name == name).id;

Future<int> idOfCategory(DriftRepositories repos, String name) async =>
    (await repos.categories.all()).firstWhere((c) => c.name == name).id;

void main() {
  group('add form', () {
    testWidgets('adds an expense with the category fee using the number pad', (tester) async {
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          final utilities = (await repos.categories.all()).firstWhere((c) => c.name == 'Utilities');
          await repos.categories.update(utilities.copyWith(feeType: FeeType.fixed, feeValue: 1000));
        },
      );
      await openNewTransaction(tester);

      await typeOnPad(tester, 'Amount', ['5', '0', '0']);
      await pickCategory(tester, 'Utilities');

      expect(find.text('Fee ৳10.00 · Total ৳510.00'), findsOneWidget);

      await tapAndSettle(tester, find.text('Save'));

      final t = (await saved(tester, app.repos)).single;
      expect(t.type, TransactionType.expense);
      expect(t.amount, 50000);
      expect(t.fee, 1000);
      expect(find.text('৳510.00'), findsWidgets);
    });

    testWidgets('the time picker uses the 12-hour dial with AM/PM on a 24-hour phone', (tester) async {
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pumpApp(tester);
      testClock = () => DateTime(2026, 9, 23, 14, 30);
      await openNewTransaction(tester);

      await tapAndSettle(tester, find.text('14:30'));
      expect(find.text('AM'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // PM is picked from the current time, so OK keeps 14:30.
      await tapAndSettle(tester, find.text('OK'));
      expect(find.text('14:30'), findsOneWidget);
    });

    testWidgets('tapping Save twice saves once and closes only the form', (tester) async {
      final app = await pumpApp(tester);
      await openNewTransaction(tester);
      await typeOnPad(tester, 'Amount', ['5', '0']);
      await pickCategory(tester, 'Food');

      // Both taps land before the first save has finished writing.
      final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed!;
      save();
      save();
      await tester.pumpAndSettle();

      expect(await saved(tester, app.repos), hasLength(1));
      expect(find.text('New transaction'), findsNothing);
      expect(find.byTooltip('Add transaction'), findsOneWidget);
    });

    testWidgets('a fee typed by hand replaces the default', (tester) async {
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          final utilities = (await repos.categories.all()).firstWhere((c) => c.name == 'Utilities');
          await repos.categories.update(utilities.copyWith(feeType: FeeType.fixed, feeValue: 1000));
        },
      );
      await openNewTransaction(tester);

      await pickCategory(tester, 'Utilities');
      await typeOnPad(tester, 'Amount', ['2', '0', '0']);
      await showMoreOptions(tester);
      expect(find.text('10.00'), findsOneWidget);
      await typeOnPad(tester, 'Fee', [backspaceKey, backspaceKey, '5']);
      await tapAndSettle(tester, find.text('Save'));

      expect((await saved(tester, app.repos)).single.fee, 500);
    });

    group('calculator', () {
      Future<void> press(WidgetTester tester, List<String> keys) async {
        for (final key in keys) {
          await tester.tap(
            key == backspaceKey
                ? find.bySemanticsLabel('Backspace')
                : find.descendant(of: find.byType(CalculatorScreen), matching: find.text(key)),
          );
          await tester.pump();
        }
      }

      Future<void> openFor(WidgetTester tester, String field) => tapAndSettle(
        tester,
        find.descendant(of: find.widgetWithText(InputDecorator, field), matching: find.byTooltip('Calculator')),
      );

      testWidgets('starts with the amount and Done puts the result back', (tester) async {
        final app = await pumpApp(tester);
        await openNewTransaction(tester);
        await pickCategory(tester, 'Food');
        await typeOnPad(tester, 'Amount', ['1', '2', '0']);
        await openFor(tester, 'Amount');

        expect(find.text('120'), findsOneWidget);
        await press(tester, ['+', '3', '0']);
        expect(find.text('120+30'), findsOneWidget);
        expect(find.text('৳150.00'), findsOneWidget);

        await tapAndSettle(tester, find.text('Done'));
        expect(find.byType(CalculatorScreen), findsNothing);
        expect(find.text('150.00'), findsOneWidget);

        await tapAndSettle(tester, find.text('Save'));
        expect((await saved(tester, app.repos)).single.amount, 15000);
      });

      testWidgets('closing it leaves the amount as it was', (tester) async {
        await pumpApp(tester);
        await openNewTransaction(tester);
        await typeOnPad(tester, 'Amount', ['1', '2', '0']);
        await openFor(tester, 'Amount');
        await press(tester, ['×', '2']);
        await tapAndSettle(tester, find.byTooltip('Close'));

        expect(find.text('120.00'), findsOneWidget);
      });

      testWidgets('a result below 0 saves a negative expense', (tester) async {
        final app = await pumpApp(tester);
        await openNewTransaction(tester);
        await pickCategory(tester, 'Food');
        await openFor(tester, 'Amount');
        await press(tester, ['5', '0', '−', '8', '0']);
        await tapAndSettle(tester, find.text('Done'));
        await tapAndSettle(tester, find.text('Save'));

        expect((await saved(tester, app.repos)).single.amount, -3000);
      });

      testWidgets('a fee cannot come out negative', (tester) async {
        await pumpApp(tester);
        await openNewTransaction(tester);
        await showMoreOptions(tester);
        await openFor(tester, 'Fee');
        await press(tester, ['5', '0', '−', '8', '0']);

        expect(find.text("Can't be negative"), findsOneWidget);
        await tapAndSettle(tester, find.text('Done'));
        expect(find.byType(CalculatorScreen), findsOneWidget);
      });

      testWidgets('Done on an unchanged fee keeps it following the category', (tester) async {
        final app = await pumpApp(
          tester,
          arrange: (repos) async {
            final utilities = (await repos.categories.all()).firstWhere((c) => c.name == 'Utilities');
            await repos.categories.update(utilities.copyWith(feeType: FeeType.percent, feeValue: 200));
          },
        );
        await openNewTransaction(tester);
        await pickCategory(tester, 'Utilities');
        await typeOnPad(tester, 'Amount', ['1', '0', '0']);
        await showMoreOptions(tester);
        await openFor(tester, 'Fee');
        await tapAndSettle(tester, find.text('Done'));

        await typeOnPad(tester, 'Amount', ['0']);
        await tapAndSettle(tester, find.text('Save'));

        expect((await saved(tester, app.repos)).single.fee, 2000);
      });

      testWidgets('every key fits on a short landscape screen', (tester) async {
        await pumpApp(tester);
        await openNewTransaction(tester);
        tester.view.physicalSize = const Size(800, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpAndSettle();
        await openFor(tester, 'Amount');

        expect(tester.takeException(), isNull);
        for (final key in ['C', '7', '00', 'Done']) {
          final rect = tester.getRect(find.descendant(of: find.byType(CalculatorScreen), matching: find.text(key)));
          expect(rect.bottom, lessThanOrEqualTo(360));
        }
      });

      testWidgets('the number pad has no operator keys', (tester) async {
        await pumpApp(tester);
        await openNewTransaction(tester);
        await tapAndSettle(tester, find.widgetWithText(InputDecorator, 'Amount'));

        for (final key in operatorKeys) {
          expect(find.descendant(of: find.byType(NumberPad), matching: find.text(key)), findsNothing);
        }
      });
    });

    testWidgets('date comes first, then account, category and amount; fee and repeat are folded away', (tester) async {
      await pumpApp(tester);
      await openNewTransaction(tester);

      double top(String label) => tester.getTopLeft(find.text(label).first).dy;
      expect(top('Wed, 23 Sep 2026'), lessThan(top('Account')));
      expect(top('Account'), lessThan(top('Category')));
      expect(top('Category'), lessThan(top('Amount')));
      expect(find.text('Fee'), findsNothing);
      expect(find.text('Repeat'), findsNothing);

      await showMoreOptions(tester);

      expect(find.text('Fee'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
    });

    testWidgets('save is a wide button at the bottom', (tester) async {
      await pumpApp(tester);
      await openNewTransaction(tester);

      final save = tester.getRect(find.widgetWithText(FilledButton, 'Save'));
      final screen = tester.getRect(find.byType(Scaffold).last);
      expect(save.width, greaterThan(screen.width * 0.8));
      expect(save.bottom, greaterThan(screen.height * 0.9));
    });

    testWidgets('a new entry starts on the first account', (tester) async {
      await pumpApp(tester);
      await openNewTransaction(tester);

      expect(find.widgetWithText(DropdownButtonFormField<int>, 'Cash'), findsOneWidget);
    });

    testWidgets('an incomplete entry is not saved and says what is missing', (tester) async {
      final app = await pumpApp(tester);
      await openNewTransaction(tester);

      await tapAndSettle(tester, find.text('Save'));

      expect(find.text('Enter an amount'), findsOneWidget);
      expect(await saved(tester, app.repos), isEmpty);
    });

    testWidgets('a transfer needs two different accounts', (tester) async {
      final app = await pumpApp(tester);
      await openNewTransaction(tester);

      await tapAndSettle(tester, find.text('Transfer'));
      await typeOnPad(tester, 'Amount', ['1', '0', '0']);
      await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<int>, 'To'));
      await tapAndSettle(tester, find.text('Cash').last);
      await tapAndSettle(tester, find.text('Save'));

      expect(find.text('Choose two different accounts'), findsOneWidget);

      await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<int>, 'To'));
      await tapAndSettle(tester, find.text('Bank Account').last);
      await tapAndSettle(tester, find.text('Save'));

      final t = (await saved(tester, app.repos)).single;
      expect(t.type, TransactionType.transfer);
      expect(t.toAssetId, isNotNull);
      expect(t.categoryId, isNull);
    });
  });

  group('edit', () {
    Future<void> oneExpense(DriftRepositories repos) async => repos.transactions.save(
      Transaction(
        id: 0,
        type: TransactionType.expense,
        amount: 25000,
        assetId: await idOfAsset(repos, 'Cash'),
        categoryId: await idOfCategory(repos, 'Food'),
        note: 'Groceries',
        dateTime: DateTime(2026, 9, 20, 18),
      ),
    );

    testWidgets('changes an existing entry', (tester) async {
      final app = await pumpApp(tester, arrange: oneExpense);
      await openTab(tester, 'Activity');

      await tapAndSettle(tester, find.text('Groceries'));
      await typeOnPad(tester, 'Amount', [backspaceKey, backspaceKey, '0', '0']);
      await tapAndSettle(tester, find.text('Save'));

      expect((await saved(tester, app.repos)).single.amount, 20000);
    });

    testWidgets('an entry on an archived account still opens and keeps its account', (tester) async {
      late int wallet;
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          wallet = await idOfAsset(repos, 'Mobile Wallet');
          final food = await idOfCategory(repos, 'Food');
          await repos.assets.update(
            (await repos.assets.all()).firstWhere((a) => a.id == wallet).copyWith(initialBalance: 25000),
          );
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.expense,
              amount: 25000,
              assetId: wallet,
              categoryId: food,
              note: 'Last wallet spend',
              dateTime: DateTime(2026, 9, 20, 18),
            ),
          );
          await repos.assets.archive(wallet);
        },
      );
      await openTab(tester, 'Activity');

      await tapAndSettle(tester, find.text('Last wallet spend'));
      expect(find.widgetWithText(DropdownButtonFormField<int>, 'Mobile Wallet'), findsOneWidget);
      await typeOnPad(tester, 'Amount', [backspaceKey, backspaceKey, '0', '0']);
      await tapAndSettle(tester, find.text('Save'));

      final saved = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!.single;
      expect(saved.assetId, wallet);
      expect(saved.amount, 20000);
    });

    testWidgets('an entry in a removed category still opens and keeps its category', (tester) async {
      late int food;
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          await oneExpense(repos);
          food = await idOfCategory(repos, 'Food');
          await repos.categories.remove(food);
        },
      );
      await openTab(tester, 'Activity');

      await tapAndSettle(tester, find.text('Groceries'));
      expect(find.widgetWithText(DropdownButtonFormField<int>, 'Food'), findsOneWidget);
      await tapAndSettle(tester, find.text('Save'));

      expect((await saved(tester, app.repos)).single.categoryId, food);
    });

    testWidgets('an entry with a fee opens with the fee showing', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async => repos.transactions.save(
          Transaction(
            id: 0,
            type: TransactionType.expense,
            amount: 25000,
            fee: 500,
            assetId: await idOfAsset(repos, 'Cash'),
            categoryId: await idOfCategory(repos, 'Food'),
            note: 'Delivery',
            dateTime: DateTime(2026, 9, 20, 18),
          ),
        ),
      );
      await openTab(tester, 'Activity');

      await tapAndSettle(tester, find.text('Delivery'));

      expect(find.widgetWithText(InputDecorator, 'Fee'), findsOneWidget);
      expect(find.text('5.00'), findsOneWidget);
    });

    testWidgets('deletes an entry', (tester) async {
      final app = await pumpApp(tester, arrange: oneExpense);
      await openTab(tester, 'Activity');

      await tapAndSettle(tester, find.text('Groceries'));
      await tapAndSettle(tester, find.byTooltip('Delete'));
      expect(find.text('Delete this transaction?'), findsOneWidget);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Delete'));

      expect(await saved(tester, app.repos), isEmpty);
      expect(find.text('Groceries'), findsNothing);
    });
  });

  group('views', () {
    Future<void> twoDays(DriftRepositories repos) async {
      final cash = await idOfAsset(repos, 'Cash');
      await repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.income,
          amount: 100000,
          assetId: cash,
          categoryId: await idOfCategory(repos, 'Salary'),
          dateTime: DateTime(2026, 9, 1, 9),
        ),
      );
      await repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.expense,
          amount: 30000,
          assetId: cash,
          categoryId: await idOfCategory(repos, 'Food'),
          note: 'Dinner out',
          dateTime: DateTime(2026, 9, 10, 20),
        ),
      );
    }

    testWidgets('header shows the period income, expense and net', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');

      expect(find.text('৳1,000.00'), findsWidgets);
      expect(find.text('৳300.00'), findsWidgets);
      expect(find.text('৳700.00'), findsOneWidget);
    });

    testWidgets('each entry shows account, category with its note under it, and amount', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');

      final row = find.ancestor(of: find.text('Dinner out'), matching: find.byType(TransactionTile));
      Offset at(String text) => tester.getCenter(find.descendant(of: row, matching: find.text(text)));
      expect(at('Cash').dx, lessThan(at('Food').dx));
      expect(at('Dinner out').dy, greaterThan(at('Food').dy));
      expect(at('Food').dx, lessThan(at('৳300.00').dx));
      expect(at('Cash').dy, closeTo(at('৳300.00').dy, 0.5));
    });

    testWidgets('long names and huge amounts stay on one line without overflowing', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async {
          final cash = (await repos.assets.all()).first;
          await repos.assets.update(cash.copyWith(name: 'My very long personal savings account name'));
          final food = (await repos.categories.all()).firstWhere((c) => c.name == 'Food');
          await repos.categories.update(food.copyWith(name: 'Groceries and household supplies'));
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.expense,
              amount: 99999999999,
              assetId: cash.id,
              categoryId: food.id,
              note: 'A very long note that keeps going well past the edge of the screen',
              dateTime: DateTime(2026, 9, 20, 18),
            ),
          );
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 88888888888,
              assetId: cash.id,
              categoryId: await idOfCategory(repos, 'Salary'),
              dateTime: DateTime(2026, 9, 20, 9),
            ),
          );
        },
      );
      await openTab(tester, 'Activity');

      expect(tester.takeException(), isNull);
      final note = tester.renderObject<RenderParagraph>(find.textContaining('A very long note'));
      expect(note.didExceedMaxLines, isTrue);
    });

    testWidgets('daily view groups entries under their day', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');

      expect(find.text('Thu, 10 Sep'), findsOneWidget);
      expect(find.text('Tue, 1 Sep'), findsOneWidget);
      expect(find.text('Dinner out'), findsOneWidget);
    });

    testWidgets('calendar lists the entries of the tapped day', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');
      await choosePeriodKind(tester, 'Calendar');

      await tapAndSettle(tester, find.byKey(const ValueKey('day-2026-09-10')));

      expect(find.text('Dinner out'), findsOneWidget);
    });

    testWidgets('monthly view shows each month of the year', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');
      await choosePeriodKind(tester, 'Monthly');

      expect(find.text('January'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('September'), 100, scrollable: find.byType(Scrollable).last);
      expect(find.text('September'), findsOneWidget);
    });

    testWidgets('going back from monthly to daily lands on the current month', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');
      await choosePeriodKind(tester, 'Monthly');
      await choosePeriodKind(tester, 'Daily');

      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('Dinner out'), findsOneWidget);
    });

    testWidgets('search says when nothing matches', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');
      await tapAndSettle(tester, find.byTooltip('Search'));

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('search finds entries by note', (tester) async {
      await pumpApp(tester, arrange: twoDays);
      await openTab(tester, 'Activity');
      await tapAndSettle(tester, find.byTooltip('Search'));

      await tester.enterText(find.byType(TextField), 'dinner');
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(TransactionTile), matching: find.text('Dinner out')), findsOneWidget);
      expect(find.text('Salary'), findsNothing);
    });
  });

  group('note suggestions', () {
    Future<void> usedNotes(DriftRepositories repos) async {
      final cash = await idOfAsset(repos, 'Cash');
      final food = await idOfCategory(repos, 'Food');
      Future<void> spend(String note, int? category, int day) => repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.expense,
          amount: 10000,
          assetId: cash,
          categoryId: category,
          note: note,
          dateTime: DateTime(2026, 9, day, 12),
        ),
      );
      await spend('Rickshaw', null, 1);
      await spend('Rickshaw', null, 2);
      await spend('CNG rickshaw', null, 3);
      await spend('Lunch', food, 4);
    }

    List<String> chips(WidgetTester tester) => [
      for (final c in tester.widgetList<ActionChip>(find.byType(ActionChip))) (c.label as Text).data!,
    ];

    Future<void> waitForLookup(WidgetTester tester) async {
      await tester.pump(noteLookupDelay);
      await tester.pumpAndSettle();
    }

    testWidgets('picking a suggested note fills the Note field', (tester) async {
      final app = await pumpApp(tester, arrange: usedNotes);
      await openNewTransaction(tester);
      await typeOnPad(tester, 'Amount', ['5', '0']);
      await pickCategory(tester, 'Food');

      await enter(tester, 'Note', 'lu');
      await waitForLookup(tester);
      expect(chips(tester), ['Lunch']);

      await tapAndSettle(tester, find.widgetWithText(ActionChip, 'Lunch'));
      expect(find.byType(ActionChip), findsNothing);
      await tapAndSettle(tester, find.text('Save'));

      expect((await saved(tester, app.repos)).first.note, 'Lunch');
    });

    testWidgets('an empty Note field offers the notes of the chosen category first', (tester) async {
      await pumpApp(tester, arrange: usedNotes);
      await openNewTransaction(tester);
      await pickCategory(tester, 'Food');

      await tester.tap(find.widgetWithText(TextField, 'Note'));
      await waitForLookup(tester);

      expect(chips(tester), ['Lunch', 'Rickshaw', 'CNG rickshaw']);
    });

    testWidgets('search suggests notes as you type and searches the one picked', (tester) async {
      await pumpApp(tester, arrange: usedNotes);
      await openTab(tester, 'Activity');
      await tapAndSettle(tester, find.byTooltip('Search'));
      await waitForLookup(tester);
      expect(find.byType(ActionChip), findsNothing);

      await tester.enterText(find.byType(TextField), 'ric');
      await waitForLookup(tester);
      expect(chips(tester), ['Rickshaw', 'CNG rickshaw']);

      await tapAndSettle(tester, find.widgetWithText(ActionChip, 'CNG rickshaw'));

      expect(find.byType(ActionChip), findsNothing);
      expect(find.widgetWithText(TextField, 'CNG rickshaw'), findsOneWidget);
      expect(find.text('CNG rickshaw'), findsNWidgets(2));
      expect(find.text('Lunch'), findsNothing);
    });
  });

  group('long lists', () {
    Future<void> manyEntries(DriftRepositories repos) async {
      final cash = await idOfAsset(repos, 'Cash');
      final food = await idOfCategory(repos, 'Food');
      for (var i = 0; i < 250; i++) {
        await repos.transactions.save(
          Transaction(
            id: 0,
            type: TransactionType.expense,
            amount: 100 + i,
            assetId: cash,
            categoryId: food,
            note: 'entry $i',
            dateTime: DateTime(2026, 9, 1 + i % 20, 9, i % 60),
          ),
        );
      }
    }

    testWidgets('Activity builds only the rows on screen', (tester) async {
      await pumpApp(tester, arrange: manyEntries);

      expect(find.byType(TransactionTile), findsWidgets);
      expect(find.byType(TransactionTile).evaluate().length, lessThan(40));
    });

    Future<void> searchEntries(WidgetTester tester) async {
      await tapAndSettle(tester, find.byTooltip('Search'));
      await tester.enterText(find.byType(TextField), 'entry');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('search builds only the rows on screen', (tester) async {
      await pumpApp(tester, arrange: manyEntries);
      await searchEntries(tester);

      expect(find.byType(TransactionTile), findsWidgets);
      expect(find.byType(TransactionTile).evaluate().length, lessThan(40));
    });

    testWidgets('search shows 200 results, then Load more adds the rest', (tester) async {
      final app = await pumpApp(tester, arrange: manyEntries);
      await searchEntries(tester);
      final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));

      await tester.scrollUntilVisible(find.text('Load more'), 500, scrollable: list);
      await tapAndSettle(tester, find.text('Load more'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(find.text('Load more'), findsNothing);
      await tester.drag(list, const Offset(0, -100000));
      await tester.pumpAndSettle();
      expect(find.text('entry 0'), findsOneWidget);
      expect((await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!.length, 250);
    });

    testWidgets('search totals add up every match, not just the loaded page', (tester) async {
      await pumpApp(tester, arrange: manyEntries);
      await searchEntries(tester);

      // 250 entries of 100 + i paisa: 25000 + 31125 = 56125 paisa.
      expect(find.text('৳561.25'), findsOneWidget);
      expect(find.text('-৳561.25'), findsOneWidget);
    });
  });

  group('search filters', () {
    Future<void> mixed(DriftRepositories repos) async {
      final assets = {for (final a in await repos.assets.all()) a.name: a.id};
      final categories = {for (final c in await repos.categories.all()) c.name: c.id};
      Future<void> add(
        TransactionType type,
        int amount,
        String account,
        String note,
        DateTime at, {
        String? category,
        String? to,
      }) => repos.transactions.save(
        Transaction(
          id: 0,
          type: type,
          amount: amount,
          assetId: assets[account]!,
          toAssetId: to == null ? null : assets[to],
          categoryId: category == null ? null : categories[category],
          note: note,
          dateTime: at,
        ),
      );
      await add(TransactionType.income, 500000, 'Bank Account', 'Pay', DateTime(2026, 9, 1), category: 'Salary');
      await add(TransactionType.expense, 30000, 'Cash', 'Lunch', DateTime(2026, 9, 5), category: 'Food');
      await add(TransactionType.expense, 5000, 'Credit Card', 'Bus', DateTime(2026, 9, 6), category: 'Transport');
      await add(TransactionType.transfer, 100000, 'Bank Account', 'Top up', DateTime(2026, 9, 7), to: 'Mobile Wallet');
      await add(TransactionType.expense, 80000, 'Mobile Wallet', 'Pills', DateTime(2026, 8, 20), category: 'Health');
    }

    const notes = ['Pay', 'Lunch', 'Bus', 'Top up', 'Pills'];

    Future<void> openSearch(WidgetTester tester) async {
      await pumpApp(tester, arrange: mixed);
      await openTab(tester, 'Activity');
      await tapAndSettle(tester, find.byTooltip('Search'));
    }

    void expectOnly(List<String> shown) {
      for (final n in notes) {
        expect(find.text(n), shown.contains(n) ? findsOneWidget : findsNothing, reason: n);
      }
    }

    Finder inSearch(String text) => find.descendant(of: find.byType(SearchScreen), matching: find.text(text));

    Future<void> tick(WidgetTester tester, String row, List<String> names) async {
      await tapAndSettle(tester, inSearch(row));
      final dialog = find.byType(AlertDialog);
      for (final n in names) {
        await tester.tap(find.descendant(of: dialog, matching: find.text(n)));
        await tester.pump();
      }
      await tapAndSettle(tester, find.descendant(of: dialog, matching: find.text('Done')));
    }

    /// Every entry, through a filter on all the accounts they use.
    Future<void> showAll(WidgetTester tester) async {
      await tapAndSettle(tester, find.text('Filters'));
      await tick(tester, 'Accounts', ['Cash', 'Bank Account', 'Credit Card', 'Mobile Wallet']);
    }

    testWidgets('only the search box shows, and no entries, until there is a search', (tester) async {
      await openSearch(tester);

      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('Categories'), findsNothing);
      expectOnly([]);
      expect(find.byType(TotalsBar), findsNothing);

      await tapAndSettle(tester, find.text('Filters'));

      for (final row in ['Date', 'Categories', 'Accounts', 'Sort']) {
        expect(inSearch(row), findsOneWidget);
      }
    });

    testWidgets('picking several categories narrows the results', (tester) async {
      await openSearch(tester);
      await tapAndSettle(tester, find.text('Filters'));

      await tick(tester, 'Categories', ['Food', 'Transport']);

      expectOnly(['Lunch', 'Bus']);
      expect(find.text('Food, Transport'), findsOneWidget);
      expect(find.text('Filters (1)'), findsOneWidget);
    });

    testWidgets('picking several accounts matches either side of a transfer', (tester) async {
      await openSearch(tester);
      await tapAndSettle(tester, find.text('Filters'));

      await tick(tester, 'Accounts', ['Cash', 'Mobile Wallet']);

      expectOnly(['Lunch', 'Top up', 'Pills']);
    });

    testWidgets('a date range narrows the results', (tester) async {
      await openSearch(tester);
      // The test font draws every glyph as a full square, so Flutter's own
      // range picker header overflows at phone width here (not on a device).
      tester.view.physicalSize = const Size(1600, 2400);
      await tapAndSettle(tester, find.text('Filters'));

      await tapAndSettle(tester, inSearch('Date'));
      await tapAndSettle(tester, find.byTooltip('Switch to input'));
      final fields = find.descendant(of: find.byType(DateRangePickerDialog), matching: find.byType(TextField));
      await tester.enterText(fields.at(0), '09/05/2026');
      await tester.enterText(fields.at(1), '09/06/2026');
      await tapAndSettle(tester, find.text('OK'));

      expectOnly(['Lunch', 'Bus']);
    });

    testWidgets('changing only the sort still shows nothing', (tester) async {
      await openSearch(tester);
      await tapAndSettle(tester, find.text('Filters'));
      await tapAndSettle(tester, find.text('Newest first'));
      await tapAndSettle(tester, find.text('Largest amount').last);

      expectOnly([]);
    });

    testWidgets('typing a note lists the matches with their totals', (tester) async {
      await openSearch(tester);
      await tester.enterText(find.byType(TextField), 'u');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      // Lunch, Bus and Top up: a transfer is neither income nor expense.
      expect(find.byType(TransactionTile), findsNWidgets(3));
      final bar = find.byType(TotalsBar);
      expect(find.descendant(of: bar, matching: find.text('৳0.00')), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('৳350.00')), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('-৳350.00')), findsOneWidget);
    });

    testWidgets('a filter shows the totals of what it matches', (tester) async {
      await openSearch(tester);
      await showAll(tester);

      final bar = find.byType(TotalsBar);
      expect(find.descendant(of: bar, matching: find.text('৳5,000.00')), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('৳1,150.00')), findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('৳3,850.00')), findsOneWidget);
    });

    testWidgets('each result shows its date under the amount, styled like the note', (tester) async {
      await openSearch(tester);
      await showAll(tester);

      final amount = tester.getRect(find.text('৳300.00'));
      final date = tester.getRect(find.text('5 Sep 2026'));
      expect(date.top, greaterThanOrEqualTo(amount.bottom));
      expect(date.right, closeTo(amount.right, 0.5));
      final dateStyle = tester.widget<Text>(find.text('5 Sep 2026')).style!;
      final noteStyle = tester.widget<Text>(find.text('Lunch')).style!;
      expect((dateStyle.fontSize, dateStyle.color), (noteStyle.fontSize, noteStyle.color));
    });

    testWidgets('categories line up across rows whatever the amount and date width', (tester) async {
      await openSearch(tester);
      await showAll(tester);

      final lefts = {
        for (final c in ['Salary', 'Food', 'Transport', 'Health']) tester.getTopLeft(find.text(c)).dx,
      };
      expect(lefts, hasLength(1));
    });

    testWidgets('activity rows leave the date to the day header', (tester) async {
      await pumpApp(tester, arrange: mixed);
      await openTab(tester, 'Activity');

      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('5 Sep 2026'), findsNothing);
    });

    testWidgets('the sort value looks like the other filter values', (tester) async {
      await openSearch(tester);
      await tapAndSettle(tester, find.text('Filters'));

      TextStyle? style(String text) =>
          tester.widget<Text>(find.descendant(of: find.byType(SearchScreen), matching: find.text(text))).style;
      expect(style('Newest first')?.color, style('Any date')?.color);
      expect(style('Newest first')?.fontSize, isNotNull);
      expect(style('Newest first')?.fontSize, style('Any date')?.fontSize);
    });

    testWidgets('sorting by largest amount puts the biggest entries first', (tester) async {
      await openSearch(tester);
      await showAll(tester);

      await tapAndSettle(tester, find.text('Newest first'));
      await tapAndSettle(tester, find.text('Largest amount').last);

      final order = [
        for (final n in ['Pay', 'Top up', 'Pills', 'Lunch', 'Bus']) tester.getTopLeft(find.text(n)).dy,
      ];
      expect(order, [...order]..sort());
    });

    testWidgets('filters stay applied when the panel is closed, and clear all resets them', (tester) async {
      await openSearch(tester);
      await tapAndSettle(tester, find.text('Filters'));
      await tick(tester, 'Categories', ['Food']);

      await tapAndSettle(tester, find.text('Filters (1)'));

      expect(find.text('Categories'), findsNothing);
      expectOnly(['Lunch']);

      await tapAndSettle(tester, find.text('Filters (1)'));
      await tapAndSettle(tester, find.text('Clear all'));

      expectOnly([]);
      expect(find.text('Filters'), findsOneWidget);
    });
  });

  group('transaction row', () {
    Future<void> twoEntries(DriftRepositories repos) async {
      final cash = (await repos.assets.all()).firstWhere((a) => a.name == 'Cash').id;
      final categories = {for (final c in await repos.categories.all()) c.name: c.id};
      Future<void> add(String category, int day, {String? note}) => repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.expense,
          amount: 10000,
          assetId: cash,
          categoryId: categories[category],
          note: note,
          dateTime: DateTime(2026, 9, day, 12),
        ),
      );
      await add('Food', 10, note: 'Groceries');
      await add('Transport', 11);
    }

    Finder row(String text) => find.ancestor(of: find.text(text), matching: find.byType(TransactionTile));

    Future<void> openActivity(WidgetTester tester) async {
      await pumpApp(tester, arrange: twoEntries);
      await openTab(tester, 'Activity');
    }

    testWidgets('the note sits under the category, lined up on the left', (tester) async {
      await openActivity(tester);

      final category = tester.getRect(find.text('Food'));
      final note = tester.getRect(find.text('Groceries'));
      expect(note.top, greaterThanOrEqualTo(category.bottom));
      expect(note.left, category.left);
    });

    testWidgets('without a note the category is centred in the row', (tester) async {
      await openActivity(tester);

      expect(tester.getCenter(find.text('Transport')).dy, closeTo(tester.getCenter(row('Transport')).dy, 0.5));
    });

    testWidgets('with a note, category and note together are centred in the row', (tester) async {
      await openActivity(tester);

      final block = tester.getRect(find.text('Food')).expandToInclude(tester.getRect(find.text('Groceries')));
      expect(block.center.dy, closeTo(tester.getCenter(row('Food')).dy, 0.5));
    });

    testWidgets('the note is smaller than the category and greyed out', (tester) async {
      await openActivity(tester);

      final category = tester.widget<Text>(find.text('Food')).style!;
      final note = tester.widget<Text>(find.text('Groceries')).style!;
      final context = tester.element(find.text('Groceries'));
      expect(note.fontSize, lessThan(category.fontSize!));
      expect(note.color, Theme.of(context).colorScheme.onSurfaceVariant);
    });

    testWidgets('rows hug their text and are kept apart by the same gap', (tester) async {
      await openActivity(tester);

      final food = tester.getRect(row('Food'));
      final block = tester.getRect(find.text('Food')).expandToInclude(tester.getRect(find.text('Groceries')));
      final transport = tester.getRect(row('Transport'));
      final transportText = tester.getRect(find.text('Transport'));
      expect(food.height - block.height, closeTo(transport.height - transportText.height, 0.5));
      expect(food.height - block.height, lessThanOrEqualTo(20));
      expect(food.height - block.height, greaterThanOrEqualTo(12));
    });
  });
}
