import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/money.dart';
import '../../../domain/services/recurring.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';

final recurringRulesProvider = StreamProvider<List<RecurringRule>>(
  (ref) => ref.watch(repositoriesProvider).recurring.watchAll(),
);

String ruleTitle(RecurringRule rule, Map<int, String> categories) =>
    rule.note ?? categories[rule.categoryId] ?? (rule.type == TransactionType.transfer ? 'Transfer' : 'Recurring');

class RecurringScreen extends ConsumerWidget {
  const RecurringScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(recurringRulesProvider).value ?? const [];
    final categories = ref.watch(categoryNamesProvider).value ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('Recurring')),
      body: rules.isEmpty
          ? const Center(child: Text('Choose "Repeat" when adding a transaction to create one'))
          : ListView(
              children: [
                for (final (i, rule) in rules.indexed) ...[
                  if (i > 0) const RowDivider(),
                  ListTile(
                    title: Text(ruleTitle(rule, categories)),
                    subtitle: Text(
                      rule.isActive
                          ? '${frequencyLabel(rule.frequency, rule.interval)} · Next ${DateFormat('d MMM yyyy').format(rule.nextDate)}'
                          : '${frequencyLabel(rule.frequency, rule.interval)} · Paused',
                    ),
                    trailing: MoneyText(rule.amount),
                    onTap: () => _edit(context, ref, rule),
                  ),
                ],
              ],
            ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, RecurringRule rule) async {
    final repo = ref.read(repositoriesProvider).recurring;
    final result = await showDialog<EditResult<RecurringRule>>(
      context: context,
      builder: (_) => _RuleDialog(rule, ref.read(moneyFormatProvider)),
    );
    switch (result) {
      case (DialogAction.remove, _):
        await repo.remove(rule.id);
      case (DialogAction.save, final edited?):
        await repo.save(!rule.isActive && edited.isActive ? resumeRule(edited, ref.read(clockProvider)()) : edited);
      case _:
        break;
    }
  }
}

/// Changes apply to future occurrences only; entries already created stay.
class _RuleDialog extends StatefulWidget {
  const _RuleDialog(this.rule, this.money);

  final RecurringRule rule;
  final MoneyFormat money;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _amount = TextEditingController(text: widget.money.editText(widget.rule.amount));
  late Frequency _frequency = widget.rule.frequency;
  late bool _active = widget.rule.isActive;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  RecurringRule? _value() {
    final amount = widget.money.parse(_amount.text);
    if (amount == null || amount <= 0) return null;
    return widget.rule.copyWith(amount: amount, frequency: _frequency, isActive: _active);
  }

  @override
  Widget build(BuildContext context) => EditDialog<RecurringRule>(
    title: 'Recurring',
    removeLabel: 'Remove',
    value: _value,
    children: [
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Amount'),
        onChanged: (_) => setState(() {}),
      ),
      DropdownButtonFormField<Frequency>(
        isExpanded: true,
        initialValue: _frequency,
        decoration: const InputDecoration(labelText: 'Repeat'),
        items: [for (final f in Frequency.values) DropdownMenuItem(value: f, child: Text(frequencyLabel(f, 1)))],
        onChanged: (f) => setState(() => _frequency = f!),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Active'),
        value: _active,
        onChanged: (v) => setState(() => _active = v),
      ),
    ],
  );
}
