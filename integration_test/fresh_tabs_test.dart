import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/device_files.dart';
import 'package:wealthtracker/data/device_security.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/demo_data.dart';
import 'package:wealthtracker/domain/services/security.dart';
import 'package:wealthtracker/presentation/app/app.dart';
import 'package:wealthtracker/presentation/app/providers.dart';
import 'package:wealthtracker/presentation/features/accounts/accounts_screen.dart';
import 'package:wealthtracker/presentation/features/settings/categories_screen.dart';
import 'package:wealthtracker/presentation/features/stats/category_screen.dart';
import 'package:wealthtracker/presentation/features/transactions/search_screen.dart';
import 'package:wealthtracker/presentation/features/transactions/transactions_screen.dart';

/// Each tab starts fresh after switching tabs, on a real device or emulator.
/// The app gets its own in-memory database and no lock, so the device's data
/// and PIN are left alone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final thisMonth = DateFormat('MMM yyyy').format(DateTime.now());

  Future<void> start(WidgetTester tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(NativeDatabase.memory());
    final repos = DriftRepositories(db);
    await loadDemoData(repos, DateTime.now(), months: 3);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoriesProvider.overrideWithValue(repos),
          pinVaultProvider.overrideWithValue(PinVault(_NoSecrets())),
          biometricsProvider.overrideWithValue(DeviceBiometrics()),
          screenPrivacyProvider.overrideWithValue(NativeScreenPrivacy()),
          filesProvider.overrideWithValue(DeviceFiles()),
          backupProvider.overrideWithValue(DriftBackupService(db, repos)),
          restorerProvider.overrideWithValue(_NoRestore()),
        ],
        child: const WealthTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Data loads for real on the device, so wait until [finder] shows up.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(finder.first);
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String label) =>
      tap(tester, find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));

  Future<void> periodKind(WidgetTester tester, String kind) async {
    await tap(tester, find.byTooltip('Period type'));
    await tap(tester, find.text(kind).last);
  }

  Finder shareRows() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ShareRow');

  testWidgets('1. stats closes the category detail', (tester) async {
    await start(tester);
    await tab(tester, 'Stats');
    await tap(tester, shareRows());
    expect(find.byType(CategoryScreen), findsOneWidget);

    await tab(tester, 'Activity');
    await tab(tester, 'Stats');

    expect(find.byType(CategoryScreen), findsNothing);
    expect(find.text('Total spent'), findsOneWidget);
  });

  testWidgets('2. stats resets type, month and open section', (tester) async {
    await start(tester);
    await tab(tester, 'Stats');
    await tap(tester, find.text('Income'));
    await tap(tester, find.byTooltip('Previous'));
    await tap(tester, find.text('Trends'));

    await tab(tester, 'Accounts');
    await tab(tester, 'Stats');

    expect(find.text('Total spent'), findsOneWidget);
    expect(find.text(thisMonth), findsOneWidget);
  });

  testWidgets('3. the trends window is kept while switching sections', (tester) async {
    await start(tester);
    await tab(tester, 'Stats');
    // Close Categories first: its long list pushes Trends off the screen.
    await tap(tester, find.text('Categories'));
    await tap(tester, find.text('Trends'));
    await tap(tester, find.byTooltip('Previous'));
    final range = find.textContaining(' – ');
    final earlier = tester.widget<Text>(range).data;

    await tap(tester, find.text('Spending pace'));
    await tap(tester, find.text('Trends'));

    expect(tester.widget<Text>(range).data, earlier);
  });

  testWidgets('4. activity goes back to this month in the daily view', (tester) async {
    await start(tester);
    await tap(tester, find.byTooltip('Previous'));
    await periodKind(tester, 'Monthly');
    expect(find.text(thisMonth), findsNothing);

    await tab(tester, 'Stats');
    await tab(tester, 'Activity');

    expect(find.text(thisMonth), findsOneWidget);
    expect(find.byType(DayList), findsOneWidget);
  });

  testWidgets('5. activity closes search', (tester) async {
    await start(tester);
    await tap(tester, find.byTooltip('Search'));
    expect(find.byType(SearchScreen), findsOneWidget);

    await tab(tester, 'Settings');
    await tab(tester, 'Activity');

    expect(find.byType(SearchScreen), findsNothing);
  });

  testWidgets('6. accounts closes the account detail', (tester) async {
    await start(tester);
    await tab(tester, 'Accounts');
    await tap(tester, find.widgetWithText(ListTile, 'Cash'));
    expect(find.byType(AccountDetailScreen), findsOneWidget);

    await tab(tester, 'Stats');
    await tab(tester, 'Accounts');

    expect(find.byType(AccountDetailScreen), findsNothing);
  });

  testWidgets('7. settings closes its sub screens', (tester) async {
    await start(tester);
    await tab(tester, 'Settings');
    await tap(tester, find.text('Categories'));
    expect(find.byType(CategoriesScreen), findsOneWidget);

    await tab(tester, 'Activity');
    await tab(tester, 'Settings');

    expect(find.byType(CategoriesScreen), findsNothing);
    expect(find.text('Preferences'), findsOneWidget);
  });

  testWidgets('8. tapping the open tab closes its sub screen', (tester) async {
    await start(tester);
    await tab(tester, 'Settings');
    await tap(tester, find.text('Categories'));

    await tab(tester, 'Settings');

    expect(find.byType(CategoriesScreen), findsNothing);
    expect(find.text('Preferences'), findsOneWidget);
  });

  testWidgets('9. back on a main tab asks, and cancel stays', (tester) async {
    await start(tester);
    await tab(tester, 'Stats');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Close Wealth Tracker?'), findsOneWidget);
    await tap(tester, find.text('Cancel'));

    expect(find.text('Close Wealth Tracker?'), findsNothing);
    expect(find.text('Total spent'), findsOneWidget);
  });

  testWidgets('10. back on a sub screen goes back without asking', (tester) async {
    await start(tester);
    await tab(tester, 'Settings');
    await tap(tester, find.text('Categories'));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Close Wealth Tracker?'), findsNothing);
    expect(find.byType(CategoriesScreen), findsNothing);
    expect(find.text('Preferences'), findsOneWidget);
  });
}

/// A keychain with no PIN in it, so the app starts unlocked.
class _NoSecrets implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _NoRestore implements DatabaseRestorer {
  @override
  String? check(String path) => 'Not used in this test';

  @override
  Future<void> restore(String path) async {}
}
