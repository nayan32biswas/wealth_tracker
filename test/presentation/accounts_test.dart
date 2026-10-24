import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/presentation/widgets/period_switcher.dart';

import 'harness.dart';

void main() {
  group('accounts', () {
    testWidgets('header shows assets, liabilities owed and net worth', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');

      expect(find.text('৳1,500.00'), findsWidgets);
      expect(find.text('৳200.00'), findsWidgets);
      expect(find.text('৳1,300.00'), findsOneWidget);
    });

    testWidgets('groups list their accounts with balances', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');

      expect(find.text('Credit Card'), findsOneWidget);
      expect(find.text('Bank Account'), findsOneWidget);
      expect(find.text('৳500.00'), findsWidgets);
    });

    testWidgets('accounts sit slightly right of their group', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');

      final group = tester.getTopLeft(find.text('Bank')).dx;
      final account = tester.getTopLeft(find.text('Bank Account')).dx;
      expect(group, 16);
      expect(account - group, 8);
    });

    testWidgets('group totals and account balances still end on one edge', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');

      // The Bank group and its one account both hold ৳500.00.
      final rights = {for (final e in find.text('৳500.00').evaluate()) tester.getTopRight(find.byWidget(e.widget)).dx};
      expect(rights, hasLength(1));
    });

    testWidgets('an account opens with its own transactions', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');

      await tapAndSettle(tester, find.text('Credit Card'));

      expect(find.text('New shoes'), findsOneWidget);
      expect(find.text('Bonus'), findsNothing);
    });

    testWidgets('an open account screen survives its account being removed', (tester) async {
      final app = await pumpApp(tester);
      await openTab(tester, 'Accounts');
      await tapAndSettle(tester, find.widgetWithText(ListTile, 'Mobile Wallet'));

      await tester.runAsync(() async {
        final wallet = (await app.repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet');
        await app.repos.assets.remove(wallet.id);
      });
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Mobile Wallet'), findsOneWidget);
    });

    testWidgets('an archived account shows while it holds money, and counts in net worth', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async {
          final assets = {for (final a in await repos.assets.all()) a.name: a};
          await repos.assets.update(assets['Mobile Wallet']!.copyWith(initialBalance: 30000));
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.income,
              amount: 500,
              assetId: assets['Cash']!.id,
              dateTime: DateTime(2026, 9, 10, 12),
            ),
          );
          await repos.assets.archive(assets['Mobile Wallet']!.id);
          await repos.assets.archive(assets['Cash']!.id);
          await repos.transactions.save(
            Transaction(
              id: 0,
              type: TransactionType.expense,
              amount: 500,
              assetId: assets['Cash']!.id,
              dateTime: DateTime(2026, 9, 11, 12),
            ),
          );
        },
      );
      await openTab(tester, 'Accounts');

      expect(find.widgetWithText(ListTile, 'Mobile Wallet'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Archived'), findsOneWidget);
      // Cash is archived and back at zero, so it has nothing to show.
      expect(find.widgetWithText(ListTile, 'Cash'), findsNothing);
      expect(find.text('৳300.00'), findsWidgets);
    });
  });

  group('account activity', () {
    // Wallet: topped up from the bank this month (fee on the bank side),
    // one expense this month and one last month.
    Future<void> walletLedger(DriftRepositories repos) async {
      final assets = {for (final a in await repos.assets.all()) a.name: a.id};
      Future<void> add(TransactionType type, int amount, DateTime at, {int fee = 0, int? to, String? note}) =>
          repos.transactions.save(
            Transaction(
              id: 0,
              type: type,
              amount: amount,
              fee: fee,
              assetId: to == null ? assets['Mobile Wallet']! : assets['Bank Account']!,
              toAssetId: to,
              note: note,
              dateTime: at,
            ),
          );
      await add(TransactionType.transfer, 30000, DateTime(2026, 9, 10), fee: 500, to: assets['Mobile Wallet']);
      await add(TransactionType.expense, 5000, DateTime(2026, 9, 15), note: 'Tea');
      await add(TransactionType.expense, 2000, DateTime(2026, 8, 5), note: 'Bus');
    }

    Future<void> openWallet(WidgetTester tester) async {
      await pumpApp(tester, arrange: walletLedger);
      await openTab(tester, 'Accounts');
      await tapAndSettle(tester, find.widgetWithText(ListTile, 'Mobile Wallet'));
    }

    String cell(WidgetTester tester, String label) {
      final column = find.ancestor(of: find.text(label), matching: find.byType(Column)).first;
      return tester.widget<Text>(find.descendant(of: column, matching: find.byType(Text)).last).data!;
    }

    testWidgets('opens on this month by day, with the balance and money in and out', (tester) async {
      await openWallet(tester);

      expect(find.text('৳230.00'), findsOneWidget);
      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('Tue, 15 Sep'), findsOneWidget);
      expect(find.text('Thu, 10 Sep'), findsOneWidget);
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('Bus'), findsNothing);
      expect(cell(tester, 'In'), '৳300.00');
      expect(cell(tester, 'Out'), '৳50.00');
      expect(cell(tester, 'Net'), '৳250.00');
    });

    testWidgets('previous shows last month', (tester) async {
      await openWallet(tester);

      await tapAndSettle(tester, find.byTooltip('Previous'));

      expect(find.text('Aug 2026'), findsOneWidget);
      expect(find.text('Bus'), findsOneWidget);
      expect(find.text('Tea'), findsNothing);
    });

    testWidgets('the menu offers only daily and monthly', (tester) async {
      await openWallet(tester);

      await tapAndSettle(tester, find.byTooltip('Period type'));

      for (final label in ['Daily', 'Monthly']) {
        expect(find.widgetWithText(PopupMenuItem<PeriodOption>, label), findsOneWidget);
      }
      for (final label in ['Calendar', 'Custom']) {
        expect(find.widgetWithText(PopupMenuItem<PeriodOption>, label), findsNothing);
      }
    });

    testWidgets('monthly lists the months of the year with transfers counted', (tester) async {
      await openWallet(tester);

      await tapAndSettle(tester, find.byTooltip('Period type'));
      await tapAndSettle(tester, find.widgetWithText(PopupMenuItem<PeriodOption>, 'Monthly'));

      expect(find.text('2026'), findsOneWidget);
      final september = find.widgetWithText(ListTile, 'September');
      await tester.scrollUntilVisible(september, 100, scrollable: find.byType(Scrollable).last);
      expect(find.descendant(of: september, matching: find.text('৳300.00')), findsOneWidget);
      expect(find.descendant(of: september, matching: find.text('৳50.00')), findsOneWidget);
      expect(find.descendant(of: september, matching: find.text('৳250.00')), findsOneWidget);
      final august = find.widgetWithText(ListTile, 'August');
      expect(find.descendant(of: august, matching: find.text('৳20.00')), findsWidgets);
    });

    testWidgets('opening the account does not move the activity tab', (tester) async {
      await openWallet(tester);
      await tapAndSettle(tester, find.byTooltip('Previous'));
      await tapAndSettle(tester, find.byTooltip('Back'));

      await openTab(tester, 'Activity');

      expect(find.text('Sep 2026'), findsOneWidget);
    });
  });
}
