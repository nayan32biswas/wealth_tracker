import 'enums.dart';

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.order = 0,
    this.feeType = FeeType.none,
    this.feeValue = 0,
  });

  final int id;
  final String name;
  final CategoryType type;
  final int order;
  final FeeType feeType;

  /// Percent fees are stored in basis points (185 = 1.85%).
  /// Fixed fees are stored in minor units (paisa).
  final int feeValue;

  Category copyWith({int? id, String? name, CategoryType? type, int? order, FeeType? feeType, int? feeValue}) =>
      Category(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        order: order ?? this.order,
        feeType: feeType ?? this.feeType,
        feeValue: feeValue ?? this.feeValue,
      );
}
