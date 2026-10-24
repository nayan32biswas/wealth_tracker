import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
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
      appBar: AppBar(title: const Text('Stats')),
      body: ListView(
        children: [
          for (final (i, section) in _sections.indexed) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              title: Text(section.title, style: Theme.of(context).textTheme.titleMedium),
              trailing: Icon(_open == i ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() => _open = _open == i ? null : i),
            ),
            if (_open == i) section.build(),
          ],
        ],
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PeriodBar(statsPeriodProvider, menuInset: statsMenuInset),
          const SizedBox(height: 8),
          SegmentedButton<TransactionType>(
            segments: const [
              ButtonSegment(value: TransactionType.expense, label: Text('Expense')),
              ButtonSegment(value: TransactionType.income, label: Text('Income')),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _type = s.single),
          ),
          const SizedBox(height: 24),
          Text(_type == TransactionType.expense ? 'Total spent' : 'Total received', style: text.labelLarge),
          MoneyText(total, style: text.headlineMedium),
          const SizedBox(height: 16),
          if (shares.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  _type == TransactionType.expense ? 'Nothing spent in this period' : 'No income in this period',
                ),
              ),
            ),
          for (final s in shares)
            _ShareRow(
              name: names[s.categoryId] ?? 'No category',
              share: s,
              color: _type == TransactionType.expense ? scheme.series2 : scheme.series1,
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
      ),
    );
  }
}

/// One ranked category: its name, share of the total as a bar, and amount.
class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.name, required this.share, required this.color, required this.onTap});

  final String name;
  final CategoryShare share;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              spacing: 8,
              children: [
                Expanded(child: Text(name, style: text.bodyLarge)),
                Text('${share.percent.round()}%', style: text.labelMedium),
                MoneyText(share.total, style: text.bodyLarge),
              ],
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share.percent / 100,
                minHeight: 8,
                color: color,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
