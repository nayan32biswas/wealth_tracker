import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/services/calendar.dart';
import 'package:wealthtracker/presentation/features/stats/pace_view.dart';
import 'package:wealthtracker/presentation/features/stats/stats_screen.dart';
import 'package:wealthtracker/presentation/features/transactions/transactions_screen.dart';

import 'harness.dart';

Future<void> spending(DriftRepositories repos) async {
  final cash = (await repos.assets.all()).first.id;
  final categories = {for (final c in await repos.categories.all()) '${c.type.name}:${c.name}': c.id};
  Future<void> add(TransactionType type, String category, int amount, DateTime at, {String? note}) =>
      repos.transactions.save(
        Transaction(
          id: 0,
          type: type,
          amount: amount,
          assetId: cash,
          categoryId: categories['${type.name}:$category'],
          note: note,
          dateTime: at,
        ),
      );
  await add(TransactionType.expense, 'Food', 30000, DateTime(2026, 9, 3), note: 'Big shop');
  await add(TransactionType.expense, 'Transport', 10000, DateTime(2026, 9, 4));
  await add(TransactionType.expense, 'Food', 10000, DateTime(2026, 9, 20));
  await add(TransactionType.expense, 'Health', 50000, DateTime(2026, 3, 2));
  await add(TransactionType.income, 'Salary', 900000, DateTime(2026, 9, 1));
}

/// Trends and the category screen have their own Month/Year menu.
Future<void> chooseScale(WidgetTester tester, String label) async {
  await tapAndSettle(tester, find.byTooltip('Period type'));
  await tapAndSettle(tester, find.text(label).last);
}

void main() {
  testWidgets('expenses are ranked by category with share and amount', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    expect(find.text('৳500.00'), findsWidgets);
    final food = tester.getTopLeft(find.text('Food'));
    final transport = tester.getTopLeft(find.text('Transport'));
    expect(food.dy, lessThan(transport.dy));
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('৳400.00'), findsOneWidget);
    expect(find.text('Health'), findsNothing);
  });

  testWidgets('a thin line separates category rows, with none above the first or below the last', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    final view = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_CategoriesView');
    final lines = find.descendant(of: view, matching: find.byType(Divider));
    expect(lines, findsOneWidget);
    final line = tester.getCenter(lines).dy;
    expect(line, greaterThan(tester.getBottomLeft(find.text('Food')).dy));
    expect(line, lessThan(tester.getTopLeft(find.text('Transport')).dy));
  });

  testWidgets('a category row is one line: share badge, name, then amount', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    final badge = tester.getCenter(find.text('80%'));
    final name = tester.getCenter(find.text('Food'));
    final amount = tester.getCenter(find.text('৳400.00'));
    expect(badge.dx, lessThan(name.dx));
    expect(name.dx, lessThan(amount.dx));
    expect((badge.dy - name.dy).abs(), lessThan(2));
    expect((amount.dy - name.dy).abs(), lessThan(2));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getTopLeft(find.text('Food')).dx, tester.getTopLeft(find.text('Transport')).dx);
  });

  testWidgets('income tab shows income categories', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.widgetWithText(SegmentedButton<TransactionType>, 'Income'));

    expect(find.text('Salary'), findsOneWidget);
    expect(find.text('Food'), findsNothing);
  });

  testWidgets('period switcher and period type share one line', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    final label = tester.getCenter(find.text('Sep 2026'));
    final kind = tester.getCenter(find.byTooltip('Period type'));
    expect((label.dy - kind.dy).abs(), lessThan(4));
    expect(find.byType(SegmentedButton<PeriodKind>), findsNothing);

    await tapAndSettle(tester, find.byTooltip('Period type'));
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Week'), findsNothing);
  });

  testWidgets('year view covers every month of the year', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await choosePeriodKind(tester, 'Year');

    expect(find.text('2026'), findsOneWidget);
    expect(find.text('Health'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('going from year back to month lands on the current month', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await choosePeriodKind(tester, 'Year');
    await choosePeriodKind(tester, 'Month');

    expect(find.text('Sep 2026'), findsOneWidget);
    expect(find.text('Health'), findsNothing);
  });

  testWidgets('a past year goes back to its first month', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await choosePeriodKind(tester, 'Year');
    await tapAndSettle(tester, find.byTooltip('Previous'));
    await choosePeriodKind(tester, 'Month');

    expect(find.text('Jan 2025'), findsOneWidget);
  });

  testWidgets('a category opens its transactions for the period', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.text('Food'));

    expect(find.text('Big shop'), findsOneWidget);
    expect(find.byType(TransactionTile), findsNWidgets(2));
  });

  group('category over time', () {
    List<double> bars(WidgetTester tester) =>
        tester.widget<BarChart>(find.byType(BarChart)).data.barGroups.map((g) => g.barRods.single.toY).toList();

    testWidgets('a category shows its last six months, ending at the chosen one', (tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');

      await tapAndSettle(tester, find.text('Food'));

      expect(bars(tester), [0, 0, 0, 0, 0, 40000]);
      expect(find.text('Apr'), findsOneWidget);
      expect(find.text('Sep'), findsOneWidget);
    });

    testWidgets('yearly shows its last six years', (tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Food'));

      await chooseScale(tester, 'Year');

      expect(bars(tester), [0, 0, 0, 0, 0, 40000]);
      expect(find.text('2021'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
    });

    testWidgets('opens yearly when the Stats period is a year', (tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');
      await choosePeriodKind(tester, 'Year');

      await tapAndSettle(tester, find.text('Health'));

      expect(bars(tester), [0, 0, 0, 0, 0, 50000]);
      expect(find.text('2021'), findsOneWidget);
    });

    testWidgets('a salary-cycle month gets bars for whole cycles', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async {
          await spending(repos);
          await repos.settings.save((await repos.settings.get()).copyWith(monthStartDay: 25));
        },
      );
      await openTab(tester, 'Stats');

      await tapAndSettle(tester, find.text('Food'));

      // 25 Aug – 24 Sep holds both Food entries.
      expect(bars(tester).last, 40000);
      expect(find.text('25 Aug'), findsOneWidget);
    });
  });

  testWidgets("a category's transactions show their dates", (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.text('Food'));

    expect(find.text('3 Sep 2026'), findsOneWidget);
    expect(find.text('20 Sep 2026'), findsOneWidget);
  });

  testWidgets('an empty period says so', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Stats');

    expect(find.text('Nothing spent in this period'), findsOneWidget);
  });

  testWidgets('categories start open and trends are not built until opened', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    expect(find.text('Food'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('section titles are shaded apart from their reports', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Stats');

    final shade = Theme.of(tester.element(find.byType(StatsScreen))).colorScheme.surfaceContainerHigh;
    for (final title in ['Categories', 'Spending pace', 'Trends']) {
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, title)).tileColor, shade, reason: title);
    }
  });

  testWidgets('opening a section closes the one that was open', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.text('Trends'));

    expect(find.byType(LineChart), findsNWidgets(2));
    expect(find.text('Food'), findsNothing);
  });

  testWidgets('tapping the open section closes it', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.text('Categories'));

    expect(find.text('Food'), findsNothing);
    expect(find.text('Trends'), findsOneWidget);
  });

  testWidgets('trends section shows six months of net worth and a table', (tester) async {
    await pumpApp(tester, arrange: smallLedger);
    await openTab(tester, 'Stats');

    await tapAndSettle(tester, find.text('Trends'));

    expect(find.byType(LineChart), findsNWidgets(2));
    expect(find.byType(BarChart), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Apr 2026'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Apr 2026'), findsOneWidget);
    expect(find.text('৳1,300.00'), findsWidgets);
    expect(find.text('৳1,000.00'), findsWidgets);
  });

  testWidgets('trends shows the savings rate as a chart and in the table', (tester) async {
    await pumpApp(tester, arrange: spending);
    await openTab(tester, 'Stats');
    await tapAndSettle(tester, find.text('Trends'));

    await tester.scrollUntilVisible(find.text('Savings rate'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Savings rate'), findsOneWidget);
    final savingsChart = find.byType(LineChart).last;
    for (final label in ['0%', '50%', '100%']) {
      expect(
        find.descendant(of: savingsChart, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    final sep = find.widgetWithText(ListTile, 'Sep 2026');
    await tester.scrollUntilVisible(sep, 100, scrollable: find.byType(Scrollable).first);
    // Sep: ৳9,000 in, ৳500 out, so 94% is kept. Aug had no income.
    expect(find.descendant(of: sep, matching: find.textContaining('Kept 94%')), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(ListTile, 'Aug 2026'), matching: find.textContaining('Kept')),
      findsNothing,
    );
  });

  group('spending pace', () {
    Future<void> openPace(WidgetTester tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Spending pace'));
    }

    testWidgets('shows this month so far against the month before', (tester) async {
      await openPace(tester);

      expect(find.byType(LineChart), findsOneWidget);
      expect(find.text('Spent so far'), findsOneWidget);
      expect(find.text('৳500.00'), findsOneWidget);
      expect(find.text('৳500.00 more than Aug 2026 by this point'), findsOneWidget);
      // ৳500 at most, so the left axis runs ৳0 to ৳600 in steps of ৳200.
      for (final label in ['৳0', '৳200', '৳400', '৳600']) {
        expect(
          find.descendant(of: find.byType(LineChart), matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
    });

    testWidgets('yearly compares this year with the year before', (tester) async {
      await openPace(tester);

      await choosePeriodKind(tester, 'Year');

      // In the period bar and in the legend.
      expect(find.text('2026'), findsNWidgets(2));
      expect(find.text('৳1,000.00'), findsOneWidget);
      expect(find.text('৳1,000.00 more than 2025 by this point'), findsOneWidget);
    });

    testWidgets('a past month is compared as a whole', (tester) async {
      await openPace(tester);

      await tapAndSettle(tester, find.byTooltip('Previous'));

      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('Same as Jul 2026'), findsOneWidget);
    });

    testWidgets('loads its data only while the section is open', (tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');
      final container = ProviderScope.containerOf(tester.element(find.byType(StatsScreen)));

      expect(container.exists(paceTransactionsProvider), isFalse);
      await tapAndSettle(tester, find.text('Spending pace'));
      expect(container.exists(paceTransactionsProvider), isTrue);
      await tapAndSettle(tester, find.text('Spending pace'));
      expect(container.exists(paceTransactionsProvider), isFalse);
    });
  });

  group('trends history', () {
    IconButton arrow(WidgetTester tester, String tooltip) =>
        tester.widget(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)));

    Future<void> openTrends(WidgetTester tester) async {
      await pumpApp(tester, arrange: spending);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Trends'));
    }

    Future<void> seeRow(WidgetTester tester, String label) async {
      final row = find.widgetWithText(ListTile, label);
      await tester.scrollUntilVisible(row, 100, scrollable: find.byType(Scrollable).first);
      expect(row, findsOneWidget);
    }

    testWidgets('opens on the last six months and cannot go past this month', (tester) async {
      await openTrends(tester);

      expect(find.text('Apr – Sep 2026'), findsOneWidget);
      expect(arrow(tester, 'Next').onPressed, isNull);
      expect(arrow(tester, 'Previous').onPressed, isNotNull);
    });

    testWidgets('previous moves one month older and stops at the first entry', (tester) async {
      await openTrends(tester);

      await tapAndSettle(tester, find.byTooltip('Previous'));

      expect(find.text('Mar – Aug 2026'), findsOneWidget);
      expect(arrow(tester, 'Previous').onPressed, isNull);
      await seeRow(tester, 'Mar 2026');
      expect(find.text('Sep 2026'), findsNothing);
    });

    testWidgets('the arrows stay put when the label gets longer, so repeated taps land', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Trends'));
      await chooseScale(tester, 'Year');
      final before = tester.getCenter(find.byTooltip('Previous'));

      await chooseScale(tester, 'Month');

      expect(find.text('Apr – Sep 2026'), findsOneWidget);
      expect(tester.getCenter(find.byTooltip('Previous')), before);
    });

    testWidgets('next comes back toward this month', (tester) async {
      await openTrends(tester);
      await tapAndSettle(tester, find.byTooltip('Previous'));

      await tapAndSettle(tester, find.byTooltip('Next'));

      expect(find.text('Apr – Sep 2026'), findsOneWidget);
    });

    testWidgets('yearly shows six years ending this year', (tester) async {
      await openTrends(tester);

      await chooseScale(tester, 'Year');

      expect(find.text('2021 – 2026'), findsOneWidget);
      expect(arrow(tester, 'Previous').onPressed, isNull);
      await seeRow(tester, '2026');
      await seeRow(tester, '2021');
    });

    testWidgets('switching between monthly and yearly starts again at the latest', (tester) async {
      await openTrends(tester);
      await tapAndSettle(tester, find.byTooltip('Previous'));

      await chooseScale(tester, 'Year');
      await chooseScale(tester, 'Month');

      expect(find.text('Apr – Sep 2026'), findsOneWidget);
    });

    testWidgets('the window is kept while another section is open', (tester) async {
      await openTrends(tester);
      await tapAndSettle(tester, find.byTooltip('Previous'));

      await tapAndSettle(tester, find.text('Categories'));
      await tapAndSettle(tester, find.text('Trends'));

      expect(find.text('Mar – Aug 2026'), findsOneWidget);
    });
  });
}
