import 'enums.dart';

class Transaction {
  const Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.assetId,
    required this.dateTime,
    this.toAssetId,
    this.categoryId,
    this.note,
    this.recurringRuleId,
    this.parentId,
  });

  /// 0 means "not saved yet".
  final int id;
  final TransactionType type;
  final int amount;
  final int assetId;
  final int? toAssetId;
  final int? categoryId;
  final String? note;
  final DateTime dateTime;
  final int? recurringRuleId;

  /// Set when this is the fee of another entry; see [Fee].
  final int? parentId;

  bool get isFee => parentId != null;

  Transaction copyWith({
    int? id,
    TransactionType? type,
    int? amount,
    int? assetId,
    int? Function()? toAssetId,
    int? Function()? categoryId,
    String? Function()? note,
    DateTime? dateTime,
    int? Function()? recurringRuleId,
    int? Function()? parentId,
  }) => Transaction(
    id: id ?? this.id,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    assetId: assetId ?? this.assetId,
    toAssetId: toAssetId != null ? toAssetId() : this.toAssetId,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    note: note != null ? note() : this.note,
    dateTime: dateTime ?? this.dateTime,
    recurringRuleId: recurringRuleId != null ? recurringRuleId() : this.recurringRuleId,
    parentId: parentId != null ? parentId() : this.parentId,
  );
}

/// A charge on an entry (a broker fee, a bank fee, tax cut from a salary),
/// saved as its own expense so it can be totalled, but typed in the same form
/// and kept in step with the entry: same account (the From account of a
/// transfer), date and note. Income with a deduction is entered gross, so the
/// account gains what actually arrived.
class Fee {
  const Fee({required this.amount, required this.categoryId});

  final int amount;
  final int categoryId;

  /// The expense row for [main], which must already be saved.
  Transaction entryFor(Transaction main, {int id = 0}) => Transaction(
    id: id,
    type: TransactionType.expense,
    amount: amount,
    assetId: main.assetId,
    categoryId: categoryId,
    note: main.note,
    dateTime: main.dateTime,
    parentId: main.id,
  );
}

class RecurringRule {
  const RecurringRule({
    required this.id,
    required this.type,
    required this.amount,
    required this.assetId,
    required this.frequency,
    required this.startDate,
    required this.nextDate,
    this.interval = 1,
    this.toAssetId,
    this.categoryId,
    this.note,
    this.endDate,
    this.isActive = true,
  });

  final int id;
  final TransactionType type;
  final int amount;
  final int assetId;
  final int? toAssetId;
  final int? categoryId;
  final String? note;
  final Frequency frequency;
  final int interval;
  final DateTime startDate;
  final DateTime? endDate;

  /// First date that has not been turned into a transaction yet.
  final DateTime nextDate;
  final bool isActive;

  RecurringRule copyWith({
    int? id,
    int? amount,
    int? assetId,
    int? Function()? toAssetId,
    int? Function()? categoryId,
    String? Function()? note,
    Frequency? frequency,
    int? interval,
    DateTime? startDate,
    DateTime? Function()? endDate,
    DateTime? nextDate,
    bool? isActive,
    TransactionType? type,
  }) => RecurringRule(
    id: id ?? this.id,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    assetId: assetId ?? this.assetId,
    toAssetId: toAssetId != null ? toAssetId() : this.toAssetId,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    note: note != null ? note() : this.note,
    frequency: frequency ?? this.frequency,
    interval: interval ?? this.interval,
    startDate: startDate ?? this.startDate,
    endDate: endDate != null ? endDate() : this.endDate,
    nextDate: nextDate ?? this.nextDate,
    isActive: isActive ?? this.isActive,
  );
}

/// Totals for one calendar month, keyed as `YYYY-MM`.
class MonthlyFlow {
  const MonthlyFlow({required this.month, required this.income, required this.expense});

  final String month;
  final int income;
  final int expense;

  /// How much net worth moved this month. Transfers stay between the user's
  /// own accounts, so they don't change it.
  int get netChange => income - expense;
}

/// [largest] and [smallest] order by [Transaction.amount].
enum TransactionSort { newest, largest, smallest }

class TransactionQuery {
  const TransactionQuery({
    this.from,
    this.toExclusive,
    this.text,
    this.types,
    this.assetIds,
    this.categoryIds,
    this.sort = TransactionSort.newest,
    this.limit,
  });

  final DateTime? from;
  final DateTime? toExclusive;
  final String? text;
  final Set<TransactionType>? types;

  /// Any of these, on either side of a transfer. Empty means any account.
  final Set<int>? assetIds;

  /// Any of these. Empty means any category.
  final Set<int>? categoryIds;
  final TransactionSort sort;
  final int? limit;
}
