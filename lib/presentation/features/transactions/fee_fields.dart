import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/enums.dart';
import '../../app/providers.dart';
import '../../widgets/number_pad.dart';
import '../../widgets/pick_field.dart';
import 'transaction_draft.dart';

/// The "Add a fee or tax" box of the transaction form. Ticked, it shows the
/// fee, what it does to the account, and its category.
class FeeFields extends ConsumerWidget {
  const FeeFields({
    super.key,
    required this.draft,
    required this.text,
    required this.active,
    required this.onTap,
    required this.onCategory,
    required this.onHasFee,
  });

  final TransactionDraft draft;

  /// What the box shows: the typed text while the pad is open on it.
  final String text;
  final bool active;
  final VoidCallback onTap;
  final ValueChanged<int> onCategory;
  final ValueChanged<bool> onHasFee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatProvider);
    final accounts = ref.watch(assetNamesProvider).value ?? const {};
    final categories = ref.watch(categoriesProvider).value ?? [];
    final names = ref.watch(categoryNamesProvider).value ?? const {};
    final current = draft.feeCategoryId;
    // A fee is always an expense. A removed category stays choosable on an
    // entry that already uses it.
    final choices = [
      for (final c in categories)
        if (c.type == CategoryType.expense) (c.id, c.name),
      if (current != null && !categories.any((c) => c.id == current) && names[current] != null)
        (current, names[current]!),
    ];
    // Income arrives smaller; an expense or a transfer takes more.
    final effect = switch (draft.type) {
      TransactionType.income => 'Arrives: ${money.format(draft.amount - draft.fee)}',
      TransactionType.expense => 'Total paid: ${money.format(draft.amount + draft.fee)}',
      TransactionType.transfer =>
        'Leaves ${accounts[draft.assetId] ?? 'From'}: ${money.format(draft.amount + draft.fee)}',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Add a fee or tax'),
          subtitle: const Text('Saved as its own expense, linked to this entry'),
          value: draft.hasFee,
          onChanged: (v) => onHasFee(v ?? false),
        ),
        if (draft.hasFee) ...[
          const SizedBox(height: 8),
          PadValue(label: 'Fee or tax', text: text, active: active, onTap: onTap),
          if (draft.fee > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(effect, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          PickField<int>(label: 'Fee category', value: current, choices: choices, onChanged: onCategory),
        ],
      ],
    );
  }
}
