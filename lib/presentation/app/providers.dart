import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/accounts.dart';
import '../../domain/models/app_settings.dart';
import '../../domain/models/categories.dart';
import '../../domain/models/transactions.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/services/backup_crypto.dart';
import '../../domain/services/calendar.dart';
import '../../domain/services/money.dart';
import '../../domain/services/reports.dart';
import '../../domain/services/security.dart';

final repositoriesProvider = Provider<Repositories>((ref) => throw UnimplementedError('Provided by main()'));

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final settingsStreamProvider = StreamProvider<AppSettings>((ref) => ref.watch(repositoriesProvider).settings.watch());

final settingsProvider = Provider<AppSettings>((ref) => ref.watch(settingsStreamProvider).value ?? const AppSettings());

final moneyFormatProvider = Provider<MoneyFormat>((ref) => MoneyFormat.of(ref.watch(settingsProvider)));

final groupsProvider = StreamProvider<List<AssetGroup>>((ref) => ref.watch(repositoriesProvider).groups.watchAll());

final assetsProvider = StreamProvider<List<Asset>>((ref) => ref.watch(repositoriesProvider).assets.watchAll());

final archivedAssetsProvider = StreamProvider<List<Asset>>(
  (ref) => ref.watch(repositoriesProvider).assets.watchArchived(),
);

final categoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(repositoriesProvider).categories.watchAll(),
);

final balanceDeltasProvider = StreamProvider<Map<int, int>>(
  (ref) => ref.watch(repositoriesProvider).transactions.watchBalanceDeltas(),
);

final balanceSheetProvider = FutureProvider<BalanceSheet>(
  (ref) async => BalanceSheet.from(
    await ref.watch(groupsProvider.future),
    // Archived accounts still hold their money, so they count too.
    [...await ref.watch(assetsProvider.future), ...await ref.watch(archivedAssetsProvider.future)],
    await ref.watch(balanceDeltasProvider.future),
  ),
);

class PeriodController extends Notifier<Period> {
  PeriodController(this.kind);

  final PeriodKind kind;

  @override
  Period build() {
    final s = ref.watch(settingsProvider);
    return Period.containing(kind, ref.watch(clockProvider)(), monthStartDay: s.monthStartDay);
  }

  void next() => state = state.next();

  void previous() => state = state.previous();

  void set(Period period) => state = period;
}

final transactionsPeriodProvider = NotifierProvider.autoDispose<PeriodController, Period>(
  () => PeriodController(PeriodKind.month),
);

final assetNamesProvider = StreamProvider<Map<int, String>>(
  (ref) => ref.watch(repositoriesProvider).assets.watchNames(),
);

final categoryNamesProvider = StreamProvider<Map<int, String>>(
  (ref) => ref.watch(repositoriesProvider).categories.watchNames(),
);

final periodTransactionsProvider = StreamProvider.autoDispose<List<Transaction>>((ref) {
  final period = ref.watch(transactionsPeriodProvider);
  return ref
      .watch(repositoriesProvider)
      .transactions
      .watch(TransactionQuery(from: period.start, toExclusive: period.endExclusive));
});

final monthlyFlowsProvider = StreamProvider<List<MonthlyFlow>>(
  (ref) => ref.watch(repositoriesProvider).transactions.watchMonthlyFlows(),
);

final pinVaultProvider = Provider<PinVault>((ref) => throw UnimplementedError('Provided by main()'));

final biometricsProvider = Provider<BiometricAuth>((ref) => throw UnimplementedError('Provided by main()'));

final screenPrivacyProvider = Provider<ScreenPrivacy>((ref) => throw UnimplementedError('Provided by main()'));

/// Worked out before the first frame so no data flashes before the lock.
final lockOnStartProvider = Provider<LockStart>((ref) => LockStart.open);

final backupProvider = Provider<BackupService>((ref) => throw UnimplementedError('Provided by main()'));

final filesProvider = Provider<FileGateway>((ref) => throw UnimplementedError('Provided by main()'));

final restorerProvider = Provider<DatabaseRestorer>((ref) => throw UnimplementedError('Provided by main()'));

final backupCipherProvider = Provider<BackupCipher>((ref) => BackupCipher());
