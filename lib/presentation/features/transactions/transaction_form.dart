import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/recurring.dart';
import '../../app/providers.dart';
import '../../widgets/calculator.dart';
import '../../widgets/note_suggestions.dart';
import '../../widgets/number_pad.dart';
import 'transaction_draft.dart';

Future<void> openTransactionForm(BuildContext context, {Transaction? existing}) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => TransactionFormScreen(existing: existing)));

enum _PadField { amount, fee }

class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, this.existing});

  final Transaction? existing;

  @override
  ConsumerState<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends ConsumerState<TransactionFormScreen> {
  late TransactionDraft _draft = widget.existing == null
      ? TransactionDraft.create(
          TransactionType.expense,
          ref.read(clockProvider)(),
          assetId: ref.read(assetsProvider).value?.firstOrNull?.id,
        )
      : TransactionDraft.edit(widget.existing!);
  late final _note = TextEditingController(text: _draft.note);
  final _noteFocus = FocusNode();
  _PadField? _padField;
  Frequency? _repeat;
  String _padText = '';
  // The pad types a magnitude; the sign is kept apart so "-" can be toggled
  // before or after the digits. Only the amount can be negative, not the fee.
  late bool _negative = _draft.amount < 0;
  // Fee and repeat are rarely needed, so they start folded away unless the
  // entry being edited already has a fee.
  late bool _showMore = _draft.fee != 0;

  // A second tap on Save while the first is still writing would save the
  // entry twice and then close the screen under the form too.
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _openPad(_PadField field) {
    FocusScope.of(context).unfocus();
    final money = ref.read(moneyFormatProvider);
    setState(() {
      _padField = field;
      _padText = money.editText((field == _PadField.amount ? _draft.amount : _draft.fee).abs());
    });
  }

  Future<void> _openCalculator(_PadField field) async {
    FocusScope.of(context).unfocus();
    setState(() => _padField = null);
    final amount = field == _PadField.amount;
    final result = await openCalculator(
      context,
      start: amount ? _draft.amount : _draft.fee,
      money: ref.read(moneyFormatProvider),
      allowNegative: amount && !_draft.isTransfer,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (amount) {
        _negative = result < 0;
        _draft = _draft.withAmount(result);
      } else if (result != _draft.fee) {
        // Only a changed fee counts as typed by the user; an unchanged one
        // keeps following the category default.
        _draft = _draft.withFee(result);
      }
    });
  }

  bool get _canBeNegative => _padField == _PadField.amount && !_draft.isTransfer;

  void _onPadKey(String key) {
    final money = ref.read(moneyFormatProvider);
    if (key == signKey) {
      if (!_canBeNegative) return;
      setState(() {
        _negative = !_negative;
        _draft = _draft.withAmount(-_draft.amount);
      });
      return;
    }
    final text = padInput(_padText, key, decimals: money.decimals);
    final value = money.parse(text) ?? 0;
    setState(() {
      _padText = text;
      _draft = _padField == _PadField.amount ? _draft.withAmount(_negative ? -value : value) : _draft.withFee(value);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final problem = _draft.problem;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    if (_repeat != null && _draft.amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A repeating entry can't be negative")));
      return;
    }
    final repos = ref.read(repositoriesProvider);
    final transaction = _draft.withNote(_note.text).toTransaction();
    setState(() => _saving = true);
    try {
      if (_repeat == null) {
        await repos.transactions.save(transaction);
      } else {
        await startRecurring(repos.recurring, transaction, _repeat!);
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      rethrow;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this transaction?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(repositoriesProvider).transactions.delete(widget.existing!.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final d = _draft.dateTime;
    final picked = await showDatePicker(
      context: context,
      initialDate: d,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _draft = _draft.withDateTime(DateTime(picked.year, picked.month, picked.day, d.hour, d.minute)));
    }
  }

  Future<void> _pickTime() async {
    final d = _draft.dateTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(d),
      // The 24-hour dial packs two rings so tight that the selection circle
      // covers the numbers next to it, so always use the 12-hour dial.
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false), child: child!),
    );
    if (picked != null) {
      setState(() => _draft = _draft.withDateTime(DateTime(d.year, d.month, d.day, picked.hour, picked.minute)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyFormatProvider);
    final accounts = ref.watch(assetsProvider).value ?? [];
    // The account list can arrive after the form opens; a new entry still
    // gets the first account as its default.
    if (!_editing && _draft.assetId == null && accounts.isNotEmpty) {
      _draft = _draft.withAccount(accounts.first.id);
    }
    final names = ref.watch(assetNamesProvider).value ?? const {};
    // An old entry may point at an account removed since; keep it selectable
    // so the entry still opens and saves with its own account.
    List<DropdownMenuItem<int>> accountItems(int? current) => [
      for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
      if (current != null && !accounts.any((a) => a.id == current) && names[current] != null)
        DropdownMenuItem(value: current, child: Text(names[current]!)),
    ];
    final categoryType = _draft.type == TransactionType.income ? CategoryType.income : CategoryType.expense;
    final categories = (ref.watch(categoriesProvider).value ?? []).where((c) => c.type == categoryType).toList();
    final categoryNames = ref.watch(categoryNamesProvider).value ?? const {};
    final currentCategory = _draft.categoryId;

    String padOrFormatted(_PadField field, int value) => _padField == field
        ? '${field == _PadField.amount && _negative ? '-' : ''}${_padText.isEmpty ? '0' : _padText}'
        : money.format(value, withSymbol: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit transaction' : 'New transaction'),
        actions: [
          if (_editing) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<TransactionType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: TransactionType.income, label: Text('Income')),
                ButtonSegment(value: TransactionType.expense, label: Text('Expense')),
                ButtonSegment(value: TransactionType.transfer, label: Text('Transfer')),
              ],
              selected: {_draft.type},
              onSelectionChanged: (s) => setState(() {
                _draft = _draft.withType(s.single);
                if (_draft.isTransfer && _negative) {
                  _negative = false;
                  _draft = _draft.withAmount(-_draft.amount);
                }
              }),
            ),
            const SizedBox(height: 16),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _pickDate,
                    child: Text(DateFormat('EEE, d MMM yyyy').format(_draft.dateTime)),
                  ),
                ),
                OutlinedButton(onPressed: _pickTime, child: Text(DateFormat('HH:mm').format(_draft.dateTime))),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              isExpanded: true,
              // Rebuilt once the default account is filled in, since the
              // field only reads its starting value once.
              key: ValueKey('account-${_draft.assetId != null}'),
              initialValue: _draft.assetId,
              decoration: InputDecoration(labelText: _draft.isTransfer ? 'From' : 'Account'),
              items: accountItems(_draft.assetId),
              onChanged: (id) => setState(() => _draft = _draft.withAccount(id)),
            ),
            const SizedBox(height: 16),
            if (_draft.isTransfer)
              DropdownButtonFormField<int>(
                isExpanded: true,
                key: const ValueKey('to-account'),
                initialValue: _draft.toAssetId,
                decoration: const InputDecoration(labelText: 'To'),
                items: accountItems(_draft.toAssetId),
                onChanged: (id) => setState(() => _draft = _draft.withToAccount(id)),
              )
            else
              DropdownButtonFormField<int>(
                isExpanded: true,
                key: ValueKey('category-${_draft.type.name}'),
                initialValue: currentCategory,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name)),
                  if (currentCategory != null &&
                      !categories.any((c) => c.id == currentCategory) &&
                      categoryNames[currentCategory] != null)
                    DropdownMenuItem(value: currentCategory, child: Text(categoryNames[currentCategory]!)),
                ],
                onChanged: (id) {
                  final picked = categories.where((c) => c.id == id).firstOrNull;
                  if (picked != null) setState(() => _draft = _draft.withCategory(picked));
                },
              ),
            const SizedBox(height: 16),
            _PadValue(
              label: 'Amount',
              text: padOrFormatted(_PadField.amount, _draft.amount),
              helper: !_showMore && _draft.fee != 0
                  ? 'Fee ${money.format(_draft.fee)} · Total ${money.format(_draft.total)}'
                  : null,
              active: _padField == _PadField.amount,
              onTap: () => _openPad(_PadField.amount),
              onCalculator: () => _openCalculator(_PadField.amount),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              focusNode: _noteFocus,
              decoration: const InputDecoration(labelText: 'Note'),
              onTap: () => setState(() => _padField = null),
            ),
            NoteSuggestions(
              controller: _note,
              focusNode: _noteFocus,
              categoryId: _draft.isTransfer ? null : _draft.categoryId,
              padding: const EdgeInsets.only(top: 8),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _showMore = !_showMore;
                  if (!_showMore && _padField == _PadField.fee) _padField = null;
                }),
                icon: Icon(_showMore ? Icons.expand_less : Icons.expand_more),
                label: Text(_showMore ? 'Fewer options' : 'More options'),
              ),
            ),
            if (_showMore) ...[
              const SizedBox(height: 8),
              _PadValue(
                label: 'Fee',
                text: padOrFormatted(_PadField.fee, _draft.fee),
                helper: 'Total ${money.format(_draft.total)}',
                active: _padField == _PadField.fee,
                onTap: () => _openPad(_PadField.fee),
                onCalculator: () => _openCalculator(_PadField.fee),
              ),
              if (!_editing) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<Frequency?>(
                  isExpanded: true,
                  initialValue: _repeat,
                  decoration: const InputDecoration(labelText: 'Repeat'),
                  items: [
                    const DropdownMenuItem(child: Text('Never')),
                    for (final f in Frequency.values) DropdownMenuItem(value: f, child: Text(frequencyLabel(f, 1))),
                  ],
                  onChanged: (f) => setState(() => _repeat = f),
                ),
              ],
            ],
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The Save button below handles the bottom safe area for both.
          if (_padField != null)
            MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: NumberPad(
                onKey: _onPadKey,
                onDone: () => setState(() => _padField = null),
                allowNegative: _canBeNegative,
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PadValue extends StatelessWidget {
  const _PadValue({
    required this.label,
    required this.text,
    required this.active,
    required this.onTap,
    required this.onCalculator,
    this.helper,
  });

  final String label;
  final String text;
  final String? helper;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onCalculator;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: InputDecorator(
      isFocused: active,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: IconButton(
          tooltip: 'Calculator',
          icon: const Icon(Icons.calculate_outlined),
          onPressed: onCalculator,
        ),
      ),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    ),
  );
}
