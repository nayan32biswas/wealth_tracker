import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/app_settings.dart';
import 'package:wealthtracker/domain/services/calendar.dart';
import 'package:wealthtracker/presentation/features/accounts/accounts_screen.dart';
import 'package:wealthtracker/presentation/features/settings/categories_screen.dart';
import 'package:wealthtracker/presentation/features/settings/settings_screen.dart';
import 'package:wealthtracker/presentation/features/stats/category_screen.dart';
import 'package:wealthtracker/presentation/features/transactions/search_screen.dart';
import 'package:wealthtracker/presentation/widgets/common.dart';
import 'package:wealthtracker/presentation/widgets/period_switcher.dart';

import 'harness.dart';

void main() {
  testWidgets('bottom navigation has the four main sections', (tester) async {
    await pumpApp(tester);

    final labels = find.descendant(of: find.byType(NavigationBar), matching: find.byType(NavigationDestination));
    expect(labels, findsNWidgets(4));
    for (final label in ['Activity', 'Stats', 'Accounts', 'Settings']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget);
    }
  });

  testWidgets('stats, accounts and settings show no page title: the tab names them', (tester) async {
    await pumpApp(tester);

    for (final tab in ['Stats', 'Accounts', 'Settings']) {
      await openTab(tester, tab);
      expect(find.byType(AppBar), findsNothing, reason: tab);
      expect(find.text(tab), findsOneWidget, reason: '$tab: only the tab label');
    }
  });

  testWidgets('the tab bar is a compact 64 px', (tester) async {
    await pumpApp(tester);

    expect(tester.getSize(find.byType(NavigationBar)).height, 64);
  });

  testWidgets('back on a main tab closes the app without asking', (tester) async {
    await pumpApp(tester);
    final closes = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') closes.add(call);
      return null;
    });

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(closes, hasLength(1));
  });

  testWidgets('back on a pushed screen goes back', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Settings');
    await tapAndSettle(tester, find.text('Categories'));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Accounts and groups'), findsOneWidget);
  });

  group('switching tabs starts the tab fresh', () {
    Future<void> away(WidgetTester tester, String tab) async {
      await openTab(tester, tab == 'Activity' ? 'Settings' : 'Activity');
      await openTab(tester, tab);
    }

    testWidgets('stats closes the category detail', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Shopping'));
      expect(find.byType(CategoryScreen), findsOneWidget);

      await away(tester, 'Stats');

      expect(find.byType(CategoryScreen), findsNothing);
      expect(find.text('Total spent'), findsOneWidget);
      expect(find.text('Sep 2026'), findsOneWidget);
    });

    testWidgets('stats goes back to this month, expenses and Categories open', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Stats');
      await tapAndSettle(tester, find.text('Income'));
      await tapAndSettle(tester, find.byTooltip('Previous'));
      await tapAndSettle(tester, find.text('Trends'));

      await away(tester, 'Stats');

      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('Total spent'), findsOneWidget);
    });

    testWidgets('activity goes back to this month in the daily view', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await tapAndSettle(tester, find.byTooltip('Previous'));
      await choosePeriodKind(tester, 'Monthly');

      await away(tester, 'Activity');

      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('New shoes'), findsOneWidget);
    });

    testWidgets('activity closes search', (tester) async {
      await pumpApp(tester);
      await tapAndSettle(tester, find.byTooltip('Search'));

      await away(tester, 'Activity');

      expect(find.byType(SearchScreen), findsNothing);
    });

    testWidgets('accounts closes the account detail', (tester) async {
      await pumpApp(tester, arrange: smallLedger);
      await openTab(tester, 'Accounts');
      await tapAndSettle(tester, find.widgetWithText(ListTile, 'Credit Card'));
      expect(find.byType(AccountDetailScreen), findsOneWidget);

      await away(tester, 'Accounts');

      expect(find.byType(AccountDetailScreen), findsNothing);
    });

    testWidgets('settings closes its sub screens', (tester) async {
      await pumpApp(tester);
      await openTab(tester, 'Settings');
      await tapAndSettle(tester, find.text('Categories'));

      await away(tester, 'Settings');

      expect(find.byType(CategoriesScreen), findsNothing);
      expect(find.text('Preferences'), findsOneWidget);
    });

    testWidgets('tapping the open tab closes its sub screen', (tester) async {
      await pumpApp(tester);
      await openTab(tester, 'Settings');
      await tapAndSettle(tester, find.text('Categories'));

      await openTab(tester, 'Settings');

      expect(find.byType(CategoriesScreen), findsNothing);
      expect(find.text('Preferences'), findsOneWidget);
    });
  });

  testWidgets('the tab bar cannot be used while a busy spinner shows', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Settings');
    final work = Completer<String>();
    final done = whileBusy(tester.element(find.byType(SettingsScreen)), 'Working…', work.future);
    await tester.pump();

    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('Activity')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('Settings')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.text('Working…'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);

    work.complete('ok');
    expect(await done, 'ok');
    await tester.pumpAndSettle();
    expect(find.text('Working…'), findsNothing);
  });

  testWidgets('the app opens on Activity', (tester) async {
    await pumpApp(tester);

    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(find.byTooltip('Add transaction'), findsOneWidget);
    expect(find.text('Sep 2026'), findsOneWidget);
  });

  testWidgets('month switcher moves between months', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Activity');

    expect(find.text('Sep 2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Oct 2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous'));
    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('Aug 2026'), findsOneWidget);
  });

  testWidgets('activity has no view tabs and no week choice', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Activity');

    expect(find.byType(TabBar), findsNothing);
    await tapAndSettle(tester, find.byTooltip('Period type'));
    for (final label in ['Daily', 'Calendar', 'Monthly']) {
      expect(find.widgetWithText(PopupMenuItem<PeriodOption>, label), findsOneWidget);
    }
    expect(find.widgetWithText(PopupMenuItem<PeriodOption>, 'Custom'), findsNothing);
    expect(find.text('Week'), findsNothing);
  });

  testWidgets('activity period type and switcher share one line', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Activity');

    final label = tester.getCenter(find.text('Sep 2026'));
    final kind = tester.getCenter(find.byTooltip('Period type'));
    expect((label.dy - kind.dy).abs(), lessThan(4));

    await choosePeriodKind(tester, 'Monthly');
    expect(find.text('2026'), findsOneWidget);
    expect(find.text('January'), findsOneWidget);
  });

  testWidgets('tapping the month jumps to any older month', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Activity');

    await tapAndSettle(tester, find.text('Sep 2026'));
    await tapAndSettle(tester, find.byTooltip('Previous year'));
    await tapAndSettle(tester, find.text('Mar'));

    expect(find.text('Mar 2025'), findsOneWidget);
  });

  testWidgets('tapping the year jumps to any older year', (tester) async {
    await pumpApp(tester);
    await openTab(tester, 'Activity');
    await choosePeriodKind(tester, 'Monthly');

    await tapAndSettle(tester, find.text('2026'));
    await tapAndSettle(tester, find.text('2019'));

    expect(find.text('2019'), findsOneWidget);
  });

  testWidgets('amounts use the currency from settings', (tester) async {
    final app = await pumpApp(tester);
    expect(find.text('৳0.00'), findsWidgets);

    await tester.runAsync(() => app.repos.settings.save(const AppSettings(currencySymbol: r'$', currencyCode: 'USD')));
    await tester.pumpAndSettle();

    expect(find.text(r'$0.00'), findsWidgets);
  });

  group('period labels', () {
    test('calendar month', () {
      expect(periodLabel(Period.containing(PeriodKind.month, DateTime(2026, 9, 5))), 'Sep 2026');
    });

    test('month with a custom start day shows its range', () {
      expect(
        periodLabel(Period.containing(PeriodKind.month, DateTime(2026, 9, 5), monthStartDay: 25)),
        '25 Aug – 24 Sep 2026',
      );
    });

    test('year', () {
      expect(periodLabel(Period.containing(PeriodKind.year, DateTime(2026, 9, 23))), '2026');
    });

    test('range across years shows both years', () {
      expect(periodLabel(Period.custom(DateTime(2025, 12, 20), DateTime(2026, 1, 5))), '20 Dec 2025 – 5 Jan 2026');
    });
  });
}
