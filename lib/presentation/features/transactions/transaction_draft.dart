import '../../../domain/models/categories.dart';
import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/money.dart';

/// The add/edit form's state. The fee follows the category default until
/// the user types their own fee; after that it is left alone.
class TransactionDraft {
  const TransactionDraft._({
    required this.id,
    required this.type,
    required this.dateTime,
    required this.amount,
    required this.fee,
    required this.feeEdited,
    required this.assetId,
    required this.toAssetId,
    required this.categoryId,
    required this.note,
    required this.recurringRuleId,
    required this.category,
  });

  factory TransactionDraft.create(TransactionType type, DateTime now, {int? assetId}) => TransactionDraft._(
    id: 0,
    type: type,
    dateTime: now,
    amount: 0,
    fee: 0,
    feeEdited: false,
    assetId: assetId,
    toAssetId: null,
    categoryId: null,
    note: '',
    recurringRuleId: null,
    category: null,
  );

  /// A saved fee is kept as the user's choice.
  factory TransactionDraft.edit(Transaction t) => TransactionDraft._(
    id: t.id,
    type: t.type,
    dateTime: t.dateTime,
    amount: t.amount,
    fee: t.fee,
    feeEdited: true,
    assetId: t.assetId,
    toAssetId: t.toAssetId,
    categoryId: t.categoryId,
    note: t.note ?? '',
    recurringRuleId: t.recurringRuleId,
    category: null,
  );

  final int id;
  final TransactionType type;
  final DateTime dateTime;
  final int amount;
  final int fee;
  final bool feeEdited;
  final int? assetId;
  final int? toAssetId;
  final int? categoryId;
  final String note;
  final int? recurringRuleId;
  final Category? category;

  bool get isTransfer => type == TransactionType.transfer;

  int get total => type == TransactionType.income ? amount - fee : amount + fee;

  String? get problem {
    if (amount == 0) return 'Enter an amount';
    if (isTransfer && amount < 0) return "A transfer can't be negative";
    if (type == TransactionType.income && fee > amount.abs()) return "The fee can't be more than the amount";
    if (assetId == null) return 'Choose an account';
    if (isTransfer) {
      if (toAssetId == null) return 'Choose where the money goes';
      if (toAssetId == assetId) return 'Choose two different accounts';
    } else if (categoryId == null) {
      return 'Choose a category';
    }
    return null;
  }

  TransactionDraft withType(TransactionType value) {
    if (value == type) return this;
    return _copy(type: value, category: null, categoryId: null, toAssetId: null);
  }

  TransactionDraft withAmount(int value) => _copy(amount: value);

  TransactionDraft withCategory(Category value) => _copy(category: value, categoryId: value.id);

  TransactionDraft withFee(int value) => _copy(fee: value, feeEdited: true);

  TransactionDraft withAccount(int? value) => _copy(assetId: value);

  TransactionDraft withToAccount(int? value) => _copy(toAssetId: value);

  /// A repeating rule finds its entries by date, so an entry moved to
  /// another day no longer stands for that day's payment. Keeping the link
  /// would make the rule skip a real payment on the new day.
  TransactionDraft withDateTime(DateTime value) =>
      _copy(dateTime: value, recurringRuleId: dateOnly(value) == dateOnly(dateTime) ? recurringRuleId : null);

  TransactionDraft withNote(String value) => _copy(note: value);

  Transaction toTransaction() => Transaction(
    id: id,
    type: type,
    amount: amount,
    fee: fee,
    assetId: assetId!,
    toAssetId: isTransfer ? toAssetId : null,
    categoryId: isTransfer ? null : categoryId,
    note: note.trim().isEmpty ? null : note.trim(),
    dateTime: dateTime,
    recurringRuleId: recurringRuleId,
  );

  static const _keep = Object();

  TransactionDraft _copy({
    TransactionType? type,
    DateTime? dateTime,
    int? amount,
    int? fee,
    bool? feeEdited,
    Object? assetId = _keep,
    Object? toAssetId = _keep,
    Object? categoryId = _keep,
    Object? category = _keep,
    String? note,
    Object? recurringRuleId = _keep,
  }) {
    final nextCategory = category == _keep ? this.category : category as Category?;
    final nextAmount = amount ?? this.amount;
    final nextFeeEdited = feeEdited ?? this.feeEdited;
    return TransactionDraft._(
      id: id,
      type: type ?? this.type,
      dateTime: dateTime ?? this.dateTime,
      amount: nextAmount,
      fee: nextFeeEdited ? fee ?? this.fee : defaultFee(nextCategory, nextAmount.abs()),
      feeEdited: nextFeeEdited,
      assetId: assetId == _keep ? this.assetId : assetId as int?,
      toAssetId: toAssetId == _keep ? this.toAssetId : toAssetId as int?,
      categoryId: categoryId == _keep ? this.categoryId : categoryId as int?,
      note: note ?? this.note,
      recurringRuleId: recurringRuleId == _keep ? this.recurringRuleId : recurringRuleId as int?,
      category: nextCategory,
    );
  }
}
