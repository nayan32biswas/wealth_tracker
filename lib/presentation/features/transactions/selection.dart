import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/transactions.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';

/// Long-press selection for the transaction rows under it, to delete many at
/// once. While any are picked, [builder] gets a bar with the count, Select
/// all and Delete to show instead of the screen's app bar, and Back clears
/// the selection instead of leaving.
///
/// Only rows in [shown] can be picked: an entry that drops out of the list
/// (another period, a new search) is let go. An entry and its fee are deleted
/// together even when one of them is not in the list; the confirm counts
/// every row and says which are not listed.
class SelectableTransactions extends ConsumerStatefulWidget {
  const SelectableTransactions({super.key, required this.shown, required this.builder, this.toolbarHeight});

  final List<Transaction> shown;
  final Widget Function(BuildContext context, PreferredSizeWidget? selectionBar) builder;

  /// Matches the screen's own app bar, so the list does not jump.
  final double? toolbarHeight;

  @override
  ConsumerState<SelectableTransactions> createState() => _SelectableTransactionsState();
}

class _SelectableTransactionsState extends ConsumerState<SelectableTransactions> {
  Set<int> _picked = const {};

  Set<int> get _shown => {for (final t in widget.shown) TransactionSelection.entryOf(t)};

  // Dropped for good, not just hidden: an entry that leaves the list and
  // comes back (the period changed and changed back) is not picked again.
  @override
  void didUpdateWidget(SelectableTransactions old) {
    super.didUpdateWidget(old);
    _picked = _picked.intersection(_shown);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final picked = _picked;
    final selection = TransactionSelection._(
      picked,
      shown,
      (id) => setState(() => _picked = picked.contains(id) ? ({...picked}..remove(id)) : {...picked, id}),
    );
    final active = picked.isNotEmpty;
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _picked = const {});
      },
      child: _SelectionScope(
        selection,
        child: Builder(builder: (context) => widget.builder(context, active ? _bar(picked, shown) : null)),
      ),
    );
  }

  PreferredSizeWidget _bar(Set<int> picked, Set<int> shown) => AppBar(
    toolbarHeight: widget.toolbarHeight,
    leading: IconButton(
      tooltip: 'Clear selection',
      icon: const Icon(Icons.close),
      onPressed: () => setState(() => _picked = const {}),
    ),
    title: Text('${picked.length} selected'),
    actions: [
      IconButton(
        tooltip: 'Select all',
        icon: const Icon(Icons.select_all),
        onPressed: picked.length == shown.length ? null : () => setState(() => _picked = shown),
      ),
      IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(picked)),
    ],
  );

  Future<void> _delete(Set<int> ids) async {
    final transactions = ref.read(repositoriesProvider).transactions;
    final listed = {for (final t in widget.shown) t.id};
    // An entry can be picked through its fee row alone (a search for the
    // fee's category), and a picked entry's fee may be filtered out.
    final hiddenEntries = ids.where((id) => !listed.contains(id)).length;
    final shownFees = widget.shown.where((t) => ids.contains(t.parentId)).length;
    final total = await transactions.countWithFees(ids);
    if (!mounted) return;
    final ok = await confirm(
      context,
      title: total == 1 ? 'Delete 1 transaction?' : 'Delete $total transactions?',
      message: _notListed(hiddenEntries, total - ids.length - shownFees),
      action: 'Delete',
    );
    if (!ok) return;
    await transactions.deleteAll(ids);
    if (mounted) setState(() => _picked = const {});
  }
}

/// Names the rows being deleted that are not in the list, so nothing goes
/// unseen. Null when every one is in view.
String? _notListed(int entries, int fees) {
  final n = entries + fees;
  if (n == 0) return null;
  final parts = [
    if (entries > 0) entries == 1 ? '1 entry whose fee you picked' : '$entries entries whose fees you picked',
    if (fees > 0) fees == 1 ? '1 fee linked to an entry you picked' : '$fees fees linked to entries you picked',
  ];
  return '${n == 1 ? '1 of them is' : '$n of them are'} not in this list: ${parts.join(' and ')}.';
}

/// What a row needs to know: whether it is picked, and how to toggle it.
/// A fee row stands for its entry, as tapping it opens the entry: picking
/// either picks both, and deleting the entry takes its fee.
class TransactionSelection {
  const TransactionSelection._(this._picked, this._shown, this._toggle);

  final Set<int> _picked;
  final Set<int> _shown;
  final void Function(int id) _toggle;

  static int entryOf(Transaction t) => t.parentId ?? t.id;

  /// Something is picked, so a tap toggles a row instead of opening it.
  bool get active => _picked.isNotEmpty;

  bool canPick(Transaction t) => _shown.contains(entryOf(t));

  bool isPicked(Transaction t) => _picked.contains(entryOf(t));

  void toggle(Transaction t) => _toggle(entryOf(t));

  static TransactionSelection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SelectionScope>()?.selection;
}

class _SelectionScope extends InheritedWidget {
  const _SelectionScope(this.selection, {required super.child});

  final TransactionSelection selection;

  @override
  bool updateShouldNotify(_SelectionScope old) =>
      !setEquals(selection._picked, old.selection._picked) || !setEquals(selection._shown, old.selection._shown);
}
