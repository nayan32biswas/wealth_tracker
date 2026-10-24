import 'package:drift/drift.dart';

import 'seed_data.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [AssetGroups, Assets, Categories, RecurringRules, Transactions, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e, {DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  final DateTime Function() clock;

  int get nowMs => clock().millisecondsSinceEpoch;

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedStarterData(this, nowMs);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
