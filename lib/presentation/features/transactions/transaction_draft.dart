import '../../../domain/models/categories.dart';
import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';

/// The add/edit form's state.
class TransactionDraft {
  const TransactionDraft._({
    required this.id,
    required this.type,
    required this.dateTime,
    required this.amount,
    required this.assetId,
    required this.toAssetId,
    required this.categoryId,
    required this.note,
    required this.recurringRuleId,
    required this.hasFee,
    required this.fee,
    required this.feeCategoryId,
  });

  factory TransactionDraft.create(TransactionType type, DateTime now, {int? assetId}) => TransactionDraft._(
    id: 0,
    type: type,
    dateTime: now,
    amount: 0,
    assetId: assetId,
    toAssetId: null,
    categoryId: null,
    note: '',
    recurringRuleId: null,
    hasFee: false,
    fee: 0,
    feeCategoryId: null,
  );

  /// [fee] is the entry's linked fee row, if it has one.
  factory TransactionDraft.edit(Transaction t, {Transaction? fee}) => TransactionDraft._(
    id: t.id,
    type: t.type,
    dateTime: t.dateTime,
    amount: t.amount,
    assetId: t.assetId,
    toAssetId: t.toAssetId,
    categoryId: t.categoryId,
    note: t.note ?? '',
    recurringRuleId: t.recurringRuleId,
    hasFee: fee != null,
    fee: fee?.amount ?? 0,
    feeCategoryId: fee?.categoryId,
  );

  final int id;
  final TransactionType type;
  final DateTime dateTime;
  final int amount;
  final int? assetId;
  final int? toAssetId;
  final int? categoryId;
  final String note;
  final int? recurringRuleId;

  /// The "Add a fee or tax" box. Unticked, the fee typed so far is kept in
  /// case it is ticked again, but nothing is saved.
  final bool hasFee;
  final int fee;
  final int? feeCategoryId;

  bool get isTransfer => type == TransactionType.transfer;

  String? get problem {
    if (assetId == null) return 'Choose an account';
    if (isTransfer) {
      if (toAssetId == null) return 'Choose where the money goes';
      if (toAssetId == assetId) return 'Choose two different accounts';
    } else if (categoryId == null) {
      return 'Choose a category';
    }
    if (hasFee) {
      if (fee == 0) return 'Enter the fee, or untick Add a fee or tax';
      if (feeCategoryId == null) return 'Choose a category for the fee';
    }
    return null;
  }

  TransactionDraft withType(TransactionType value) {
    if (value == type) return this;
    return _copy(type: value, categoryId: null, toAssetId: null);
  }

  TransactionDraft withAmount(int value) => _copy(amount: value);

  TransactionDraft withCategory(Category value) => _copy(categoryId: value.id);

  TransactionDraft withAccount(int? value) => _copy(assetId: value);

  TransactionDraft withToAccount(int? value) => _copy(toAssetId: value);

  /// A repeating rule finds its entries by date, so an entry moved to
  /// another day no longer stands for that day's payment. Keeping the link
  /// would make the rule skip a real payment on the new day.
  TransactionDraft withDateTime(DateTime value) =>
      _copy(dateTime: value, recurringRuleId: dateOnly(value) == dateOnly(dateTime) ? recurringRuleId : null);

  TransactionDraft withNote(String value) => _copy(note: value);

  TransactionDraft withHasFee(bool value) => _copy(hasFee: value);

  TransactionDraft withFee(int value) => _copy(fee: value);

  TransactionDraft withFeeCategory(int? value) => _copy(feeCategoryId: value);

  Fee? toFee() => hasFee ? Fee(amount: fee, categoryId: feeCategoryId!) : null;

  Transaction toTransaction() => Transaction(
    id: id,
    type: type,
    amount: amount,
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
    Object? assetId = _keep,
    Object? toAssetId = _keep,
    Object? categoryId = _keep,
    String? note,
    Object? recurringRuleId = _keep,
    bool? hasFee,
    int? fee,
    Object? feeCategoryId = _keep,
  }) => TransactionDraft._(
    id: id,
    type: type ?? this.type,
    dateTime: dateTime ?? this.dateTime,
    amount: amount ?? this.amount,
    assetId: assetId == _keep ? this.assetId : assetId as int?,
    toAssetId: toAssetId == _keep ? this.toAssetId : toAssetId as int?,
    categoryId: categoryId == _keep ? this.categoryId : categoryId as int?,
    note: note ?? this.note,
    recurringRuleId: recurringRuleId == _keep ? this.recurringRuleId : recurringRuleId as int?,
    hasFee: hasFee ?? this.hasFee,
    fee: fee ?? this.fee,
    feeCategoryId: feeCategoryId == _keep ? this.feeCategoryId : feeCategoryId as int?,
  );
}
