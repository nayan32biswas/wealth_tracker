import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';

import 'harness.dart';

Future<void> rentRule(DriftRepositories repos, {DateTime? start}) async => repos.recurring.save(
  RecurringRule(
    id: 0,
    type: TransactionType.expense,
    amount: 2500000,
    assetId: (await repos.assets.all()).firstWhere((a) => a.name == 'Bank Account').id,
    categoryId: (await repos.categories.all()).firstWhere((c) => c.name == 'Rent').id,
    note: 'House rent',
    frequency: Frequency.monthly,
    startDate: start ?? DateTime(2026, 10, 5),
    nextDate: start ?? DateTime(2026, 10, 5),
  ),
);

Future<void> openRecurring(WidgetTester tester) async {
  await openTab(tester, 'Settings');
  await tapAndSettle(tester, find.text('Recurring'));
}

void main() {
  testWidgets('due recurring entries are created when the app starts', (tester) async {
    final app = await pumpApp(tester, arrange: (repos) => rentRule(repos, start: DateTime(2026, 8, 5)));

    final txns = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!;
    expect(txns.map((t) => t.dateTime), [DateTime(2026, 9, 5), DateTime(2026, 8, 5)]);
  });

  testWidgets('repeat on a new entry creates a rule starting with it', (tester) async {
    final app = await pumpApp(tester);
    await openNewTransaction(tester);

    await typeOnPad(tester, 'Amount', ['9', '9']);
    await pickCategory(tester, 'Mobile & Internet');
    await showMoreOptions(tester);
    await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<Frequency?>, 'Repeat'));
    await tapAndSettle(tester, find.text('Every month').last);
    await tapAndSettle(tester, find.text('Save'));

    final rule = (await tester.runAsync(app.repos.recurring.active))!.single;
    final txn = (await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery())))!.single;
    expect(rule.frequency, Frequency.monthly);
    expect(rule.amount, 9900);
    expect(rule.nextDate, DateTime(2026, 10, 23));
    expect(txn.recurringRuleId, rule.id);
    expect(txn.dateTime, testToday);
  });

  testWidgets('recurring screen lists rules with their schedule', (tester) async {
    await pumpApp(tester, arrange: rentRule);
    await openRecurring(tester);

    expect(find.text('House rent'), findsOneWidget);
    expect(find.textContaining('Every month'), findsOneWidget);
    expect(find.textContaining('Next 5 Oct 2026'), findsOneWidget);
  });

  testWidgets('editing a rule changes future amounts only', (tester) async {
    final app = await pumpApp(tester, arrange: rentRule);
    await openRecurring(tester);

    await tapAndSettle(tester, find.text('House rent'));
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '26000');
    await tester.pump();
    await tapAndSettle(tester, find.text('Save'));

    expect((await tester.runAsync(app.repos.recurring.active))!.single.amount, 2600000);
  });

  testWidgets('a rule can be paused and removed', (tester) async {
    final app = await pumpApp(tester, arrange: rentRule);
    await openRecurring(tester);

    await tapAndSettle(tester, find.text('House rent'));
    await tapAndSettle(tester, find.byType(Switch));
    await tapAndSettle(tester, find.text('Save'));
    expect(await tester.runAsync(app.repos.recurring.active), isEmpty);
    expect(find.textContaining('Paused'), findsOneWidget);

    await tapAndSettle(tester, find.text('House rent'));
    await tapAndSettle(tester, find.text('Remove'));
    expect(find.text('House rent'), findsNothing);
  });
}
