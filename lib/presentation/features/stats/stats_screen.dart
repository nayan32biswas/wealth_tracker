import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/period_switcher.dart';
import 'category_screen.dart';
import 'pace_view.dart';
import 'trends_view.dart';

final statsPeriodProvider = NotifierProvider.autoDispose<PeriodController, Period>(
  () => PeriodController(PeriodKind.month),
);

/// Keeps each section's Month/Year menu clear of the section's fold arrow
/// above it.
const statsMenuInset = 16.0;

final _statsTransactionsProvider = StreamProvider.autoDispose<List<Transaction>>((ref) {
  final p = ref.watch(statsPeriodProvider);
  return ref
      .watch(repositoriesProvider)
      .transactions
      .watch(TransactionQuery(from: p.start, toExclusive: p.endExclusive));
});

/// One collapsible report on the Stats tab. [build] runs only while the
/// section is open, so a closed section loads no data.
typedef _StatsSection = ({String title, Widget Function() build});

final _sections = <_StatsSection>[
  (title: 'Categories', build: () => const _CategoriesView()),
  (title: 'Spending pace', build: () => const PaceView()),
  (title: 'Trends', build: () => const TrendsView()),
];

/// Reports stacked as collapsible sections, at most one open at a time, so
/// the list can grow without a crowded tab bar.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  int? _open = 0;

  @override
  Widget build(BuildContext context) {
    // The period and trend window are kept while the Stats tab is open, so
    // they survive switching sections, and reset once the tab closes.
    ref.listen(statsPeriodProvider, (_, _) {});
    ref.listen(trendWindowProvider, (_, _) {});
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          children: [
            for (final (i, section) in _sections.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                dense: true,
                title: Text(section.title, style: Theme.of(context).textTheme.titleMedium),
                trailing: Icon(_open == i ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _open = _open == i ? null : i),
              ),
              if (_open == i) section.build(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Where the money went (or came from) in a period, ranked by category.
class _CategoriesView extends ConsumerStatefulWidget {
  const _CategoriesView();

  @override
  ConsumerState<_CategoriesView> createState() => _CategoriesViewState();
}

class _CategoriesViewState extends ConsumerState<_CategoriesView> {
  TransactionType _type = TransactionType.expense;

  @override
  Widget build(BuildContext context) {
    final txns = ref.watch(_statsTransactionsProvider).value ?? const <Transaction>[];
    final names = ref.watch(categoryNamesProvider).value ?? const {};
    final shares = categoryBreakdown(txns, _type);
    final total = shares.fold(0, (sum, s) => sum + s.total);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PeriodBar(statsPeriodProvider, menuInset: statsMenuInset),
          const SizedBox(height: 4),
          SegmentedButton<TransactionType>(
            segments: const [
              ButtonSegment(value: TransactionType.expense, label: Text('Expense')),
              ButtonSegment(value: TransactionType.income, label: Text('Income')),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _type = s.single),
          ),
          const SizedBox(height: 12),
          Text(_type == TransactionType.expense ? 'Total spent' : 'Total received', style: text.labelLarge),
          MoneyText(total, style: text.headlineSmall),
          const SizedBox(height: 8),
          if (shares.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  _type == TransactionType.expense ? 'Nothing spent in this period' : 'No income in this period',
                ),
              ),
            ),
          for (final (i, s) in shares.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _ShareRow(
              name: names[s.categoryId] ?? 'No category',
              share: s,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CategoryScreen(
                    title: names[s.categoryId] ?? 'No category',
                    categoryId: s.categoryId,
                    type: _type,
                    period: ref.read(statsPeriodProvider),
                    transactions: txns.where((t) => t.type == _type && t.categoryId == s.categoryId).toList(),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One ranked category on one line: its share of the total as a badge, its
/// name and its amount.
class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.name, required this.share, required this.onTap});

  final String name;
  final CategoryShare share;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          spacing: 12,
          children: [
            // Fixed width so every name starts at the same place, even at 100%.
            Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
              child: Text('${share.percent.round()}%', style: text.labelLarge),
            ),
            Expanded(child: Text(name, style: text.bodyLarge)),
            MoneyText(share.total, style: text.bodyLarge),
          ],
        ),
      ),
    );
  }
}
