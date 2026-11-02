import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/recurring.dart';
import '../../app/providers.dart';
import '../../widgets/calculator.dart';
import '../../widgets/common.dart';
import '../../widgets/note_suggestions.dart';
import '../../widgets/number_pad.dart';
import '../../widgets/pick_field.dart';
import 'fee_fields.dart';
import 'transaction_draft.dart';

/// A new entry starts at [at] (default now) on [accountId] (default none).
/// A fee opens the entry it belongs to, since it only changes with it.
Future<void> openTransactionForm(BuildContext context, {Transaction? existing, DateTime? at, int? accountId}) async {
  Transaction? fee;
  if (existing != null) {
    final repo = ProviderScope.containerOf(context, listen: false).read(repositoriesProvider).transactions;
    if (existing.parentId case final parentId?) existing = await repo.byId(parentId) ?? existing;
    fee = await repo.feeOf(existing.id);
    if (!context.mounted) return;
  }
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => TransactionFormScreen(existing: existing, fee: fee, at: at, accountId: accountId),
    ),
  );
}

enum _PadField { amount, fee }

class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, this.existing, this.fee, this.at, this.accountId});

  final Transaction? existing;

  /// The fee row linked to [existing], if any.
  final Transaction? fee;
  final DateTime? at;
  final int? accountId;

  @override
  ConsumerState<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends ConsumerState<TransactionFormScreen> {
  late TransactionDraft _draft = widget.existing == null
      ? TransactionDraft.create(
          TransactionType.expense,
          widget.at ?? ref.read(clockProvider)(),
          // Archived accounts are left out of the pickers, so a new entry
          // never starts on one.
          assetId: (ref.read(assetsProvider).value ?? []).any((a) => a.id == widget.accountId)
              ? widget.accountId
              : null,
        )
      : TransactionDraft.edit(widget.existing!, fee: widget.fee);
  late final _note = TextEditingController(text: _draft.note);
  final _noteFocus = FocusNode();

  /// The box the number pad types into; null when the pad is closed.
  _PadField? _pad;
  Frequency? _repeat;
  String _padText = '';
  // The pad types a magnitude; the sign is kept apart so "-" can be toggled
  // before or after the digits.
  late bool _negative = _draft.amount < 0;
  // Fee and repeat are rarely needed, so they start folded away unless the
  // entry has a fee.
  late bool _showMore = _draft.hasFee;

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
      _pad = field;
      _padText = money.editText(field == _PadField.fee ? _draft.fee : _draft.amount.abs());
    });
  }

  Future<void> _openCalculator() async {
    final field = _pad ?? _PadField.amount;
    FocusScope.of(context).unfocus();
    setState(() => _pad = null);
    final result = await openCalculator(
      context,
      start: field == _PadField.fee ? _draft.fee : _draft.amount,
      money: ref.read(moneyFormatProvider),
      allowNegative: _canBeNegative(field),
    );
    if (result == null || !mounted) return;
    if (field == _PadField.fee) {
      setState(() => _draft = _draft.withFee(result));
      return;
    }
    setState(() {
      _negative = result < 0;
      _draft = _draft.withAmount(result);
    });
  }

  bool _canBeNegative(_PadField? field) => field == _PadField.amount && !_draft.isTransfer;

  void _onPadKey(String key) {
    final money = ref.read(moneyFormatProvider);
    if (key == signKey) {
      if (!_canBeNegative(_pad)) return;
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
      _draft = _pad == _PadField.fee ? _draft.withFee(value) : _draft.withAmount(_negative ? -value : value);
    });
  }

  /// Ticking the box starts the fee category as the one used for a fee on a
  /// similar entry before.
  Future<void> _setHasFee(bool value) async {
    setState(() {
      _draft = _draft.withHasFee(value);
      if (!value && _pad == _PadField.fee) _pad = null;
    });
    if (!value || _draft.feeCategoryId != null) return;
    final d = _draft;
    final offered = await ref
        .read(repositoriesProvider)
        .transactions
        .lastFeeCategory(
          Transaction(
            id: 0,
            type: d.type,
            amount: d.amount,
            assetId: d.assetId ?? -1,
            toAssetId: d.toAssetId,
            categoryId: d.categoryId,
            dateTime: d.dateTime,
          ),
        );
    final usable = (ref.read(categoriesProvider).value ?? []).any(
      (c) => c.id == offered && c.type == CategoryType.expense,
    );
    if (!mounted || !usable || !_draft.hasFee || _draft.feeCategoryId != null) return;
    setState(() => _draft = _draft.withFeeCategory(offered));
  }

  Future<void> _save() async {
    if (_saving) return;
    final problem = _draft.problem;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    if (_repeat != null && _draft.amount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A repeating entry needs an amount')));
      return;
    }
    if (_repeat != null && _draft.amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A repeating entry can't be negative")));
      return;
    }
    // A rule repeats one amount, so a fee would be left behind after the first time.
    if (_repeat != null && _draft.hasFee) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A repeating entry can't have a fee")));
      return;
    }
    final repos = ref.read(repositoriesProvider);
    final transaction = _draft.withNote(_note.text).toTransaction();
    setState(() => _saving = true);
    try {
      if (_repeat == null) {
        await repos.transactions.save(transaction, fee: _draft.toFee());
      } else {
        await startRecurring(repos.recurring, transaction, _repeat!, today: ref.read(clockProvider)());
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      rethrow;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final title = widget.fee == null ? 'Delete this transaction?' : 'Delete this transaction and its fee?';
    if (!await confirm(context, title: title, action: 'Delete')) return;
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
    final names = ref.watch(assetNamesProvider).value ?? const {};
    // An entry may be on an archived account, which the pickers leave out;
    // keep it selectable so the entry still opens and saves with its account.
    List<(int, String)> accountItems(int? current) => [
      for (final a in accounts) (a.id, a.name),
      if (current != null && !accounts.any((a) => a.id == current) && names[current] != null)
        (current, names[current]!),
    ];
    final categoryType = _draft.type == TransactionType.income ? CategoryType.income : CategoryType.expense;
    final categories = (ref.watch(categoriesProvider).value ?? []).where((c) => c.type == categoryType).toList();
    final categoryNames = ref.watch(categoryNamesProvider).value ?? const {};
    final currentCategory = _draft.categoryId;

    final amountText = _pad == _PadField.amount
        ? '${_negative ? '-' : ''}${_padText.isEmpty ? '0' : _padText}'
        : money.format(_draft.amount, withSymbol: false);
    final feeText = _pad == _PadField.fee
        ? (_padText.isEmpty ? '0' : _padText)
        : money.format(_draft.fee, withSymbol: false);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
        title: Text(_editing ? 'Edit transaction' : 'New transaction'),
        // Close sits on the right, by the thumb.
        automaticallyImplyLeading: false,
        actions: [
          if (_editing) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          const CloseButton(),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        // 12 px between fields: the least that keeps a field's floating label
        // clear of the field above it.
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
            const SizedBox(height: 12),
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
            const SizedBox(height: 12),
            PickField<int>(
              label: _draft.isTransfer ? 'From' : 'Account',
              value: _draft.assetId,
              choices: accountItems(_draft.assetId),
              onChanged: (id) => setState(() => _draft = _draft.withAccount(id)),
            ),
            const SizedBox(height: 12),
            if (_draft.isTransfer)
              PickField<int>(
                label: 'To',
                value: _draft.toAssetId,
                choices: accountItems(_draft.toAssetId),
                onChanged: (id) => setState(() => _draft = _draft.withToAccount(id)),
              )
            else
              PickField<int>(
                label: 'Category',
                value: currentCategory,
                choices: [
                  for (final c in categories) (c.id, c.name),
                  if (currentCategory != null &&
                      !categories.any((c) => c.id == currentCategory) &&
                      categoryNames[currentCategory] != null)
                    (currentCategory, categoryNames[currentCategory]!),
                ],
                onChanged: (id) {
                  final picked = categories.where((c) => c.id == id).firstOrNull;
                  if (picked != null) setState(() => _draft = _draft.withCategory(picked));
                },
              ),
            const SizedBox(height: 12),
            PadValue(
              label: 'Amount',
              text: amountText,
              active: _pad == _PadField.amount,
              onTap: () => _openPad(_PadField.amount),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              focusNode: _noteFocus,
              decoration: const InputDecoration(labelText: 'Note'),
              onTap: () => setState(() => _pad = null),
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
                onPressed: () => setState(() => _showMore = !_showMore),
                icon: Icon(_showMore ? Icons.expand_less : Icons.expand_more),
                label: Text(_showMore ? 'Fewer options' : 'More options'),
              ),
            ),
            if (_showMore) ...[
              const SizedBox(height: 8),
              FeeFields(
                draft: _draft,
                text: feeText,
                active: _pad == _PadField.fee,
                onTap: () => _openPad(_PadField.fee),
                onCategory: (id) => setState(() => _draft = _draft.withFeeCategory(id)),
                onHasFee: _setHasFee,
              ),
              // Only a new entry can start repeating.
              if (!_editing) ...[
                const SizedBox(height: 12),
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
          if (_pad != null)
            MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: NumberPad(
                onKey: _onPadKey,
                onDone: () => setState(() => _pad = null),
                onCalculator: _openCalculator,
                allowNegative: _canBeNegative(_pad),
              ),
            ),
          BottomActionButton(label: 'Save', onPressed: _saving ? null : _save),
        ],
      ),
    );
  }
}
