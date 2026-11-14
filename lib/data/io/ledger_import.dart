import 'package:drift/drift.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/ledger_import.dart';
import '../../domain/models/transactions.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/services/calendar.dart';
import '../db/app_database.dart';
import '../repositories/drift_repositories.dart';
import '../repositories/drift_transactions.dart';

/// The one writer behind database restore, CSV import and demo data; see
/// [Repositories.importLedger].
Future<void> importLedger(AppDatabase db, LedgerImport data, {bool replace = false}) => db.transaction(() async {
  if (ledgerProblem(data) case final problem?) throw RuleViolation(problem);
  final now = db.nowMs;

  if (replace) {
    for (final table in <TableInfo<Table, dynamic>>[
      db.transactions,
      db.recurringRules,
      db.assets,
      db.assetGroups,
      db.categories,
    ]) {
      await db.delete(table).go();
    }
  }

  // Replacing keeps the source's list order. Adding puts new rows at the end
  // and reuses what already has the same name, so a CSV or demo data never
  // makes a second "Cash".
  Future<int> order(String table, int sourceOrder) async => replace ? sourceOrder : nextOrder(db, table);
  final existingAccounts = replace ? <String, int>{} : await accountIdsByName(db);
  final existingCategories = replace ? <String, int>{} : await categoryIdsByKey(db);

  final groups = <int, int>{};
  for (final g in data.groups) {
    groups[g.id] = await db
        .into(db.assetGroups)
        .insert(
          AssetGroupsCompanion.insert(
            name: g.name,
            type: Value(g.type.name),
            sortOrder: Value(await order('asset_group', g.order)),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
  int? defaultGroup;
  Future<int> groupOf(int sourceId) async => groups[sourceId] ?? (defaultGroup ??= await _firstAssetGroup(db));

  final accounts = <int, int>{};
  for (final a in data.accounts) {
    accounts[a.id] =
        existingAccounts[a.name] ??
        await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: a.name,
                assetGroupId: await groupOf(a.groupId),
                sortOrder: Value(await order('asset', a.order)),
                initialBalance: Value(a.initialBalance),
                isArchived: Value(a.isArchived),
                createdAt: now,
                updatedAt: now,
              ),
            );
  }

  final categories = <int, int>{};
  for (final c in data.categories) {
    categories[c.id] =
        existingCategories[categoryKey(c.type, c.name)] ??
        await db
            .into(db.categories)
            .insert(
              CategoriesCompanion.insert(
                name: c.name,
                type: c.type.name,
                sortOrder: Value(await order('category', c.order)),
                isDeleted: Value(data.deletedCategoryIds.contains(c.id)),
                createdAt: now,
                updatedAt: now,
              ),
            );
  }

  final rules = <int, int>{};
  for (final r in data.rules) {
    rules[r.id] = await db
        .into(db.recurringRules)
        .insert(
          RecurringRulesCompanion.insert(
            type: r.type.name,
            amount: r.amount,
            assetId: accounts[r.assetId]!,
            toAssetId: Value(accounts[r.toAssetId]),
            categoryId: Value(categories[r.categoryId]),
            note: Value(r.note),
            frequency: r.frequency.name,
            interval: Value(r.interval),
            startDate: dateKey(r.startDate),
            endDate: Value(r.endDate == null ? null : dateKey(r.endDate!)),
            nextDate: dateKey(r.nextDate),
            isActive: Value(r.isActive),
            isDeleted: Value(data.deletedRuleIds.contains(r.id)),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  TransactionsCompanion row(Transaction t, Map<int, int> entries) => DriftTransactionRepository.toCompanion(
    t.copyWith(
      assetId: accounts[t.assetId],
      toAssetId: () => accounts[t.toAssetId],
      categoryId: () => categories[t.categoryId],
      recurringRuleId: () => rules[t.recurringRuleId],
      parentId: () => entries[t.parentId],
    ),
    now,
  ).copyWith(createdAt: Value(now));

  // An entry with a fee is inserted on its own to learn its new id; the
  // rest, fees included, go in one batch.
  final parents = {for (final t in data.transactions) ?t.parentId};
  final entries = <int, int>{};
  for (final t in data.transactions) {
    if (parents.contains(t.id)) entries[t.id] = await db.into(db.transactions).insert(row(t, entries));
  }
  await db.batch(
    (b) => b.insertAll(db.transactions, [
      for (final t in data.transactions)
        if (!parents.contains(t.id)) row(t, entries),
    ]),
  );

  if (data.settings case final map?) {
    await db.delete(db.settings).go();
    await DriftSettingsRepository(db).save(AppSettings.fromMap(map));
  }
});

/// Account name to id, archived accounts included; an active one wins when
/// two share a name.
Future<Map<String, int>> accountIdsByName(AppDatabase db) async => {
  for (final a in await (db.select(db.assets)..orderBy([(a) => OrderingTerm.desc(a.isArchived)])).get()) a.name: a.id,
};

/// [categoryKey] to id, for categories in use.
Future<Map<String, int>> categoryIdsByKey(AppDatabase db) async => {
  for (final c in await (db.select(db.categories)..where((c) => c.isDeleted.equals(false))).get())
    categoryKey(CategoryType.values.byName(c.type), c.name): c.id,
};

String categoryKey(CategoryType type, String name) => '${type.name}:$name';

Future<int> _firstAssetGroup(AppDatabase db) async {
  final groups = await (db.select(db.assetGroups)..orderBy([(g) => OrderingTerm(expression: g.sortOrder)])).get();
  if (groups.isEmpty) throw const RuleViolation('Add an account group first.');
  return groups.firstWhere((g) => g.type == GroupType.asset.name, orElse: () => groups.first).id;
}

/// The same rules the form and the database enforce, checked before
/// anything is written so the message can say which entry is wrong. A backup
/// is checked with these too, before the user is asked to replace anything.
String? ledgerProblem(LedgerImport data) {
  final groups = {for (final g in data.groups) g.id};
  final accounts = {for (final a in data.accounts) a.id};
  final categories = {for (final c in data.categories) c.id};
  final rules = {for (final r in data.rules) r.id};

  for (final a in data.accounts) {
    if (data.groups.isNotEmpty && !groups.contains(a.groupId)) return 'Account "${a.name}" has no group.';
  }
  String? entry(TransactionType type, int amount, int assetId, int? toAssetId, int? categoryId) {
    if (!accounts.contains(assetId)) return 'its account is missing';
    if (categoryId != null && !categories.contains(categoryId)) return 'its category is missing';
    if (type != TransactionType.transfer) return null;
    if (toAssetId == null || !accounts.contains(toAssetId)) return 'a transfer has no second account';
    if (toAssetId == assetId) return 'a transfer goes to the same account';
    return null;
  }

  // An entry may be 0, but a rule that repeats 0 makes no sense.
  for (final r in data.rules) {
    if (r.amount == 0) return 'A recurring rule: the amount is 0.';
    if (entry(r.type, r.amount, r.assetId, r.toAssetId, r.categoryId) case final p?) return 'A recurring rule: $p.';
  }
  final entries = {for (final t in data.transactions) t.id: t};
  final feeOwners = <int>{};
  for (final (i, t) in data.transactions.indexed) {
    if (entry(t.type, t.amount, t.assetId, t.toAssetId, t.categoryId) case final p?) return 'Entry ${i + 1}: $p.';
    if (t.recurringRuleId != null && !rules.contains(t.recurringRuleId)) {
      return 'Entry ${i + 1}: its recurring rule is missing.';
    }
    if (t.parentId case final parentId?) {
      final parent = entries[parentId];
      if (parent == null || parentId == t.id) return 'Entry ${i + 1}: the entry its fee belongs to is missing.';
      if (parent.isFee) return 'Entry ${i + 1}: a fee belongs to another fee.';
      if (t.type != TransactionType.expense) return 'Entry ${i + 1}: a fee is not an expense.';
      if (!feeOwners.add(parentId)) return 'Entry ${i + 1}: an entry has two fees.';
    }
  }
  return null;
}
