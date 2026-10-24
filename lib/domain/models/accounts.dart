import 'enums.dart';

class AssetGroup {
  const AssetGroup({required this.id, required this.name, required this.type, this.order = 0});

  final int id;
  final String name;
  final GroupType type;
  final int order;

  bool get isLiability => type == GroupType.liability;

  AssetGroup copyWith({String? name, GroupType? type, int? order}) =>
      AssetGroup(id: id, name: name ?? this.name, type: type ?? this.type, order: order ?? this.order);
}

class Asset {
  const Asset({
    required this.id,
    required this.name,
    required this.groupId,
    this.order = 0,
    this.initialBalance = 0,
    this.isArchived = false,
  });

  final int id;
  final String name;
  final int groupId;
  final int order;

  /// Minor units (paisa). Negative for a liability that starts with a debt.
  final int initialBalance;

  /// Hidden from pickers and lists, but still counted in balances.
  final bool isArchived;

  Asset copyWith({String? name, int? groupId, int? order, int? initialBalance}) => Asset(
    id: id,
    name: name ?? this.name,
    groupId: groupId ?? this.groupId,
    order: order ?? this.order,
    initialBalance: initialBalance ?? this.initialBalance,
    isArchived: isArchived,
  );
}
