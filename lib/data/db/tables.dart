import 'package:drift/drift.dart';

const transactionTypes = ['income', 'expense', 'transfer'];
const categoryTypes = ['income', 'expense'];
const groupTypes = ['asset', 'liability'];
const feeTypes = ['none', 'percent', 'fixed'];
const frequencies = ['daily', 'weekly', 'monthly', 'yearly'];

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
  TextColumn get type => text().check(type.isIn(groupTypes)).withDefault(const Constant('asset'))();
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
  TextColumn get type => text().check(type.isIn(categoryTypes))();
  TextColumn get feeType => text().check(feeType.isIn(feeTypes)).withDefault(const Constant('none'))();
  IntColumn get feeValue => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

@DataClassName('RecurringRuleRow')
class RecurringRules extends Table with Timestamps {
  @override
  String get tableName => 'recurring_rule';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get note => text().nullable()();
  TextColumn get type => text().check(type.isIn(transactionTypes))();
  IntColumn get amount => integer()();
  IntColumn get fee => integer().withDefault(const Constant(0))();
  IntColumn get assetId => integer().references(Assets, #id)();
  IntColumn get toAssetId => integer().nullable().references(Assets, #id)();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  TextColumn get frequency => text().check(frequency.isIn(frequencies))();
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
  TextColumn get type => text().check(type.isIn(transactionTypes))();

  /// Income and expense may be negative (a refund, a reversal); a transfer may not.
  IntColumn get amount =>
      integer().check(amount.isNotValue(0) & (type.equals('transfer').not() | amount.isBiggerThanValue(0)))();
  IntColumn get fee => integer().check(fee.isBiggerOrEqualValue(0)).withDefault(const Constant(0))();
  IntColumn get assetId => integer().references(Assets, #id)();
  IntColumn get toAssetId => integer().nullable().references(Assets, #id)();
  IntColumn get categoryId => integer().nullable().references(Categories, #id)();
  IntColumn get recurringRuleId => integer().nullable().references(RecurringRules, #id)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {recurringRuleId, date},
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
