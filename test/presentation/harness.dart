import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/device_files.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/backup_crypto.dart';
import 'package:wealthtracker/domain/services/security.dart';
import 'package:wealthtracker/presentation/app/app.dart';
import 'package:wealthtracker/presentation/app/providers.dart';
import 'package:wealthtracker/presentation/features/security/secret_input.dart';
import 'package:wealthtracker/presentation/widgets/number_pad.dart';
import 'package:wealthtracker/presentation/widgets/period_switcher.dart';

final testToday = DateTime(2026, 9, 23, 10);

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  /// Fails every call, like a keystore with a bad key.
  bool broken = false;

  void _check() {
    if (broken) throw const SecretStoreException('bad key');
  }

  @override
  Future<String?> read(String key) async {
    _check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }
}

class FakeBiometrics implements BiometricAuth {
  bool available = true;
  bool succeeds = true;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeeds;
  }
}

class FakeScreenPrivacy implements ScreenPrivacy {
  bool secure = false;

  @override
  Future<void> setSecure(bool value) async => secure = value;
}

class FakeFiles implements FileGateway {
  FakeFiles(this.dir);

  final String dir;
  Uint8List? nextPick;
  final shared = <String>[];

  @override
  Future<Uint8List?> pickFile() async => nextPick;

  @override
  Future<void> share(String path) async => shared.add(path);

  @override
  Future<String> tempDirectory() async => dir;

  @override
  Future<void> clearExports() async => clearExportsIn(dir);
}

/// The real backup service, except a test can hold an import open to see
/// what the screen shows meanwhile.
class HoldableBackup implements BackupService {
  HoldableBackup(this._inner);

  final BackupService _inner;
  Completer<void>? holdImport;

  @override
  Future<void> exportSqlite(String targetPath) => _inner.exportSqlite(targetPath);

  @override
  Future<String> exportCsv() => _inner.exportCsv();

  @override
  Future<CsvPreview> previewCsv(String text) => _inner.previewCsv(text);

  @override
  Future<void> importCsv(CsvPreview preview) async {
    await holdImport?.future;
    await _inner.importCsv(preview);
  }
}

class FakeRestorer implements DatabaseRestorer {
  String? problem;
  String? restored;
  Uint8List? restoredBytes;

  @override
  String? check(String path) => problem;

  // Keeps the bytes because the app deletes the file once restore returns.
  @override
  Future<void> restore(String path) async {
    restored = path;
    restoredBytes = File(path).readAsBytesSync();
  }
}

class TestApp {
  TestApp._(this.repos, this.vault, this.biometrics, this.privacy, this.files, this.restorer, this.cipher, this.backup);

  final DriftRepositories repos;
  final PinVault vault;
  final FakeBiometrics biometrics;
  final FakeScreenPrivacy privacy;
  final FakeFiles files;
  final FakeRestorer restorer;
  final BackupCipher cipher;
  final HoldableBackup backup;
}

/// A few entries across two months plus one upcoming rule.
Future<void> smallLedger(DriftRepositories repos) async {
  final assets = {for (final a in await repos.assets.all()) a.name: a};
  final categories = {for (final c in await repos.categories.all()) c.name: c.id};
  await repos.assets.update(assets['Cash']!.copyWith(initialBalance: 100000));
  await repos.transactions.save(
    Transaction(
      id: 0,
      type: TransactionType.expense,
      amount: 20000,
      assetId: assets['Credit Card']!.id,
      categoryId: categories['Shopping'],
      note: 'New shoes',
      dateTime: DateTime(2026, 9, 12, 16),
    ),
  );
  await repos.transactions.save(
    Transaction(
      id: 0,
      type: TransactionType.income,
      amount: 50000,
      assetId: assets['Bank Account']!.id,
      categoryId: categories['Bonus'],
      dateTime: DateTime(2026, 8, 30, 9),
    ),
  );
  await repos.recurring.save(
    RecurringRule(
      id: 0,
      type: TransactionType.expense,
      amount: 2500000,
      assetId: assets['Bank Account']!.id,
      categoryId: categories['Rent'],
      note: 'House rent',
      frequency: Frequency.monthly,
      startDate: DateTime(2026, 10, 5),
      nextDate: DateTime(2026, 10, 5),
    ),
  );
}

/// Replace to move time forward inside a test.
DateTime Function() testClock = () => testToday;

// Widget tests leave the in-memory database open: closing it in teardown can
// wait forever on work parked on the test's fake clock after a failure.
Future<TestApp> pumpApp(
  WidgetTester tester, {
  Future<void> Function(DriftRepositories repos)? arrange,
  Future<void> Function(PinVault vault)? arrangeVault,
  bool lockOnStart = false,
  MemorySecretStore? secrets,
  bool biometricSucceeds = true,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testClock = () => testToday;
  final db = AppDatabase(
    DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    clock: () => testToday,
  );
  final repos = DriftRepositories(db);
  final files = FakeFiles(Directory.systemTemp.createTempSync('wt_files').path);
  final restorer = FakeRestorer();
  final vault = PinVault(secrets ?? MemorySecretStore(), iterations: 10);
  final biometrics = FakeBiometrics()..succeeds = biometricSucceeds;
  final privacy = FakeScreenPrivacy();
  final cipher = BackupCipher(iterations: 10, offload: <R>(work) async => work());
  final backup = HoldableBackup(DriftBackupService(db, repos));
  var start = LockStart.open;
  await tester.runAsync(() async {
    await arrange?.call(repos);
    await arrangeVault?.call(vault);
    start = await LockStart.read(lockEnabled: lockOnStart, vault: vault);
  });

  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoriesProvider.overrideWithValue(repos),
        clockProvider.overrideWithValue(() => testClock()),
        pinVaultProvider.overrideWithValue(vault),
        biometricsProvider.overrideWithValue(biometrics),
        screenPrivacyProvider.overrideWithValue(privacy),
        lockOnStartProvider.overrideWithValue(start),
        backupProvider.overrideWithValue(backup),
        filesProvider.overrideWithValue(files),
        restorerProvider.overrideWithValue(restorer),
        backupCipherProvider.overrideWithValue(cipher),
      ],
      child: const WealthTrackerApp(),
    ),
  );
  await tester.pumpAndSettle();
  return TestApp._(repos, vault, biometrics, privacy, files, restorer, cipher, backup);
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

/// Taps [finder] after scrolling it into view (building it first if a lazy
/// list has not yet), then lets the UI settle.
Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final list = find.byType(Scrollable).first;
    try {
      await tester.scrollUntilVisible(finder, -200, scrollable: list, maxScrolls: 20);
    } on StateError {
      await tester.scrollUntilVisible(finder, 200, scrollable: list);
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String label, String text) async {
  await tester.enterText(find.widgetWithText(TextField, label), text);
  await tester.pump();
}

Future<void> openSettingsItem(WidgetTester tester, String item) async {
  await openTab(tester, 'Settings');
  await tapAndSettle(tester, find.text(item));
}

Future<void> openNewTransaction(WidgetTester tester) async {
  await openTab(tester, 'Activity');
  await tapAndSettle(tester, find.byTooltip('Add transaction'));
}

Future<void> pickCategory(WidgetTester tester, String name) async {
  await tapAndSettle(tester, find.widgetWithText(DropdownButtonFormField<int>, 'Category'));
  await tapAndSettle(tester, find.text(name).last);
}

Future<void> choosePeriodKind(WidgetTester tester, String kind) async {
  await tapAndSettle(tester, find.byTooltip('Period type'));
  await tapAndSettle(tester, find.widgetWithText(PopupMenuItem<PeriodOption>, kind));
}

Future<void> showMoreOptions(WidgetTester tester) => tapAndSettle(tester, find.text('More options'));

Future<void> typeOnPad(WidgetTester tester, String field, List<String> keys) async {
  await tapAndSettle(tester, find.widgetWithText(InputDecorator, field));
  for (final key in keys) {
    final finder = key == backspaceKey
        ? find.byTooltip('Backspace')
        : find.descendant(of: find.byType(NumberPad), matching: find.text(key));
    await tester.tap(finder);
    await tester.pump();
  }
  await tapAndSettle(tester, find.text('Done'));
}

Future<void> typePin(WidgetTester tester, String pin, {String submit = 'OK'}) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.descendant(of: find.byType(PinPad), matching: find.text(digit)));
    await tester.pump();
  }
  await tapAndSettle(tester, find.text(submit));
}
