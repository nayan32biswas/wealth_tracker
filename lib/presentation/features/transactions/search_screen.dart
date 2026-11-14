import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/note_suggestions.dart';
import 'selection.dart';
import 'transactions_screen.dart';

const _sortLabels = {
  TransactionSort.newest: 'Newest first',
  TransactionSort.largest: 'Largest amount',
  TransactionSort.smallest: 'Smallest amount',
};

/// How many results one page holds.
const _pageSize = 200;

typedef _Choice = ({int id, String name});

/// Search by note, with date, category, account and sort options folded
/// under a Filters button. Filters stay applied while the panel is closed;
/// the button counts them so a filtered list is never a surprise. Nothing is
/// listed until there is text or a filter, so opening search is not just a
/// second copy of every entry.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _text = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _open = false;
  DateTimeRange? _dates;
  Set<int> _categoryIds = {};
  Set<int> _assetIds = {};
  TransactionSort _sort = TransactionSort.newest;

  Stream<List<Transaction>>? _results;
  Stream<({int income, int expense})>? _totals;
  String? _resultsKey;
  String? _searchKey;
  int _limit = _pageSize;

  /// The same stream for the same search, so opening the Filters panel or a
  /// change in accounts does not run the query again. A new search starts
  /// again at one page; Load more asks for another page of the same search.
  Stream<List<Transaction>> _resultsFor(DateTimeRange? dates) {
    final search = [
      _text,
      dates?.start,
      dates?.end,
      ([..._categoryIds]..sort()),
      ([..._assetIds]..sort()),
      _sort,
    ].join('|');
    final repo = ref.read(repositoriesProvider).transactions;
    TransactionQuery query() => TransactionQuery(
      text: _text,
      from: dates?.start,
      toExclusive: dates == null ? null : dateOnly(dates.end).add(const Duration(days: 1)),
      assetIds: _assetIds,
      categoryIds: _categoryIds,
      sort: _sort,
      limit: _limit,
    );
    if (search != _searchKey) {
      _searchKey = search;
      _limit = _pageSize;
      // Totals cover every match, not just the pages loaded so far.
      _totals = repo.watchTotals(query());
    }
    final key = '$search|$_limit';
    if (key != _resultsKey) {
      _resultsKey = key;
      _results = repo.watch(query());
    }
    return _results!;
  }

  // Focused here rather than by autofocus, which would focus the field
  // again each time a selection ends and the search bar comes back.
  @override
  void initState() {
    super.initState();
    _searchFocus.requestFocus();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _searching => _text.trim().isNotEmpty || _filterCount > 0;

  int get _filterCount => [_dates != null, _categoryIds.isNotEmpty, _assetIds.isNotEmpty].where((on) => on).length;

  void _clearAll() => setState(() {
    _dates = null;
    _categoryIds = {};
    _assetIds = {};
    _sort = TransactionSort.newest;
  });

  @override
  Widget build(BuildContext context) {
    // Archived accounts come last, so their old entries can still be found.
    final accounts = [
      for (final a in [...?ref.watch(assetsProvider).value, ...?ref.watch(archivedAssetsProvider).value])
        (id: a.id, name: a.name),
    ];
    final categories = ref.watch(categoriesProvider).value ?? const [];
    List<_Choice> ofType(CategoryType type) => [
      for (final c in categories)
        if (c.type == type) (id: c.id, name: c.name),
    ];
    final categoryGroups = {'Expense': ofType(CategoryType.expense), 'Income': ofType(CategoryType.income)};
    final results = _searching ? _resultsFor(_dates) : null;

    return StreamBuilder(
      stream: results,
      builder: (context, snapshot) {
        final found = results == null ? null : snapshot.data;
        return SelectableTransactions(
          shown: found ?? const [],
          builder: (context, selectionBar) =>
              _page(context, selectionBar, found, results != null, accounts, categoryGroups),
        );
      },
    );
  }

  Widget _page(
    BuildContext context,
    PreferredSizeWidget? selectionBar,
    List<Transaction>? found,
    bool searching,
    List<_Choice> accounts,
    Map<String, List<_Choice>> categoryGroups,
  ) {
    final dates = _dates;
    return Scaffold(
      appBar:
          selectionBar ??
          AppBar(
            title: TextField(
              controller: _search,
              focusNode: _searchFocus,
              decoration: const InputDecoration(hintText: 'Search notes', border: InputBorder.none),
              onChanged: (v) => setState(() => _text = v),
            ),
          ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoteSuggestions(
            controller: _search,
            focusNode: _searchFocus,
            whenEmpty: false,
            onPicked: (note) => setState(() => _text = note),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
                label: Text(_filterCount == 0 ? 'Filters' : 'Filters ($_filterCount)'),
                onPressed: () => setState(() => _open = !_open),
              ),
            ),
          ),
          if (_open) ...[
            _FilterRow(
              label: 'Date',
              value: dates == null ? 'Any date' : _rangeLabel(dates),
              onTap: _pickDates,
              onClear: dates == null ? null : () => setState(() => _dates = null),
            ),
            _FilterRow(
              label: 'Categories',
              value: _names(categoryGroups.values.expand((g) => g), _categoryIds) ?? 'Any category',
              onTap: () => _pickMany('Categories', categoryGroups, _categoryIds, (ids) => _categoryIds = ids),
            ),
            _FilterRow(
              label: 'Accounts',
              value: _names(accounts, _assetIds) ?? 'Any account',
              onTap: () => _pickMany('Accounts', {'': accounts}, _assetIds, (ids) => _assetIds = ids),
            ),
            ListTile(
              title: const Text('Sort'),
              trailing: DropdownButton<TransactionSort>(
                value: _sort,
                underline: const SizedBox(),
                // The closed button shows the value like the other rows do.
                selectedItemBuilder: (context) => [
                  for (final label in _sortLabels.values) Center(child: Text(label, style: _valueStyle(context))),
                ],
                items: [
                  for (final MapEntry(:key, :value) in _sortLabels.entries)
                    DropdownMenuItem(value: key, child: Text(value)),
                ],
                onChanged: (s) => setState(() => _sort = s ?? TransactionSort.newest),
              ),
            ),
            if (_filterCount > 0 || _sort != TransactionSort.newest)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton(onPressed: _clearAll, child: const Text('Clear all')),
                ),
              ),
          ],
          if (searching)
            StreamBuilder(
              stream: _totals,
              builder: (context, snapshot) => switch (snapshot.data) {
                null => const SizedBox(),
                final t => TotalsBar(PeriodTotals(t.income, t.expense)),
              },
            ),
          const Divider(height: 1),
          Expanded(
            child: switch (found) {
              null => const SizedBox(),
              [] => const Center(child: Text('No matches')),
              final found => ListView.builder(
                // A full page means there may be more to load.
                itemCount: found.length + (found.length >= _limit ? 1 : 0),
                itemBuilder: (context, i) => i < found.length
                    ? TransactionTile(found[i], showDate: true)
                    : Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextButton(
                          onPressed: () => setState(() => _limit += _pageSize),
                          child: const Text('Load more'),
                        ),
                      ),
              ),
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickDates() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      currentDate: ref.read(clockProvider)(),
      initialDateRange: _dates,
    );
    if (picked != null) setState(() => _dates = picked);
  }

  Future<void> _pickMany(
    String title,
    Map<String, List<_Choice>> groups,
    Set<int> current,
    void Function(Set<int>) apply,
  ) async {
    final picked = await showDialog<Set<int>>(
      context: context,
      builder: (_) => _PickManyDialog(title: title, groups: groups, initial: current),
    );
    if (picked != null) setState(() => apply(picked));
  }
}

String _rangeLabel(DateTimeRange r) {
  final day = DateFormat('d MMM yyyy');
  return dateOnly(r.start) == dateOnly(r.end) ? day.format(r.start) : '${day.format(r.start)} – ${day.format(r.end)}';
}

TextStyle? _valueStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

/// Chosen names in list order, or null when nothing is chosen.
String? _names(Iterable<_Choice> choices, Set<int> ids) =>
    ids.isEmpty ? null : choices.where((c) => ids.contains(c.id)).map((c) => c.name).join(', ');

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.label, required this.value, required this.onTap, this.onClear});

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  // A plain row rather than ListTile: the value takes whatever width is
  // left and shortens with an ellipsis, so a long date range or many names
  // never overflow.
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        spacing: 16,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: _valueStyle(context),
            ),
          ),
          if (onClear != null)
            IconButton(tooltip: 'Clear $label', icon: const Icon(Icons.close), onPressed: onClear)
          else
            const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.chevron_right)),
        ],
      ),
    ),
  );
}

/// Tick any number of [groups] items. A group with an empty heading is
/// listed without one.
class _PickManyDialog extends StatefulWidget {
  const _PickManyDialog({required this.title, required this.groups, required this.initial});

  final String title;
  final Map<String, List<_Choice>> groups;
  final Set<int> initial;

  @override
  State<_PickManyDialog> createState() => _PickManyDialogState();
}

class _PickManyDialogState extends State<_PickManyDialog> {
  late final Set<int> _ids = {...widget.initial};

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.title),
    contentPadding: const EdgeInsets.symmetric(vertical: 8),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final (g, MapEntry(key: heading, value: items))
              in widget.groups.entries.where((e) => e.value.isNotEmpty).indexed) ...[
            if (g > 0) const BlockGap(),
            if (heading.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Text(heading, style: Theme.of(context).textTheme.labelLarge),
              ),
            for (final (i, c) in items.indexed) ...[
              if (i > 0) const RowDivider(),
              CheckboxListTile(
                title: Text(c.name),
                value: _ids.contains(c.id),
                onChanged: (on) => setState(() => on! ? _ids.add(c.id) : _ids.remove(c.id)),
              ),
            ],
          ],
        ],
      ),
    ),
    secondary: TextButton(onPressed: () => setState(_ids.clear), child: const Text('Clear')),
    primary: FilledButton(onPressed: () => Navigator.pop(context, _ids), child: const Text('Done')),
  );
}
