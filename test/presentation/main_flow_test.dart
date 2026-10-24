import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/enums.dart';

import 'harness.dart';

/// The main path through the app, end to end on one ledger.
void main() {
  testWidgets('lock, set up, record, review and back up', (tester) async {
    final app = await pumpApp(tester);

    await openSettingsItem(tester, 'App lock');
    await typePin(tester, '1234');
    await typePin(tester, '1234');

    await tapAndSettle(tester, find.text('Accounts and groups'));
    await tapAndSettle(tester, find.text('Bank'));
    await tapAndSettle(tester, find.byTooltip('Add account'));
    await enter(tester, 'Name', 'Savings');
    await enter(tester, 'Opening balance', '5000');
    await tapAndSettle(tester, find.text('Save'));
    await tapAndSettle(tester, find.byTooltip('Back'));
    await tapAndSettle(tester, find.byTooltip('Back'));

    await tapAndSettle(tester, find.text('Categories'));
    await tapAndSettle(tester, find.text('Utilities'));
    await tapAndSettle(tester, find.text('Fixed'));
    await enter(tester, 'Fee amount', '10');
    await tapAndSettle(tester, find.text('Save'));
    await tapAndSettle(tester, find.byTooltip('Back'));

    await openNewTransaction(tester);
    await typeOnPad(tester, 'Amount', ['5', '0', '0']);
    await pickCategory(tester, 'Utilities');
    await tapAndSettle(tester, find.text('Save'));

    await openNewTransaction(tester);
    await typeOnPad(tester, 'Amount', ['1', '5', '0', '0', '0']);
    await pickCategory(tester, 'Rent');
    await showMoreOptions(tester);
    await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<Frequency?>, 'Repeat'));
    await tapAndSettle(tester, find.text('Every month').last);
    await tapAndSettle(tester, find.text('Save'));

    await openTab(tester, 'Accounts');
    expect(find.text('-৳15,510.00'), findsWidgets);
    expect(find.text('-৳10,510.00'), findsWidgets);

    await openTab(tester, 'Stats');
    expect(find.text('97%'), findsOneWidget);
    expect(find.text('3%'), findsOneWidget);

    await openTab(tester, 'Activity');
    expect(find.text('Rent'), findsWidgets);

    await openTab(tester, 'Settings');
    await tapAndSettle(tester, find.text('Export backup'));
    await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Export'));
    await tapAndSettle(tester, find.text('Export CSV'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(app.files.shared.map((f) => f.split('.').last), ['sqlite', 'csv']);
    expect(File(app.files.shared.last).readAsLinesSync(), hasLength(3));
    expect(await tester.runAsync(() => app.vault.verify('1234')), isTrue);
  });
}
