// Table declarations are read by drift_dev at build time and never run in the
// app, so they have no lines a test could cover.
// coverage:ignore-file

import 'package:drift/drift.dart';

// Enum columns (type, frequency) hold the Dart enum's name and have no CHECK:
// adding a value to a CHECK means rebuilding the table, while the enums
// already reject unknown values when a row is read or imported.

mixin Timestamps on Table {
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
}

@DataClassName('AssetGroupRow')
class AssetGroups extends Table with Timestamps {
  @override
  String get tableName => 'asset_group';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get type => text().withDefault(const Constant('asset'))();
}

@DataClassName('AssetRow')
class Assets extends Table with Timestamps {
  @override
  String get tableName => 'asset';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get assetGroupId => integer().references(AssetGroups, #id)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get initialBalance => integer().withDefault(const Constant(0))();

  /// Hidden from pickers but still counted in every balance. An account with
  /// entries is archived instead of deleted, so its money can never drop out
  /// of net worth.
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
}

@DataClassName('CategoryRow')
class Categories extends Table with Timestamps {
  @override
  String get tableName => 'category';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get type => text()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

@DataClassName('RecurringRuleRow')
class RecurringRules extends Table with Timestamps {
  @override
  String get tableName => 'recurring_rule';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get note => text().nullable()();
  TextColumn get type => text()();
  IntColumn get amount => integer()();
  IntColumn get assetId => integer().references(Assets, #id)();
  IntColumn get toAssetId => integer().nullable().references(Assets, #id)();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  TextColumn get frequency => text()();
  IntColumn get interval => integer().withDefault(const Constant(1))();
  TextColumn get startDate => text()();
  TextColumn get endDate => text().nullable()();
  TextColumn get nextDate => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

// One index per column the lists filter on. `time` serves the newest-first
// order, so a page of search results stops after the first 200 rows.
@DataClassName('TransactionRow')
@TableIndex(name: 'idx_transaction_date', columns: {#date})
@TableIndex(name: 'idx_transaction_time', columns: {#time})
@TableIndex(name: 'idx_transaction_asset', columns: {#assetId})
@TableIndex(name: 'idx_transaction_to_asset', columns: {#toAssetId})
@TableIndex(name: 'idx_transaction_category', columns: {#categoryId})
class Transactions extends Table with Timestamps {
  @override
  String get tableName => 'transaction';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get note => text().nullable()();

  /// Epoch milliseconds.
  IntColumn get time => integer()();

  /// Local calendar date `YYYY-MM-DD`, used for grouping by day/month.
  TextColumn get date => text()();
  TextColumn get type => text()();

  /// Any sign. A negative amount works against its total: a refund lowers
  /// expense, a negative transfer moves money from the target back to the
  /// source. Zero is allowed, e.g. a free item kept for the record.
  IntColumn get amount => integer()();
  IntColumn get assetId => integer().references(Assets, #id)();
  IntColumn get toAssetId => integer().nullable().references(Assets, #id)();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get recurringRuleId => integer().nullable().references(RecurringRules, #id)();

  /// Set on a fee or tax saved as its own expense for another entry. It is
  /// edited and deleted with that entry, and an entry has at most one.
  IntColumn get parentId => integer().nullable().references(Transactions, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {recurringRuleId, date},
    {parentId},
  ];
}

@DataClassName('SettingRow')
class Settings extends Table {
  @override
  String get tableName => 'setting';

  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
