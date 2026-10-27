import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/transactions.dart';

import 'harness.dart';

Future<void> openBackupItem(WidgetTester tester, String item) async {
  await openTab(tester, 'Settings');
  await tapAndSettle(tester, find.text(item));
  await settleWork(tester);
}

/// Lets database work that waits on timers finish under the fake clock.
Future<void> settleWork(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> exportPlain(WidgetTester tester) async {
  await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Export'));
  await settleWork(tester);
}

Future<void> exportWithPassword(WidgetTester tester, String password) async {
  await tapAndSettle(tester, find.text('Protect with a password'));
  await enter(tester, 'Password', password);
  await enter(tester, 'Confirm password', password);
  await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Export'));
  await settleWork(tester);
}

final plainBackup = Uint8List.fromList([...ascii.encode('SQLite format 3'), 0, 1, 2, 3]);

void main() {
  testWidgets('export backup without a password shares a dated SQLite file', (tester) async {
    final app = await pumpApp(tester);

    await openBackupItem(tester, 'Export backup');
    expect(find.text('Password'), findsNothing);
    await exportPlain(tester);

    expect(app.files.shared.single, endsWith('wealthtracker-2026-09-23.sqlite'));
    expect(File(app.files.shared.single).existsSync(), isTrue);
  });

  testWidgets('export with a password shares an encrypted file and leaves no plain copy', (tester) async {
    final app = await pumpApp(tester);

    await openBackupItem(tester, 'Export backup');
    await exportWithPassword(tester, 'long enough');

    final shared = File(app.files.shared.single);
    expect(shared.path, endsWith('wealthtracker-2026-09-23.wtbackup'));
    final bytes = shared.readAsBytesSync();
    expect(ascii.decode(bytes.sublist(0, 8)), 'WTBACKUP');
    final plain = await app.cipher.decrypt(bytes, 'long enough');
    expect(ascii.decode(plain.sublist(0, 15)), 'SQLite format 3');
    expect(Directory(app.files.dir).listSync().where((f) => f.path.endsWith('.sqlite')), isEmpty);
  });

  testWidgets('an export first removes earlier exports, including the share copy', (tester) async {
    final app = await pumpApp(tester);
    final shareCopy = File('${app.files.dir}/share_plus/wealthtracker-2026-09-01.sqlite')..createSync(recursive: true);
    final oldCsv = File('${app.files.dir}/wealthtracker-2026-09-01.csv')..createSync();

    await openBackupItem(tester, 'Export backup');
    await exportPlain(tester);

    expect(shareCopy.existsSync(), isFalse);
    expect(oldCsv.existsSync(), isFalse);
    expect(File(app.files.shared.single).existsSync(), isTrue);
  });

  testWidgets('cancelling the export shares nothing', (tester) async {
    final app = await pumpApp(tester);

    await openBackupItem(tester, 'Export backup');
    await tapAndSettle(tester, find.text('Cancel'));
    await settleWork(tester);

    expect(app.files.shared, isEmpty);
  });

  testWidgets('export waits for matching passwords of at least 8 characters', (tester) async {
    await pumpApp(tester);
    await openBackupItem(tester, 'Export backup');
    VoidCallback? export() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export')).onPressed;

    await tapAndSettle(tester, find.text('Protect with a password'));
    expect(export(), isNull);
    await enter(tester, 'Password', 'short');
    await enter(tester, 'Confirm password', 'short');
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    expect(export(), isNull);

    await enter(tester, 'Password', 'long enough');
    await enter(tester, 'Confirm password', 'long enougX');
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(export(), isNull);

    await enter(tester, 'Confirm password', 'long enough');
    expect(export(), isNotNull);
  });

  testWidgets('switching protection off drops the typed password', (tester) async {
    final app = await pumpApp(tester);
    await openBackupItem(tester, 'Export backup');

    await tapAndSettle(tester, find.text('Protect with a password'));
    await enter(tester, 'Password', 'long enough');
    await enter(tester, 'Confirm password', 'long enough');
    await tapAndSettle(tester, find.text('Protect with a password'));
    expect(find.text('Password'), findsNothing);
    await exportPlain(tester);

    expect(app.files.shared.single, endsWith('.sqlite'));
  });

  testWidgets('an export clears earlier export files from the temp folder', (tester) async {
    final app = await pumpApp(tester);
    final stale = [
      for (final ext in ['sqlite', 'csv', 'wtbackup']) File('${app.files.dir}/wealthtracker-2026-09-01.$ext'),
    ];
    for (final file in stale) {
      file.writeAsStringSync('old');
    }

    await openBackupItem(tester, 'Export CSV');

    expect(stale.where((f) => f.existsSync()), isEmpty);
    expect(File(app.files.shared.single).existsSync(), isTrue);
  });

  testWidgets('a file error is explained instead of failing silently', (tester) async {
    final app = await pumpApp(tester);
    Directory(app.files.dir).deleteSync(recursive: true);

    await openBackupItem(tester, 'Export CSV');

    expect(find.text('Could not read or write the file. Check free space and try again.'), findsOneWidget);
    expect(app.files.shared, isEmpty);
  });

  testWidgets('export CSV shares a CSV file with a header', (tester) async {
    final app = await pumpApp(tester);

    await openBackupItem(tester, 'Export CSV');

    expect(app.files.shared.single, endsWith('.csv'));
    expect(File(app.files.shared.single).readAsStringSync(), startsWith('date,time,type'));
  });

  testWidgets('restore asks before replacing data', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = Uint8List.fromList([1, 2, 3]);

    await openBackupItem(tester, 'Restore from backup');
    expect(find.text('Replace all data?'), findsOneWidget);
    await tapAndSettle(tester, find.text('Restore'));

    expect(app.restorer.restored, endsWith('restore.sqlite'));
  });

  testWidgets('an encrypted backup asks for its password until it is right', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = await app.cipher.encrypt(plainBackup, 'right password');

    await openBackupItem(tester, 'Restore from backup');
    expect(find.text('Backup password'), findsOneWidget);
    await enter(tester, 'Password', 'wrong password');
    await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Open'));
    await settleWork(tester);
    expect(find.text('Wrong password, or the file is damaged.'), findsOneWidget);

    await enter(tester, 'Password', 'right password');
    await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Open'));
    await settleWork(tester);
    expect(find.text('Replace all data?'), findsOneWidget);
    await tapAndSettle(tester, find.text('Restore'));
    await settleWork(tester);

    expect(app.restorer.restoredBytes, plainBackup);
    expect(File(app.restorer.restored!).existsSync(), isFalse);
  });

  testWidgets('cancelling the password prompt restores nothing', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = await app.cipher.encrypt(plainBackup, 'right password');

    await openBackupItem(tester, 'Restore from backup');
    expect(find.text('Backup password'), findsOneWidget);
    await tapAndSettle(tester, find.text('Cancel'));
    await settleWork(tester);

    expect(find.text('Replace all data?'), findsNothing);
    expect(app.restorer.restored, isNull);
  });

  testWidgets('a file that cannot be restored is explained and nothing changes', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = Uint8List.fromList([1, 2, 3]);
    app.restorer.problem = 'This is not a Wealth Tracker backup.';

    await openBackupItem(tester, 'Restore from backup');

    expect(find.text('This is not a Wealth Tracker backup.'), findsOneWidget);
    expect(find.text('Replace all data?'), findsNothing);
    expect(app.restorer.restored, isNull);
  });

  testWidgets('CSV import shows a preview, then adds the rows', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = utf8.encode(
      'date,time,type,amount,fee,account,to_account,category,note\r\n'
      '2026-09-01,09:00,expense,120,0,Cash,,Pets,Cat food\r\n',
    );

    await openBackupItem(tester, 'Import CSV');
    expect(find.text('1 transactions ready'), findsOneWidget);
    expect(find.text('Expense: Pets'), findsOneWidget);
    app.backup.holdImport = Completer();
    await tester.tap(find.text('Import'));
    await tester.pump();
    expect(find.text('Importing transactions…'), findsOneWidget);
    app.backup.holdImport!.complete();
    await settleWork(tester);

    expect(find.text('Importing transactions…'), findsNothing);
    expect(find.text('1 transactions ready'), findsNothing);

    final saved = await tester.runAsync(() => app.repos.transactions.find(const TransactionQuery()));
    expect(saved!.single.note, 'Cat food');
  });

  testWidgets('CSV with errors cannot be imported', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = utf8.encode('wrong,header\r\n');

    await openBackupItem(tester, 'Import CSV');

    expect(find.textContaining('The first line must be'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Import')).onPressed, isNull);
  });
}
