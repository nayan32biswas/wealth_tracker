import 'enums.dart';

class Transaction {
  const Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.assetId,
    required this.dateTime,
    this.fee = 0,
    this.toAssetId,
    this.categoryId,
    this.note,
    this.recurringRuleId,
  });

  /// 0 means "not saved yet".
  final int id;
  final TransactionType type;
  final int amount;
  final int fee;
  final int assetId;
  final int? toAssetId;
  final int? categoryId;
  final String? note;
  final DateTime dateTime;
  final int? recurringRuleId;

  /// Money actually moved. Expenses and transfers cost amount + fee;
  /// income arrives with the fee (e.g. tax deducted) already taken off.
  int get total => type == TransactionType.income ? amount - fee : amount + fee;

  Transaction copyWith({
    int? id,
    TransactionType? type,
    int? amount,
    int? fee,
    int? assetId,
    int? Function()? toAssetId,
    int? Function()? categoryId,
    String? Function()? note,
    DateTime? dateTime,
    int? Function()? recurringRuleId,
  }) => Transaction(
    id: id ?? this.id,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    fee: fee ?? this.fee,
    assetId: assetId ?? this.assetId,
    toAssetId: toAssetId != null ? toAssetId() : this.toAssetId,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    note: note != null ? note() : this.note,
    dateTime: dateTime ?? this.dateTime,
    recurringRuleId: recurringRuleId != null ? recurringRuleId() : this.recurringRuleId,
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
    this.fee = 0,
    this.toAssetId,
    this.categoryId,
    this.note,
    this.endDate,
    this.isActive = true,
  });

  final int id;
  final TransactionType type;
  final int amount;
  final int fee;
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
    int? fee,
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
    fee: fee ?? this.fee,
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
  const MonthlyFlow({required this.month, required this.income, required this.expense, required this.netChange});

  final String month;
  final int income;
  final int expense;

  /// How much net worth moved this month. Differs from income − expense
  /// because transfer fees also lower net worth.
  final int netChange;
}

/// [largest] and [smallest] order by money moved ([Transaction.total]), the
/// figure each row shows, so fees count.
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
