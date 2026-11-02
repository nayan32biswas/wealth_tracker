import 'enums.dart';

class Category {
  const Category({required this.id, required this.name, required this.type, this.order = 0});

  final int id;
  final String name;
  final CategoryType type;
  final int order;

  Category copyWith({int? id, String? name, CategoryType? type, int? order}) =>
      Category(id: id ?? this.id, name: name ?? this.name, type: type ?? this.type, order: order ?? this.order);
}
