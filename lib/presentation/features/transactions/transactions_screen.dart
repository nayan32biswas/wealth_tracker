import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/period_switcher.dart';
import 'search_screen.dart';
import 'transaction_form.dart';

/// How Activity shows its period, picked from the menu in the top bar.
/// Each view also sets the kind of period the arrows move through.
enum ActivityView {
  daily('Daily', PeriodKind.month),
  calendar('Calendar', PeriodKind.month),
  monthly('Monthly', PeriodKind.year);

  const ActivityView(this.label, this.kind);

  final String label;
  final PeriodKind kind;

  PeriodOption get option => (label: label, kind: kind);
}

class ActivityViewController extends Notifier<ActivityView> {
  @override
  ActivityView build() => ActivityView.daily;

  void set(ActivityView view) => state = view;
}

final activityViewProvider = NotifierProvider.autoDispose<ActivityViewController, ActivityView>(
  ActivityViewController.new,
);

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(periodTransactionsProvider).value ?? const [];
    final view = ref.watch(activityViewProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: PeriodBar(
          transactionsPeriodProvider,
          options: [for (final v in ActivityView.values) v.option],
          selected: view.option,
          onSelected: (o) =>
              ref.read(activityViewProvider.notifier).set(ActivityView.values.firstWhere((v) => v.label == o.label)),
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          TotalsBar(PeriodTotals.of(txns)),
          const Divider(height: 1),
          Expanded(
            child: switch (view) {
              ActivityView.daily => DayList(txns),
              ActivityView.calendar => _CalendarView(txns),
              ActivityView.monthly => const _MonthlyView(),
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        tooltip: 'Add transaction',
        onPressed: () => openTransactionForm(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

typedef _Cell = ({String label, int amount, MoneyTone tone});

class TotalsBar extends StatelessWidget {
  TotalsBar(PeriodTotals totals, {super.key})
    : _cells = [
        (label: 'Income', amount: totals.income, tone: MoneyTone.income),
        (label: 'Expense', amount: totals.expense, tone: MoneyTone.expense),
        (label: 'Net', amount: totals.net, tone: MoneyTone.signed),
      ];

  /// One account: transfers count, so Net is how much the balance moved.
  TotalsBar.account(AccountTotals totals, {super.key})
    : _cells = [
        (label: 'In', amount: totals.inflow, tone: MoneyTone.income),
        (label: 'Out', amount: totals.outflow, tone: MoneyTone.expense),
        (label: 'Net', amount: totals.net, tone: MoneyTone.signed),
      ];

  final List<_Cell> _cells;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, int amount, MoneyTone tone) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: MoneyText(amount, tone: tone, style: Theme.of(context).textTheme.titleSmall),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [for (final c in _cells) cell(c.label, c.amount, c.tone)]),
    );
  }
}

/// Entries grouped under a header per day. With [accountId] the headers show
/// money in and out of that account, transfers included.
class DayList extends StatelessWidget {
  const DayList(this.txns, {super.key, this.accountId});

  final List<Transaction> txns;
  final int? accountId;

  @override
  Widget build(BuildContext context) {
    if (txns.isEmpty) return const _Empty('No transactions in this period');
    // Rows are described first and built only when scrolled into view.
    final rows = <Widget Function(BuildContext)>[
      for (final (i, day) in groupByDay(txns).indexed) ...[
        if (i > 0) (_) => const SizedBox(height: 16),
        (context) => _dayHeader(context, day),
        for (final t in day.transactions) (_) => TransactionTile(t),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i](context),
    );
  }

  Widget _dayHeader(BuildContext context, DayGroup day) {
    final account = accountId == null ? null : AccountTotals.of(day.transactions, accountId!);
    final moneyIn = account?.inflow ?? day.totals.income;
    final moneyOut = account?.outflow ?? day.totals.expense;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // The date keeps a third of the row; large day totals shrink to fit
      // the rest instead of pushing the row off screen.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              DateFormat('EEE, d MMM').format(day.date),
              style: Theme.of(context).textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Flexible(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                spacing: 12,
                children: [
                  if (moneyIn > 0) MoneyText(moneyIn, tone: MoneyTone.income),
                  if (moneyOut > 0) MoneyText(moneyOut, tone: MoneyTone.expense),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarView extends ConsumerStatefulWidget {
  const _CalendarView(this.txns);

  final List<Transaction> txns;

  @override
  ConsumerState<_CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<_CalendarView> {
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final period = ref.watch(transactionsPeriodProvider);
    final weekStart = ref.watch(settingsProvider).weekStart;
    final money = ref.watch(moneyFormatProvider);
    final scheme = Theme.of(context).colorScheme;
    final byDay = {for (final d in groupByDay(widget.txns)) d.date: d};

    final days = [
      for (var d = period.start; d.isBefore(period.endExclusive); d = DateTime(d.year, d.month, d.day + 1)) d,
    ];
    final cells = <DateTime?>[...List.filled((days.first.weekday - weekStart) % 7, null), ...days];
    final weeks = [for (var i = 0; i < cells.length; i += 7) cells.skip(i).take(7).toList()];
    final small = Theme.of(context).textTheme.labelSmall;

    Widget cell(DateTime? day) {
      if (day == null) return const Expanded(child: SizedBox());
      final totals = byDay[day]?.totals;
      return Expanded(
        child: InkWell(
          key: ValueKey('day-${dateKey(day)}'),
          onTap: () => setState(() => _selected = day),
          child: Container(
            height: 76,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              border: Border.all(color: day == _selected ? scheme.primary : scheme.outlineVariant, width: 0.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${day.day}', style: small),
                // A day cell is narrow on a phone, so large amounts shrink to
                // one line instead of wrapping out of the cell.
                if ((totals?.income ?? 0) > 0)
                  _CellAmount(money.format(totals!.income, withSymbol: false), small?.copyWith(color: scheme.income)),
                if ((totals?.expense ?? 0) > 0)
                  _CellAmount(money.format(totals!.expense, withSymbol: false), small?.copyWith(color: scheme.expense)),
              ],
            ),
          ),
        ),
      );
    }

    final weekdayLabels = [for (var i = 0; i < 7; i++) DateFormat('E').format(DateTime(2024, 1, weekStart + i))];
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        Row(
          children: [
            for (final label in weekdayLabels)
              Expanded(
                child: Center(child: Text(label, style: small)),
              ),
          ],
        ),
        for (final week in weeks) Row(children: [for (var i = 0; i < 7; i++) cell(i < week.length ? week[i] : null)]),
        if (_selected != null) ...[
          const SizedBox(height: 8),
          for (final t in byDay[_selected]?.transactions ?? const <Transaction>[]) TransactionTile(t),
        ],
      ],
    );
  }
}

class _MonthlyView extends ConsumerWidget {
  const _MonthlyView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = ref.watch(transactionsPeriodProvider).start.year;
    final flows = ref.watch(monthlyFlowsProvider).value ?? const <MonthlyFlow>[];
    return MonthList(year, {for (final f in flows) f.month: (f.income, f.expense)});
  }
}

/// The twelve months of [year], each with money in, out and the difference.
/// [totals] is keyed by `YYYY-MM`; missing months show zero.
class MonthList extends StatelessWidget {
  const MonthList(this.year, this.totals, {super.key});

  final int year;
  final Map<String, (int, int)> totals;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 88),
    children: [
      for (final month in [for (var m = 1; m <= 12; m++) DateTime(year, m)])
        if (totals[monthKey(month)] ?? (0, 0) case (final moneyIn, final moneyOut))
          ListTile(
            title: Text(DateFormat('MMMM').format(month)),
            subtitle: Wrap(
              spacing: 16,
              children: [
                MoneyText(moneyIn, tone: MoneyTone.income),
                MoneyText(moneyOut, tone: MoneyTone.expense),
              ],
            ),
            trailing: MoneyText(moneyIn - moneyOut, tone: MoneyTone.signed),
          ),
    ],
  );
}

class _CellAmount extends StatelessWidget {
  const _CellAmount(this.text, this.style);

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text(text, style: style, maxLines: 1),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(child: Text(message, style: Theme.of(context).textTheme.bodyLarge));
}

class TransactionTile extends ConsumerWidget {
  const TransactionTile(this.transaction, {super.key, this.showDate = false});

  final Transaction transaction;

  /// For flat lists with no day headers (search, a category's entries), so
  /// each row says when it happened.
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = transaction;
    final accounts = ref.watch(assetNamesProvider).value ?? const {};
    final categories = ref.watch(categoryNamesProvider).value ?? const {};
    final account = t.type == TransactionType.transfer
        ? '${accounts[t.assetId] ?? '?'} → ${accounts[t.toAssetId] ?? '?'}'
        : accounts[t.assetId] ?? '?';
    final title = t.type == TransactionType.transfer ? 'Transfer' : categories[t.categoryId] ?? 'No category';

    final text = Theme.of(context).textTheme;
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final note = t.note?.trim() ?? '';
    final small = text.bodySmall?.copyWith(color: grey);
    Text line(String value, TextStyle? style) =>
        Text(value, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);

    // Account, then category with the note under it, then amount. The row
    // hugs its text; the padding is the gap between rows and stays tappable.
    return InkWell(
      onTap: () => openTransactionForm(context, existing: t),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          spacing: 8,
          children: [
            Expanded(flex: 4, child: line(account, text.bodyMedium?.copyWith(color: grey))),
            Expanded(
              flex: 6,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [line(title, text.bodyMedium), if (note.isNotEmpty) line(note, small)],
              ),
            ),
            // One fixed width so the category column lines up on every row,
            // whatever the amount and date; a very large amount shrinks to fit.
            SizedBox(
              width: 88,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: MoneyText(
                      t.total,
                      tone: switch (t.type) {
                        TransactionType.income => MoneyTone.income,
                        TransactionType.expense => MoneyTone.expense,
                        TransactionType.transfer => MoneyTone.plain,
                      },
                    ),
                  ),
                  if (showDate)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(DateFormat('d MMM yyyy').format(t.dateTime), style: small),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
