import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wealthtracker/data/device_files.dart';
import 'package:wealthtracker/data/device_security.dart';
import 'package:wealthtracker/data/ledger_store.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/demo_data.dart';
import 'package:wealthtracker/domain/services/recurring.dart';
import 'package:wealthtracker/domain/services/security.dart';
import 'package:wealthtracker/main.dart';
import 'package:wealthtracker/presentation/features/security/app_lock.dart';
import 'package:wealthtracker/presentation/features/security/secret_input.dart';
import 'package:wealthtracker/presentation/widgets/number_pad.dart';
import 'package:wealthtracker/presentation/widgets/pick_field.dart';

/// Whole user flows on a real device or emulator, through the same host the
/// app runs in: real SQLite files, restore, encryption and keystore. Each
/// test has its own database file, so the device's data is left alone. Only
/// the file picker and the share sheet are stood in for: they are system
/// screens a test can't drive.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late LedgerStore store;
  late _Files files;

  setUp(() async {
    dir = await (await getTemporaryDirectory()).createTemp('wt_flow');
    store = LedgerStore('${dir.path}/ledger.sqlite', NativeDatabase.createInBackground);
    await store.open();
    files = _Files(dir.path);
  });
  tearDown(() async {
    await store.db.close();
    await dir.delete(recursive: true);
  });

  /// Data and the lock are read for real, off the test's clock, so wait.
  Future<void> waitFor(WidgetTester tester, Finder finder, {int seconds = 20}) async {
    for (var i = 0; i < seconds * 10 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets);
  }

  /// Waits out spinners (encrypting, restoring) that never let the UI settle.
  Future<void> waitForWork(WidgetTester tester) async {
    for (var i = 0; i < 300 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await waitFor(tester, finder);
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    await tester.tap(finder.first);
    await tester.pumpAndSettle();
  }

  Future<void> startApp(WidgetTester tester, {PinVault? vault}) async {
    await tester.pumpWidget(
      LedgerHost(store, vault ?? PinVault(_MemorySecrets()), NativeScreenPrivacy(), files: files, key: UniqueKey()),
    );
  }

  Future<void> openTab(WidgetTester tester, String label) =>
      tap(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));

  Future<void> pick(WidgetTester tester, String field, String choice) async {
    await tap(tester, find.widgetWithText(PickField<int>, field));
    await tap(tester, find.text(choice).last);
  }

  Future<void> typeAmount(WidgetTester tester, List<String> keys) async {
    await tap(tester, find.widgetWithText(InputDecorator, 'Amount'));
    for (final key in keys) {
      await tester.tap(
        key == backspaceKey
            ? find.byTooltip('Backspace')
            : find.descendant(of: find.byType(NumberPad), matching: find.text(key)),
      );
      await tester.pump();
    }
    await tap(tester, find.byTooltip('Done'));
  }

  Future<void> typePin(WidgetTester tester, String pin, String submit) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.descendant(of: find.byType(PinPad), matching: find.text(digit)));
      await tester.pump();
    }
    await tap(tester, find.text(submit));
    await waitForWork(tester);
  }

  Future<Map<String, int>> balances() async {
    final repos = store.repos;
    final accounts = [...await repos.assets.all(), ...await repos.assets.watchArchived().first];
    final deltas = await repos.transactions.watchBalanceDeltas().first;
    return {for (final a in accounts) a.name: a.initialBalance + (deltas[a.id] ?? 0)};
  }

  Future<List<Transaction>> entries() => store.repos.transactions.find(const TransactionQuery());

  testWidgets('an entry is added, edited and deleted, and the balances follow', (tester) async {
    await startApp(tester);

    await tap(tester, find.byTooltip('Add transaction'));
    await pick(tester, 'Account', 'Cash');
    await pick(tester, 'Category', 'Food');
    await typeAmount(tester, ['2', '5', '0']);
    await tester.enterText(find.widgetWithText(TextField, 'Note'), 'Lunch at work');
    await tap(tester, find.text('Save'));

    await waitFor(tester, find.text('Lunch at work'));
    expect((await balances())['Cash'], -25000);

    await tap(tester, find.text('Lunch at work'));
    await typeAmount(tester, [backspaceKey, backspaceKey, backspaceKey, '9', '9']);
    await tap(tester, find.text('Save'));
    await waitFor(tester, find.text('Lunch at work'));
    expect((await balances())['Cash'], -9900);

    await tap(tester, find.byTooltip('Add transaction'));
    await tap(tester, find.text('Transfer'));
    await pick(tester, 'From', 'Bank Account');
    await pick(tester, 'To', 'Cash');
    await typeAmount(tester, ['1', '0', '0', '0']);
    await tap(tester, find.text('Save'));
    await waitFor(tester, find.text('→ Cash'));
    expect(await balances(), containsPair('Cash', 90100));
    expect(await balances(), containsPair('Bank Account', -100000));

    await tap(tester, find.text('Lunch at work'));
    await tap(tester, find.byTooltip('Delete'));
    await tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Lunch at work'), findsNothing);
    expect((await entries()).single.type, TransactionType.transfer);
    expect(await balances(), containsPair('Cash', 100000));

    await openTab(tester, 'Accounts');
    await waitFor(tester, find.text('৳1,000.00'));
  });

  testWidgets('a password-protected export restores the data as it was', (tester) async {
    await loadDemoData(store.repos, DateTime.now(), months: 2);
    // Done before the app starts, so the app's own catch-up adds nothing
    // while the test is counting.
    await applyDueRecurring(store.repos.recurring, DateTime.now());
    await store.repos.settings.save((await store.repos.settings.get()).copyWith(currencyCode: 'EUR'));
    final (count, money) = ((await entries()).length, await balances());
    await startApp(tester);

    await openTab(tester, 'Settings');
    await tap(tester, find.text('Export backup'));
    await tap(tester, find.text('Protect with a password'));
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'long enough');
    await tester.enterText(find.widgetWithText(TextField, 'Confirm password'), 'long enough');
    await tester.pump();
    await tap(tester, find.widgetWithText(FilledButton, 'Export'));
    await tap(tester, find.text('Share'));
    await waitForWork(tester);
    expect(files.shared.single, endsWith('.wtbackup'));
    final backup = File(files.shared.single).readAsBytesSync();

    // Data changed after the backup was made; restore must undo it.
    final cash = (await store.repos.assets.all()).firstWhere((a) => a.name == 'Cash');
    await store.repos.transactions.save(
      Transaction(
        id: 0,
        type: TransactionType.expense,
        amount: 123400,
        assetId: cash.id,
        categoryId: (await store.repos.categories.all()).first.id,
        dateTime: DateTime.now(),
      ),
    );
    await store.repos.settings.save((await store.repos.settings.get()).copyWith(currencyCode: 'BDT'));

    files.nextPick = backup;
    await tap(tester, find.text('Restore from backup'));
    await waitFor(tester, find.text('Backup password'));
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'long enough');
    await tester.pump();
    await tap(tester, find.widgetWithText(FilledButton, 'Open'));
    await waitForWork(tester);
    await tap(tester, find.text('Restore'));
    await waitFor(tester, find.byTooltip('Add transaction'));
    await waitForWork(tester);

    expect(await entries(), hasLength(count));
    expect(await balances(), money);
    expect((await store.repos.settings.get()).currencyCode, 'EUR');
    expect(File('${store.path}.old').existsSync(), isFalse);
  });

  testWidgets('a PIN set in Settings locks the app on the next start', (tester) async {
    // The phone's real keystore; cleared afterwards so the installed app is
    // not left locked.
    final vault = PinVault(KeychainSecretStore());
    await vault.clear();
    addTearDown(vault.clear);
    await startApp(tester, vault: vault);

    await openTab(tester, 'Settings');
    await tap(tester, find.text('App lock'));
    await typePin(tester, '1357', 'OK');
    await typePin(tester, '1357', 'OK');
    await waitFor(tester, find.text('Change PIN or password'));
    expect((await store.repos.settings.get()).lockEnabled, isTrue);

    // Start again, as after the app was closed.
    await tester.pumpWidget(const SizedBox());
    await store.db.close();
    await store.open();
    await startApp(tester, vault: vault);

    await waitFor(tester, find.byType(LockScreen));
    await typePin(tester, '0000', 'Unlock');
    await waitFor(tester, find.textContaining('Wrong PIN'));
    expect(find.byType(LockScreen), findsOneWidget);
    await typePin(tester, '1357', 'Unlock');

    expect(find.byType(LockScreen), findsNothing);
  });
}

class _Files implements FileGateway {
  _Files(this.dir);

  final String dir;
  Uint8List? nextPick;
  final shared = <String>[];
  @override
  Future<Uint8List?> pickFile() async => nextPick;

  @override
  Future<void> share(String path) async => shared.add(path);

  @override
  Future<bool> save(String fileName, Uint8List bytes) async => false;

  @override
  Future<String> tempDirectory() async => dir;

  @override
  Future<void> clearExports() async => clearExportsIn(dir);
}

class _MemorySecrets implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
