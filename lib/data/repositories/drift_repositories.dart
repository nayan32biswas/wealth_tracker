import 'package:drift/drift.dart';

import '../../domain/models/accounts.dart';
import '../../domain/models/app_settings.dart';
import '../../domain/models/categories.dart';
import '../../domain/models/enums.dart';
import '../../domain/repositories/repositories.dart';
import '../db/app_database.dart';
import '../db/seed_data.dart';
import 'drift_transactions.dart';

class DriftRepositories implements Repositories {
  factory DriftRepositories(AppDatabase db) {
    final transactions = DriftTransactionRepository(db);
    return DriftRepositories._(
      db,
      groups: DriftAssetGroupRepository(db),
      assets: DriftAssetRepository(db),
      categories: DriftCategoryRepository(db),
      transactions: transactions,
      recurring: DriftRecurringRuleRepository(db),
      settings: DriftSettingsRepository(db),
    );
  }

  DriftRepositories._(
    this._db, {
    required this.groups,
    required this.assets,
    required this.categories,
    required this.transactions,
    required this.recurring,
    required this.settings,
  });

  @override
  final DriftAssetGroupRepository groups;
  @override
  final DriftAssetRepository assets;
  @override
  final DriftCategoryRepository categories;
  @override
  final DriftTransactionRepository transactions;
  @override
  final DriftRecurringRuleRepository recurring;
  @override
  final DriftSettingsRepository settings;
  final AppDatabase _db;

  @override
  Future<T> inTransaction<T>(Future<T> Function() action) => _db.transaction(action);

  @override
  Future<void> resetToStarter() => _db.transaction(() async {
    for (final table in <TableInfo<Table, dynamic>>[
      _db.transactions,
      _db.recurringRules,
      _db.assets,
      _db.assetGroups,
      _db.categories,
    ]) {
      await _db.delete(table).go();
    }
    await seedStarterLedger(_db, _db.nowMs);
  });
}

Future<int> nextOrder(AppDatabase db, String table) async {
  final row = await db.customSelect('SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM "$table"').getSingle();
  return row.read<int>('next');
}

/// Clears the soft delete and moves the row to the end of its list.
Future<void> restoreRow(AppDatabase db, TableInfo<Table, dynamic> table, int id) async {
  final name = table.actualTableName;
  await db.customUpdate(
    'UPDATE "$name" SET is_deleted = 0, sort_order = ?, updated_at = ? WHERE id = ?',
    variables: [Variable.withInt(await nextOrder(db, name)), Variable.withInt(db.nowMs), Variable.withInt(id)],
    updates: {table},
  );
}

Future<void> applyOrder(AppDatabase db, TableInfo<Table, dynamic> table, List<int> idsInOrder) =>
    db.transaction(() async {
      for (final (i, id) in idsInOrder.indexed) {
        await db.customUpdate(
          'UPDATE "${table.actualTableName}" SET sort_order = ?, updated_at = ? WHERE id = ?',
          variables: [Variable.withInt(i), Variable.withInt(db.nowMs), Variable.withInt(id)],
          updates: {table},
        );
      }
    });

Future<int> countEntries(AppDatabase db, Expression<bool> Function($TransactionsTable t) where) async {
  final count = countAll();
  final query = db.selectOnly(db.transactions)
    ..addColumns([count])
    ..where(where(db.transactions));
  return (await query.getSingle()).read(count)!;
}

Future<bool> deleteIfUnused(
  AppDatabase db,
  TableInfo<Table, dynamic> table,
  int id, {
  required Expression<bool> Function($TransactionsTable t) entries,
  required Expression<bool> Function($RecurringRulesTable r) rules,
}) async {
  final made = db.selectOnly(db.transactions)
    ..addColumns([db.transactions.recurringRuleId])
    ..where(db.transactions.recurringRuleId.isNotNull());
  // A removed rule that never made an entry is a leftover; it shouldn't keep the row alive.
  await (db.delete(db.recurringRules)..where((r) => r.isDeleted & rules(r) & r.id.isNotInQuery(made))).go();
  final count = countAll();
  final ruleQuery = db.selectOnly(db.recurringRules)
    ..addColumns([count])
    ..where(rules(db.recurringRules));
  if ((await ruleQuery.getSingle()).read(count)! > 0 || await countEntries(db, entries) > 0) return false;
  await db.customUpdate(
    'DELETE FROM "${table.actualTableName}" WHERE id = ?',
    variables: [Variable.withInt(id)],
    updates: {table},
    updateKind: UpdateKind.delete,
  );
  return true;
}

class DriftAssetGroupRepository implements AssetGroupRepository {
  DriftAssetGroupRepository(this._db);

  final AppDatabase _db;

  SimpleSelectStatement<$AssetGroupsTable, AssetGroupRow> get _ordered =>
      _db.select(_db.assetGroups)
        ..orderBy([(g) => OrderingTerm(expression: g.sortOrder), (g) => OrderingTerm(expression: g.id)]);

  static AssetGroup _toModel(AssetGroupRow r) =>
      AssetGroup(id: r.id, name: r.name, type: GroupType.values.byName(r.type), order: r.sortOrder);

  @override
  Stream<List<AssetGroup>> watchAll() => _ordered.map(_toModel).watch();

  @override
  Future<List<AssetGroup>> all() => _ordered.map(_toModel).get();

  @override
  Future<int> add(String name, GroupType type) async => _db
      .into(_db.assetGroups)
      .insert(
        AssetGroupsCompanion.insert(
          name: name,
          type: Value(type.name),
          sortOrder: Value(await nextOrder(_db, 'asset_group')),
          createdAt: _db.nowMs,
          updatedAt: _db.nowMs,
        ),
      );

  @override
  Future<void> update(AssetGroup group) => (_db.update(_db.assetGroups)..where((g) => g.id.equals(group.id))).write(
    AssetGroupsCompanion(name: Value(group.name), type: Value(group.type.name), updatedAt: Value(_db.nowMs)),
  );

  @override
  Future<void> reorder(List<int> idsInOrder) => applyOrder(_db, _db.assetGroups, idsInOrder);

  @override
  Future<void> remove(int id) => _db.transaction(() async {
    final accounts = await (_db.select(_db.assets)..where((a) => a.assetGroupId.equals(id))).get();
    if (accounts.isNotEmpty) {
      throw const RuleViolation('Move or delete the accounts in this group first, archived ones too.');
    }
    await (_db.delete(_db.assetGroups)..where((g) => g.id.equals(id))).go();
  });
}

class DriftAssetRepository implements AssetRepository {
  DriftAssetRepository(this._db);

  final AppDatabase _db;

  SimpleSelectStatement<$AssetsTable, AssetRow> _rows({required bool archived}) => _db.select(_db.assets)
    ..where((a) => a.isArchived.equals(archived))
    ..orderBy([(a) => OrderingTerm(expression: a.sortOrder), (a) => OrderingTerm(expression: a.id)]);

  static Asset _toModel(AssetRow r) => Asset(
    id: r.id,
    name: r.name,
    groupId: r.assetGroupId,
    order: r.sortOrder,
    initialBalance: r.initialBalance,
    isArchived: r.isArchived,
  );

  @override
  Stream<List<Asset>> watchAll() => _rows(archived: false).map(_toModel).watch();

  @override
  Future<List<Asset>> all() => _rows(archived: false).map(_toModel).get();

  @override
  Stream<List<Asset>> watchArchived() => _rows(archived: true).map(_toModel).watch();

  @override
  Stream<Map<int, String>> watchNames() {
    final q = _db.selectOnly(_db.assets)..addColumns([_db.assets.id, _db.assets.name]);
    return q.watch().map((rows) => {for (final r in rows) r.read(_db.assets.id)!: r.read(_db.assets.name)!});
  }

  @override
  Future<int> add(String name, int groupId, {int initialBalance = 0}) async => _db
      .into(_db.assets)
      .insert(
        AssetsCompanion.insert(
          name: name,
          assetGroupId: groupId,
          initialBalance: Value(initialBalance),
          sortOrder: Value(await nextOrder(_db, 'asset')),
          createdAt: _db.nowMs,
          updatedAt: _db.nowMs,
        ),
      );

  @override
  Future<void> update(Asset asset) => (_db.update(_db.assets)..where((a) => a.id.equals(asset.id))).write(
    AssetsCompanion(
      name: Value(asset.name),
      assetGroupId: Value(asset.groupId),
      initialBalance: Value(asset.initialBalance),
      updatedAt: Value(_db.nowMs),
    ),
  );

  @override
  Future<void> reorder(List<int> idsInOrder) => applyOrder(_db, _db.assets, idsInOrder);

  @override
  Future<int> usage(int id) => countEntries(_db, (t) => t.assetId.equals(id) | t.toAssetId.equals(id));

  Future<void> _checkNoRule(int id) async {
    final rules =
        await (_db.select(_db.recurringRules)
              ..where((r) => r.isDeleted.equals(false))
              ..where((r) => r.assetId.equals(id) | r.toAssetId.equals(id)))
            .get();
    if (rules.isNotEmpty) {
      throw const RuleViolation('A recurring rule still uses this account. Remove the rule first.');
    }
  }

  @override
  Future<bool> remove(int id) => _db.transaction(() async {
    await _checkNoRule(id);
    final deleted = await deleteIfUnused(
      _db,
      _db.assets,
      id,
      entries: (t) => t.assetId.equals(id) | t.toAssetId.equals(id),
      rules: (r) => r.assetId.equals(id) | r.toAssetId.equals(id),
    );
    if (!deleted) await _setArchived(id, true);
    return deleted;
  });

  @override
  Future<void> archive(int id) => _db.transaction(() async {
    await _checkNoRule(id);
    await _setArchived(id, true);
  });

  @override
  Future<void> unarchive(int id) => _setArchived(id, false);

  Future<void> _setArchived(int id, bool archived) => (_db.update(
    _db.assets,
  )..where((a) => a.id.equals(id))).write(AssetsCompanion(isArchived: Value(archived), updatedAt: Value(_db.nowMs)));
}

class DriftCategoryRepository implements CategoryRepository {
  DriftCategoryRepository(this._db);

  final AppDatabase _db;

  SimpleSelectStatement<$CategoriesTable, CategoryRow> get _active => _rows(deleted: false);

  SimpleSelectStatement<$CategoriesTable, CategoryRow> _rows({required bool deleted}) => _db.select(_db.categories)
    ..where((c) => c.isDeleted.equals(deleted))
    ..orderBy([(c) => OrderingTerm(expression: c.sortOrder), (c) => OrderingTerm(expression: c.id)]);

  static Category _toModel(CategoryRow r) => Category(
    id: r.id,
    name: r.name,
    type: CategoryType.values.byName(r.type),
    order: r.sortOrder,
    feeType: FeeType.values.byName(r.feeType),
    feeValue: r.feeValue,
  );

  @override
  Stream<List<Category>> watchAll() => _active.map(_toModel).watch();

  @override
  Stream<Map<int, String>> watchNames() {
    final q = _db.selectOnly(_db.categories)..addColumns([_db.categories.id, _db.categories.name]);
    return q.watch().map((rows) => {for (final r in rows) r.read(_db.categories.id)!: r.read(_db.categories.name)!});
  }

  @override
  Future<List<Category>> all() => _active.map(_toModel).get();

  @override
  Stream<List<Category>> watchDeleted() => _rows(deleted: true).map(_toModel).watch();

  @override
  Future<void> restore(int id) => restoreRow(_db, _db.categories, id);

  @override
  Future<int> add(String name, CategoryType type) async => _db
      .into(_db.categories)
      .insert(
        CategoriesCompanion.insert(
          name: name,
          type: type.name,
          sortOrder: Value(await nextOrder(_db, 'category')),
          createdAt: _db.nowMs,
          updatedAt: _db.nowMs,
        ),
      );

  @override
  Future<void> update(Category category) => (_db.update(_db.categories)..where((c) => c.id.equals(category.id))).write(
    CategoriesCompanion(
      name: Value(category.name),
      feeType: Value(category.feeType.name),
      feeValue: Value(category.feeValue),
      updatedAt: Value(_db.nowMs),
    ),
  );

  @override
  Future<void> reorder(List<int> idsInOrder) => applyOrder(_db, _db.categories, idsInOrder);

  @override
  Future<int> usage(int id) => countEntries(_db, (t) => t.categoryId.equals(id));

  @override
  Future<void> remove(int id) => _db.transaction(() async {
    final deleted = await deleteIfUnused(
      _db,
      _db.categories,
      id,
      entries: (t) => t.categoryId.equals(id),
      rules: (r) => r.categoryId.equals(id),
    );
    if (deleted) return;
    await (_db.update(_db.categories)..where((c) => c.id.equals(id))).write(
      CategoriesCompanion(isDeleted: const Value(true), updatedAt: Value(_db.nowMs)),
    );
  });

  @override
  Future<void> merge(int fromId, int intoId) => _db.transaction(() async {
    final rows = {
      for (final c in await (_db.select(_db.categories)..where((c) => c.id.isIn([fromId, intoId]))).get()) c.id: c,
    };
    final (from, into) = (rows[fromId], rows[intoId]);
    if (fromId == intoId || from == null || into == null || into.isDeleted || from.type != into.type) {
      throw const RuleViolation('Pick another category of the same type.');
    }
    final now = _db.nowMs;
    await (_db.update(_db.transactions)..where((t) => t.categoryId.equals(fromId))).write(
      TransactionsCompanion(categoryId: Value(intoId), updatedAt: Value(now)),
    );
    await (_db.update(_db.recurringRules)..where((r) => r.categoryId.equals(fromId))).write(
      RecurringRulesCompanion(categoryId: Value(intoId), updatedAt: Value(now)),
    );
    await (_db.delete(_db.categories)..where((c) => c.id.equals(fromId))).go();
  });
}

class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._db);

  final AppDatabase _db;

  static AppSettings _toModel(List<SettingRow> rows) => AppSettings.fromMap({for (final r in rows) r.key: r.value});

  @override
  Stream<AppSettings> watch() => _db.select(_db.settings).watch().map(_toModel);

  @override
  Future<AppSettings> get() async => _toModel(await _db.select(_db.settings).get());

  @override
  Future<void> save(AppSettings settings) => _db.batch(
    (b) => b.insertAllOnConflictUpdate(_db.settings, [
      for (final e in settings.toMap().entries) SettingsCompanion.insert(key: e.key, value: e.value),
    ]),
  );
}
