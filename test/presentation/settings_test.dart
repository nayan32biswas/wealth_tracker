import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';

import 'harness.dart';

Future<void> openDemoDialog(WidgetTester tester) async {
  await openTab(tester, 'Settings');
  await tester.scrollUntilVisible(find.text('Load demo data'), 100);
  await tapAndSettle(tester, find.text('Load demo data'));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

/// Taps Load and waits for the real database work behind the spinner.
Future<void> loadDemo(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Load'));
  for (var i = 0; i < 100 && find.textContaining('of demo data.').evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> foodLunch(DriftRepositories repos) async {
  final cash = (await repos.assets.all()).firstWhere((a) => a.name == 'Cash');
  final food = (await repos.categories.all()).firstWhere((c) => c.name == 'Food');
  await repos.transactions.save(
    Transaction(
      id: 0,
      type: TransactionType.expense,
      amount: 200,
      assetId: cash.id,
      categoryId: food.id,
      note: 'Lunch',
      dateTime: DateTime(2026, 9, 10, 12),
    ),
  );
}

void main() {
  group('categories', () {
    testWidgets('adds a new category to the chosen type', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.byTooltip('Add category'));
      await enter(tester, 'Name', 'Pets');
      await tapAndSettle(tester, find.text('Save'));

      await tester.scrollUntilVisible(find.text('Pets'), 100);
      await tester.ensureVisible(find.text('Pets'));
      expect(find.text('Pets'), findsOneWidget);
      final pets = (await tester.runAsync(app.repos.categories.all))!.firstWhere((c) => c.name == 'Pets');
      expect(pets.type, CategoryType.expense);
    });

    testWidgets('sets a percent default fee', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Bank Charges'));
      await tapAndSettle(tester, find.text('Percent'));
      await enter(tester, 'Fee %', '1.85');
      await tapAndSettle(tester, find.text('Save'));

      final saved = (await tester.runAsync(app.repos.categories.all))!.firstWhere((c) => c.name == 'Bank Charges');
      expect(saved.feeType, FeeType.percent);
      expect(saved.feeValue, 185);
      expect(find.text('Fee 1.85%'), findsOneWidget);
    });

    testWidgets('a percent fee above 100% cannot be saved', (tester) async {
      await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Bank Charges'));
      await tapAndSettle(tester, find.text('Percent'));
      await enter(tester, 'Fee %', '150');

      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
    });

    testWidgets('shows income categories on the Income tab', (tester) async {
      await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Income'));

      expect(find.text('Salary'), findsOneWidget);
      expect(find.text('Food'), findsNothing);
    });

    testWidgets('removes a category', (tester) async {
      await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Education'));
      await tapAndSettle(tester, find.text('Delete'));

      expect(find.text('Education'), findsNothing);
    });

    testWidgets('merges a used category into another one', (tester) async {
      final app = await pumpApp(tester, arrange: foodLunch);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Food'));
      await tapAndSettle(tester, find.text('Merge or mark deleted'));
      expect(find.textContaining('Used by 1 entry.'), findsOneWidget);
      await tapAndSettle(tester, find.text('Merge into'));
      await tapAndSettle(tester, find.text('Rent').last);
      await tapAndSettle(tester, find.text('Merge'));

      expect(find.text('Food'), findsNothing);
      final lunch = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!.single;
      final names = (await tester.runAsync(() => app.repos.categories.watchNames().first))!;
      expect(names[lunch.categoryId], 'Rent');
      expect(names.values, isNot(contains('Food')));
    });

    testWidgets('marks a used category as deleted', (tester) async {
      final app = await pumpApp(tester, arrange: foodLunch);
      await openSettingsItem(tester, 'Categories');

      await tapAndSettle(tester, find.text('Food'));
      await tapAndSettle(tester, find.text('Merge or mark deleted'));
      await tapAndSettle(tester, find.text('Mark as deleted'));

      expect(find.text('Food'), findsNothing);
      final names = (await tester.runAsync(() => app.repos.categories.watchNames().first))!;
      expect(names.values, contains('Food'));
    });

    testWidgets('drag reorders categories', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');

      final gesture = await tester.startGesture(tester.getCenter(find.text('Food')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 170));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      final expense = (await tester.runAsync(app.repos.categories.all))!
          .where((c) => c.type == CategoryType.expense)
          .map((c) => c.name)
          .toList();
      expect(expense.first, isNot('Food'));
      expect(expense.take(4), contains('Food'));
    });
  });

  group('restoring deleted items', () {
    testWidgets('a category marked deleted can be restored', (tester) async {
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          await foodLunch(repos);
          await repos.categories.remove((await repos.categories.all()).firstWhere((c) => c.name == 'Food').id);
        },
      );
      await openSettingsItem(tester, 'Categories');
      expect(find.text('Food'), findsNothing);

      await tapAndSettle(tester, find.byTooltip('Deleted categories'));
      expect(find.text('Expense'), findsOneWidget);
      expect(find.text('Income'), findsNothing);
      await tapAndSettle(tester, find.widgetWithText(TextButton, 'Restore'));

      expect(find.text('Food restored'), findsOneWidget);
      expect(find.text('No deleted categories'), findsOneWidget);
      expect((await tester.runAsync(app.repos.categories.all))!.last.name, 'Food');
    });

    testWidgets('an archived account can be brought back', (tester) async {
      late int wallet;
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          wallet = (await repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet').id;
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 500,
              assetId: wallet,
              dateTime: DateTime(2026, 9, 10, 12),
            ),
          );
          await repos.assets.archive(wallet);
        },
      );
      await openSettingsItem(tester, 'Accounts and groups');
      expect(find.text('Asset · 0 accounts · 1 archived'), findsOneWidget);

      await tapAndSettle(tester, find.byTooltip('Archived accounts'));
      expect(find.widgetWithText(TextButton, 'Unarchive'), findsOneWidget);
      await tapAndSettle(tester, find.widgetWithText(TextButton, 'Unarchive'));

      expect(find.text('Mobile Wallet is back in the list'), findsOneWidget);
      expect(find.text('No archived accounts'), findsOneWidget);
      expect((await tester.runAsync(app.repos.assets.all))!.map((a) => a.id), contains(wallet));
    });

    testWidgets('says so when nothing is deleted', (tester) async {
      await pumpApp(tester);
      await openSettingsItem(tester, 'Categories');
      await tapAndSettle(tester, find.byTooltip('Deleted categories'));

      expect(find.text('No deleted categories'), findsOneWidget);
    });
  });

  group('groups and accounts', () {
    testWidgets('adds a liability group', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.byTooltip('Add group'));
      await enter(tester, 'Name', 'Mortgage');
      await tapAndSettle(tester, find.text('Liability'));
      await tapAndSettle(tester, find.text('Save'));

      final group = (await tester.runAsync(app.repos.groups.all))!.last;
      expect(group.name, 'Mortgage');
      expect(group.type, GroupType.liability);
    });

    testWidgets('cannot remove a group that has accounts', (tester) async {
      await pumpApp(tester);
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Bank'));
      await tapAndSettle(tester, find.byTooltip('Edit group'));
      await tapAndSettle(tester, find.text('Delete'));

      expect(find.text('Move or delete the accounts in this group first, archived ones too.'), findsOneWidget);
    });

    testWidgets('an account with transactions is archived instead of deleted', (tester) async {
      late int wallet;
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          wallet = (await repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet').id;
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 500,
              assetId: wallet,
              dateTime: DateTime(2026, 9, 10, 12),
            ),
          );
        },
      );
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Mobile Wallet'));
      await tapAndSettle(tester, find.widgetWithText(ListTile, 'Mobile Wallet'));
      expect(find.text('Delete'), findsNothing);
      await tapAndSettle(tester, find.text('Archive'));

      expect(find.text('Archived'), findsOneWidget);
      final names = (await tester.runAsync(() => app.repos.assets.watchNames().first))!;
      expect(names[wallet], 'Mobile Wallet');
      expect((await tester.runAsync(() => app.repos.assets.watchArchived().first))!.single.id, wallet);
    });

    testWidgets('a group with an archived account cannot be deleted', (tester) async {
      late int wallet;
      await pumpApp(
        tester,
        arrange: (repos) async {
          wallet = (await repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet').id;
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 500,
              assetId: wallet,
              dateTime: DateTime(2026, 9, 10, 12),
            ),
          );
          await repos.assets.archive(wallet);
        },
      );
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Mobile Wallet'));
      await tapAndSettle(tester, find.byTooltip('Edit group'));
      await tapAndSettle(tester, find.text('Delete'));

      expect(find.text('Move or delete the accounts in this group first, archived ones too.'), findsOneWidget);
    });

    testWidgets('an archived account is listed in its group and can be moved out, so the group can go', (tester) async {
      late int wallet;
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          wallet = (await repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet').id;
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 500,
              assetId: wallet,
              dateTime: DateTime(2026, 9, 10, 12),
            ),
          );
          await repos.assets.archive(wallet);
        },
      );
      await openSettingsItem(tester, 'Accounts and groups');
      await tapAndSettle(tester, find.text('Mobile Wallet'));
      expect(find.text('Archived'), findsOneWidget);

      await tapAndSettle(tester, find.widgetWithText(ListTile, 'Mobile Wallet'));
      expect(find.text('Archive'), findsNothing);
      await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<int>, 'Mobile Wallet'));
      await tapAndSettle(tester, find.text('Cash').last);
      await tapAndSettle(tester, find.text('Save'));
      expect(find.text('Archived'), findsNothing);

      await tapAndSettle(tester, find.byTooltip('Edit group'));
      await tapAndSettle(tester, find.text('Delete'));

      final groups = (await tester.runAsync(app.repos.groups.all))!.map((g) => g.name);
      expect(groups, isNot(contains('Mobile Wallet')));
      final moved = (await tester.runAsync(() => app.repos.assets.watchArchived().first))!.single;
      expect((moved.id, moved.groupId), (wallet, (await tester.runAsync(app.repos.groups.all))!.first.id));
    });

    testWidgets('adds an account with an opening balance', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Bank'));
      await tapAndSettle(tester, find.byTooltip('Add account'));
      await enter(tester, 'Name', 'Savings');
      await enter(tester, 'Opening balance', '1,250.50');
      await tapAndSettle(tester, find.text('Save'));

      expect(find.text('Savings'), findsOneWidget);
      final savings = (await tester.runAsync(app.repos.assets.all))!.firstWhere((a) => a.name == 'Savings');
      expect(savings.initialBalance, 125050);
    });

    testWidgets('renaming an account keeps its balance after its group changes type', (tester) async {
      final app = await pumpApp(
        tester,
        arrange: (repos) async {
          final card = (await repos.assets.all()).firstWhere((a) => a.name == 'Credit Card');
          await repos.assets.update(card.copyWith(initialBalance: -50000));
          final group = (await repos.groups.all()).firstWhere((g) => g.name == 'Card');
          await repos.groups.update(group.copyWith(type: GroupType.asset));
        },
      );
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Card'));
      await tapAndSettle(tester, find.text('Credit Card'));
      expect(find.widgetWithText(TextField, '-500'), findsOneWidget);
      await enter(tester, 'Name', 'Old card');
      await tapAndSettle(tester, find.text('Save'));

      final card = (await tester.runAsync(app.repos.assets.all))!.firstWhere((a) => a.name == 'Old card');
      expect(card.initialBalance, -50000);
    });

    testWidgets('an asset account can start overdrawn', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Bank'));
      await tapAndSettle(tester, find.text('Bank Account'));
      await enter(tester, 'Opening balance', '-200');
      await tapAndSettle(tester, find.text('Save'));

      final bank = (await tester.runAsync(app.repos.assets.all))!.firstWhere((a) => a.name == 'Bank Account');
      expect(bank.initialBalance, -20000);
    });

    testWidgets('a card account can start with a debt', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'Accounts and groups');

      await tapAndSettle(tester, find.text('Card'));
      await tapAndSettle(tester, find.text('Credit Card'));
      await enter(tester, 'Amount owed', '500');
      await tapAndSettle(tester, find.text('Save'));

      final card = (await tester.runAsync(app.repos.assets.all))!.firstWhere((a) => a.name == 'Credit Card');
      expect(card.initialBalance, -50000);
    });
  });

  group('preferences', () {
    testWidgets('currency and week start are saved', (tester) async {
      final app = await pumpApp(tester);
      await openTab(tester, 'Settings');

      await tapAndSettle(tester, find.text('Currency'));
      await enter(tester, 'Symbol', r'$');
      await enter(tester, 'Code', 'USD');
      await tapAndSettle(tester, find.text('Save'));

      await tapAndSettle(tester, find.text('First day of week'));
      await tapAndSettle(tester, find.text('Monday').last);

      final s = (await tester.runAsync(app.repos.settings.get))!;
      expect(s.currencySymbol, r'$');
      expect(s.currencyCode, 'USD');
      expect(s.weekStart, DateTime.monday);
    });

    testWidgets('month start day is saved', (tester) async {
      final app = await pumpApp(tester);
      await openTab(tester, 'Settings');

      await tapAndSettle(tester, find.text('First day of month'));
      await tester.scrollUntilVisible(find.text('25'), 50, scrollable: find.byType(Scrollable).last);
      await tapAndSettle(tester, find.text('25'));

      expect((await tester.runAsync(app.repos.settings.get))!.monthStartDay, 25);
    });

    testWidgets('demo data loads the typed number of months', (tester) async {
      final app = await pumpApp(tester);
      await openDemoDialog(tester);

      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Months')).controller!.text, '12');
      expect(find.text('Remove existing data first'), findsNothing);
      await enter(tester, 'Months', '1');
      await loadDemo(tester);

      final dates = (await tester.runAsync(
        () => app.repos.transactions.find(const TransactionQuery()),
      ))!.map((t) => t.dateTime).toList()..sort();
      expect(DateUtils.dateOnly(dates.first), DateTime(2026, 8, 23));
      expect(find.text('Loaded 1 month of demo data.'), findsOneWidget);
    });

    testWidgets('demo data can replace what is already there', (tester) async {
      final app = await pumpApp(tester, arrange: smallLedger);
      await openDemoDialog(tester);

      await tapAndSettle(tester, find.text('Remove existing data first'));
      await enter(tester, 'Months', '1');
      await loadDemo(tester);

      final notes = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!
          .map((t) => t.note);
      expect(notes, isNot(contains('New shoes')));
      expect(notes, isNotEmpty);
    });

    testWidgets('demo data is added next to existing data unless asked', (tester) async {
      final app = await pumpApp(tester, arrange: smallLedger);
      await openDemoDialog(tester);

      expect(find.text('Remove existing data first'), findsOneWidget);
      await enter(tester, 'Months', '1');
      await loadDemo(tester);

      final notes = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!
          .map((t) => t.note);
      expect(notes, contains('New shoes'));
      expect(notes.length, greaterThan(2));
    });

    testWidgets('demo months must be at least 1, with no upper limit', (tester) async {
      await pumpApp(tester);
      await openDemoDialog(tester);
      VoidCallback? load() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Load')).onPressed;

      for (final months in ['', '0']) {
        await enter(tester, 'Months', months);
        expect(load(), isNull, reason: months);
      }
      expect(find.text('Enter 1 or more'), findsOneWidget);
      for (final months in ['24', '25', '120']) {
        await enter(tester, 'Months', months);
        expect(load(), isNotNull, reason: months);
      }
    });
  });
}
