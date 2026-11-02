import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/categories.dart';
import '../../../domain/models/enums.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  CategoryType _type = CategoryType.expense;

  @override
  Widget build(BuildContext context) {
    final categories = (ref.watch(categoriesProvider).value ?? []).where((c) => c.type == _type).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          IconButton(
            tooltip: 'Archived categories',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DeletedCategoriesScreen())),
          ),
          IconButton(
            tooltip: 'Add category',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(Category(id: 0, name: '', type: _type)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<CategoryType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: CategoryType.expense, label: Text('Expense')),
                ButtonSegment(value: CategoryType.income, label: Text('Income')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.single),
            ),
          ),
          Expanded(
            child: ReorderableTiles(
              ids: [for (final c in categories) c.id],
              onReorder: ref.read(repositoriesProvider).categories.reorder,
              children: [for (final c in categories) ListTile(title: Text(c.name), onTap: () => _edit(c))],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(Category category) async {
    final repo = ref.read(repositoriesProvider).categories;
    final entries = category.id == 0 ? 0 : await repo.usage(category.id);
    if (!mounted) return;
    final result = await showDialog<EditResult<Category>>(
      context: context,
      builder: (_) => _CategoryDialog(category, entries == 0 ? removeLabel(category.id, 0) : 'Merge or archive'),
    );
    if (result == null || !mounted) return;
    await guarded(context, () async {
      switch (result) {
        case (DialogAction.remove, _):
          if (entries == 0) return repo.remove(category.id);
          if (!mounted) return;
          final others = (ref.read(categoriesProvider).value ?? [])
              .where((c) => c.type == category.type && c.id != category.id)
              .toList();
          final choice = await showDialog<_Removal>(
            context: context,
            builder: (_) => _UsedCategoryDialog(category, others, entries),
          );
          switch (choice) {
            case null:
              break;
            case (mergeInto: final into?):
              await repo.merge(category.id, into);
            case (mergeInto: null):
              await repo.remove(category.id);
          }
        case (DialogAction.save, final edited?) when edited.id == 0:
          await repo.add(edited.name, edited.type);
        case (DialogAction.save, final edited?):
          await repo.update(edited);
        case (DialogAction.save, null):
          break;
      }
    });
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog(this.category, this.removeLabel);

  final Category category;
  final String? removeLabel;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _name = TextEditingController(text: widget.category.name);

  Category? _value() {
    final name = _name.text.trim();
    return name.isEmpty ? null : widget.category.copyWith(name: name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog<Category>(
    title: widget.category.id == 0 ? 'New category' : 'Edit category',
    removeLabel: widget.removeLabel,
    value: _value,
    children: [
      TextField(
        controller: _name,
        autofocus: widget.category.id == 0,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

typedef _Removal = ({int? mergeInto});

class _UsedCategoryDialog extends StatefulWidget {
  const _UsedCategoryDialog(this.category, this.others, this.entries);

  final Category category;
  final List<Category> others;
  final int entries;

  @override
  State<_UsedCategoryDialog> createState() => _UsedCategoryDialogState();
}

class _UsedCategoryDialogState extends State<_UsedCategoryDialog> {
  int? _into;

  @override
  Widget build(BuildContext context) {
    final name = widget.category.name;
    return AppDialog(
      title: Text('Merge or archive "$name"?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          Text(
            'Used by ${entryCount(widget.entries)}. Merge moves them, and any recurring rules, '
            'to another category and deletes "$name". Archive hides it, and old entries keep its name.',
          ),
          if (widget.others.isNotEmpty)
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _into,
              decoration: const InputDecoration(labelText: 'Merge into'),
              items: [for (final c in widget.others) DropdownMenuItem(value: c.id, child: Text(c.name))],
              onChanged: (id) => setState(() => _into = id),
            ),
        ],
      ),
      secondary: TextButton(
        onPressed: () => Navigator.pop<_Removal>(context, (mergeInto: null)),
        child: const Text('Archive'),
      ),
      primary: widget.others.isEmpty
          ? null
          : FilledButton(
              onPressed: _into == null ? null : () => Navigator.pop<_Removal>(context, (mergeInto: _into)),
              child: const Text('Merge'),
            ),
    );
  }
}

final _deletedCategoriesProvider = StreamProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(repositoriesProvider).categories.watchDeleted(),
);

class DeletedCategoriesScreen extends ConsumerWidget {
  const DeletedCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleted = ref.watch(_deletedCategoriesProvider).value ?? [];
    final repo = ref.read(repositoriesProvider).categories;
    List<DeletedItem> of(CategoryType type) => [
      for (final c in deleted.where((c) => c.type == type))
        (name: c.name, detail: null, restore: () => repo.restore(c.id), restored: '${c.name} restored'),
    ];
    return DeletedList(
      title: 'Archived categories',
      empty: 'No archived categories',
      sections: [('Expense', of(CategoryType.expense)), ('Income', of(CategoryType.income))],
    );
  }
}
