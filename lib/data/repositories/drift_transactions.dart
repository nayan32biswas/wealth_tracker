import 'package:drift/drift.dart';

import '../../domain/models/enums.dart';
import '../../domain/models/transactions.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/services/calendar.dart';
import '../db/app_database.dart';

class DriftTransactionRepository implements TransactionRepository {
  DriftTransactionRepository(this._db);

  final AppDatabase _db;

  static Transaction toModel(TransactionRow r) => Transaction(
    id: r.id,
    type: TransactionType.values.byName(r.type),
    amount: r.amount,
    fee: r.fee,
    assetId: r.assetId,
    toAssetId: r.toAssetId,
    categoryId: r.categoryId,
    note: r.note,
    dateTime: DateTime.fromMillisecondsSinceEpoch(r.time),
    recurringRuleId: r.recurringRuleId,
  );

  static TransactionsCompanion toCompanion(Transaction t, int now) => TransactionsCompanion(
    type: Value(t.type.name),
    amount: Value(t.amount),
    fee: Value(t.fee),
    assetId: Value(t.assetId),
    toAssetId: Value(t.type == TransactionType.transfer ? t.toAssetId : null),
    categoryId: Value(t.type == TransactionType.transfer ? null : t.categoryId),
    note: Value(t.note),
    time: Value(t.dateTime.millisecondsSinceEpoch),
    date: Value(dateKey(t.dateTime)),
    recurringRuleId: Value(t.recurringRuleId),
    updatedAt: Value(now),
  );

  static Expression<bool> _matches($TransactionsTable t, TransactionQuery q) {
    Expression<bool> e = const Constant(true);
    if (q.from != null) e &= t.date.isBiggerOrEqualValue(dateKey(q.from!));
    if (q.toExclusive != null) e &= t.date.isSmallerThanValue(dateKey(q.toExclusive!));
    if (q.text?.trim().isNotEmpty ?? false) e &= t.note.like('%${_escapeLike(q.text!.trim())}%', escapeChar: '!');
    if (q.types != null) e &= t.type.isIn(q.types!.map((x) => x.name));
    if (q.assetIds case final ids? when ids.isNotEmpty) e &= t.assetId.isIn(ids) | t.toAssetId.isIn(ids);
    if (q.categoryIds case final ids? when ids.isNotEmpty) e &= t.categoryId.isIn(ids);
    return e;
  }

  Selectable<Transaction> _select(TransactionQuery q) {
    final s = _db.select(_db.transactions);
    s.where((t) => _matches(t, q));
    // Same rule as Transaction.total: income arrives net of its fee.
    Expression<int> moved($TransactionsTable t) => CaseWhenExpression<int>(
      cases: [CaseWhen(t.type.equals(TransactionType.income.name), then: t.amount - t.fee)],
      orElse: t.amount + t.fee,
    );
    s.orderBy([
      if (q.sort == TransactionSort.largest) (t) => OrderingTerm.desc(moved(t)),
      if (q.sort == TransactionSort.smallest) (t) => OrderingTerm.asc(moved(t)),
      (t) => OrderingTerm.desc(t.time),
      (t) => OrderingTerm.desc(t.id),
    ]);
    if (q.limit != null) s.limit(q.limit!);
    return s.map(toModel);
  }

  @override
  Stream<List<Transaction>> watch(TransactionQuery query) => _select(query).watch();

  @override
  Stream<({int income, int expense})> watchTotals(TransactionQuery query) {
    final t = _db.transactions;
    Expression<int> sumOf(TransactionType type, Expression<int> value) => CaseWhenExpression<int>(
      cases: [CaseWhen(t.type.equals(type.name), then: value)],
      orElse: const Constant(0),
    ).sum();
    final income = sumOf(TransactionType.income, t.amount - t.fee);
    final expense = sumOf(TransactionType.expense, t.amount + t.fee);
    final q = _db.selectOnly(t)
      ..addColumns([income, expense])
      ..where(_matches(t, query));
    return q.watchSingle().map((r) => (income: r.read(income) ?? 0, expense: r.read(expense) ?? 0));
  }

  @override
  Future<List<Transaction>> find(TransactionQuery query) => _select(query).get();

  @override
  Future<Transaction?> byId(int id) =>
      (_db.select(_db.transactions)..where((t) => t.id.equals(id))).map(toModel).getSingleOrNull();

  @override
  Future<int> save(Transaction t) async {
    final row = toCompanion(t, _db.nowMs);
    if (t.id == 0) {
      return _db.into(_db.transactions).insert(row.copyWith(createdAt: Value(_db.nowMs)));
    }
    await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(row);
    return t.id;
  }

  @override
  Future<void> delete(int id) => (_db.delete(_db.transactions)..where((t) => t.id.equals(id))).go();

  @override
  Future<bool> hasAny() async =>
      await _db.customSelect('SELECT 1 FROM "transaction" LIMIT 1').getSingleOrNull() != null;

  // Balance rule: income adds amount − fee; expense and transfer-out take
  // amount + fee from the source; transfer-in adds the plain amount.
  Selectable<QueryRow> get _deltaRows => _db.customSelect(
    '''
    SELECT asset_id AS id,
           SUM(CASE type WHEN 'income' THEN amount - fee ELSE -(amount + fee) END) AS delta
      FROM "transaction" GROUP BY asset_id
    UNION ALL
    SELECT to_asset_id, SUM(amount)
      FROM "transaction" WHERE type = 'transfer' GROUP BY to_asset_id
    ''',
    readsFrom: {_db.transactions},
  );

  static Map<int, int> _sumDeltas(List<QueryRow> rows) {
    final deltas = <int, int>{};
    for (final r in rows) {
      final id = r.read<int>('id');
      deltas[id] = (deltas[id] ?? 0) + r.read<int>('delta');
    }
    return deltas;
  }

  @override
  Stream<Map<int, int>> watchBalanceDeltas() => _deltaRows.watch().map(_sumDeltas);

  Future<Map<int, int>> balanceDeltas() async => _sumDeltas(await _deltaRows.get());

  // A transfer moves money between the user's own accounts, so only its fee
  // changes net worth.
  @override
  Stream<List<MonthlyFlow>> watchMonthlyFlows() => _db
      .customSelect(
        '''
        SELECT substr(date, 1, 7) AS month,
               SUM(CASE WHEN type = 'income' THEN amount - fee ELSE 0 END) AS income,
               SUM(CASE WHEN type = 'expense' THEN amount + fee ELSE 0 END) AS expense,
               SUM(CASE type WHEN 'income' THEN amount - fee
                             WHEN 'expense' THEN -(amount + fee)
                             ELSE -fee END) AS net
          FROM "transaction" GROUP BY month ORDER BY month
        ''',
        readsFrom: {_db.transactions},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            MonthlyFlow(
              month: r.read<String>('month'),
              income: r.read<int>('income'),
              expense: r.read<int>('expense'),
              netChange: r.read<int>('net'),
            ),
        ],
      );

  // "Lunch" and "lunch " are one note. With a single max() in the query,
  // SQLite reads the bare `note` from the newest row, so the latest spelling
  // is the one offered.
  static const noteSuggestionsSql = '''
    SELECT trim(note) AS note, COUNT(*) AS uses, MAX(time) AS last, TOTAL(category_id = ?1) AS here
      FROM "transaction"
     WHERE date >= ?2 AND trim(note) <> '' AND lower(trim(note)) <> lower(?3)
       AND (note LIKE ?4 ESCAPE '!' OR note LIKE ?5 ESCAPE '!')
     GROUP BY lower(trim(note))
     ORDER BY here DESC, uses DESC, last DESC
     LIMIT ?6
    ''';

  @override
  Future<List<String>> noteSuggestions({
    String text = '',
    int? categoryId,
    required DateTime since,
    int limit = 8,
  }) async {
    final typed = _escapeLike(text.trim());
    final rows = await _db
        .customSelect(
          noteSuggestionsSql,
          variables: [
            Variable.withInt(categoryId ?? -1),
            Variable.withString(dateKey(since)),
            Variable.withString(text.trim()),
            Variable.withString('$typed%'),
            Variable.withString('% $typed%'),
            Variable.withInt(limit),
          ],
          readsFrom: {_db.transactions},
        )
        .get();
    return [for (final r in rows) r.read<String>('note')];
  }
}

class DriftRecurringRuleRepository implements RecurringRuleRepository {
  DriftRecurringRuleRepository(this._db);

  final AppDatabase _db;

  SimpleSelectStatement<$RecurringRulesTable, RecurringRuleRow> get _visible => _db.select(_db.recurringRules)
    ..where((r) => r.isDeleted.equals(false))
    ..orderBy([(r) => OrderingTerm(expression: r.nextDate)]);

  static RecurringRule _toModel(RecurringRuleRow r) => RecurringRule(
    id: r.id,
    type: TransactionType.values.byName(r.type),
    amount: r.amount,
    fee: r.fee,
    assetId: r.assetId,
    toAssetId: r.toAssetId,
    categoryId: r.categoryId,
    note: r.note,
    frequency: Frequency.values.byName(r.frequency),
    interval: r.interval,
    startDate: parseDateKey(r.startDate),
    endDate: r.endDate == null ? null : parseDateKey(r.endDate!),
    nextDate: parseDateKey(r.nextDate),
    isActive: r.isActive,
  );

  @override
  Stream<List<RecurringRule>> watchAll() => _visible.map(_toModel).watch();

  @override
  Future<List<RecurringRule>> active() => (_visible..where((r) => r.isActive.equals(true))).map(_toModel).get();

  @override
  Future<int> save(RecurringRule rule) async {
    final row = RecurringRulesCompanion(
      type: Value(rule.type.name),
      amount: Value(rule.amount),
      fee: Value(rule.fee),
      assetId: Value(rule.assetId),
      toAssetId: Value(rule.toAssetId),
      categoryId: Value(rule.categoryId),
      note: Value(rule.note),
      frequency: Value(rule.frequency.name),
      interval: Value(rule.interval),
      startDate: Value(dateKey(rule.startDate)),
      endDate: Value(rule.endDate == null ? null : dateKey(rule.endDate!)),
      nextDate: Value(dateKey(rule.nextDate)),
      isActive: Value(rule.isActive),
      updatedAt: Value(_db.nowMs),
    );
    if (rule.id == 0) {
      return _db.into(_db.recurringRules).insert(row.copyWith(createdAt: Value(_db.nowMs)));
    }
    await (_db.update(_db.recurringRules)..where((r) => r.id.equals(rule.id))).write(row);
    return rule.id;
  }

  @override
  Future<void> remove(int id) => (_db.update(_db.recurringRules)..where((r) => r.id.equals(id))).write(
    RecurringRulesCompanion(isDeleted: const Value(true), updatedAt: Value(_db.nowMs)),
  );

  @override
  Future<void> applyOccurrences(RecurringRule rule, List<DateTime> dates, DateTime nextDate) =>
      _db.transaction(() async {
        for (final date in dates) {
          final txn = Transaction(
            id: 0,
            type: rule.type,
            amount: rule.amount,
            fee: rule.fee,
            assetId: rule.assetId,
            toAssetId: rule.toAssetId,
            categoryId: rule.categoryId,
            note: rule.note,
            dateTime: date,
            recurringRuleId: rule.id,
          );
          await _db
              .into(_db.transactions)
              .insert(
                DriftTransactionRepository.toCompanion(txn, _db.nowMs).copyWith(createdAt: Value(_db.nowMs)),
                mode: InsertMode.insertOrIgnore,
              );
        }
        await (_db.update(_db.recurringRules)..where((r) => r.id.equals(rule.id))).write(
          RecurringRulesCompanion(nextDate: Value(dateKey(nextDate)), updatedAt: Value(_db.nowMs)),
        );
      });
}

/// Makes % and _ typed by the user match themselves, not any text.
String _escapeLike(String text) => text.replaceAllMapped(RegExp('[!%_]'), (m) => '!${m[0]}');
