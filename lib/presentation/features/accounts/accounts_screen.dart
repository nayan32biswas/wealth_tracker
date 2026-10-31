import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/accounts.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/period_switcher.dart';
import '../transactions/transactions_screen.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheet = ref.watch(balanceSheetProvider).value;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: sheet == null
            ? const SizedBox()
            : ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        _Figure('Assets', sheet.assets),
                        _Figure('Liabilities', sheet.liabilities),
                        _Figure('Net worth', sheet.netWorth, tone: MoneyTone.signed),
                      ],
                    ),
                  ),
                  // Accounts sit a little right of their group so the nesting
                  // shows; every amount keeps the same right edge.
                  for (final (g, shown) in [
                    for (final g in sheet.groups) (g, g.accounts.where((a) => !a.asset.isArchived || a.balance != 0)),
                  ])
                    if (shown.isNotEmpty) ...[
                      Container(
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(child: Text(g.group.name, style: text.titleSmall)),
                            MoneyText(owedOrHeld(g.group, g.total), style: text.titleSmall),
                          ],
                        ),
                      ),
                      // An archived account stays in view while it holds money.
                      for (final a in shown)
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 24, right: 16),
                          title: Text(a.asset.name),
                          subtitle: a.asset.isArchived ? const Text('Archived') : null,
                          trailing: MoneyText(owedOrHeld(g.group, a.balance), tone: MoneyTone.signed),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => AccountDetailScreen(account: a, group: g.group),
                            ),
                          ),
                        ),
                    ],
                ],
              ),
      ),
    );
  }
}

/// Liability balances are stored negative (money owed); show them as the
/// positive amount owed.
int owedOrHeld(AssetGroup group, int balance) => group.isLiability ? -balance : balance;

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.amount, {this.tone = MoneyTone.plain});

  final String label;
  final int amount;
  final MoneyTone tone;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        MoneyText(amount, tone: tone, style: Theme.of(context).textTheme.titleSmall),
      ],
    ),
  );
}

/// Freed when the account screen closes, so every visit starts on this
/// month and the Activity tab's period is left alone.
final _accountPeriodProvider = NotifierProvider.autoDispose<PeriodController, Period>(
  () => PeriodController(PeriodKind.month),
);

final _accountTransactionsProvider = StreamProvider.autoDispose.family<List<Transaction>, int>((ref, id) {
  final p = ref.watch(_accountPeriodProvider);
  return ref
      .watch(repositoriesProvider)
      .transactions
      .watch(TransactionQuery(assetIds: {id}, from: p.start, toExclusive: p.endExclusive));
});

/// Monthly steps through years, so the view follows the period's kind.
const _views = [ActivityView.daily, ActivityView.monthly];

Map<String, (int, int)> _byMonth(List<Transaction> txns, int accountId) {
  final months = <String, List<Transaction>>{};
  for (final t in txns) {
    months.putIfAbsent(monthKey(t.dateTime), () => []).add(t);
  }
  return {
    for (final MapEntry(:key, :value) in months.entries)
      if (AccountTotals.of(value, accountId) case final t) key: (t.inflow, t.outflow),
  };
}

class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen({super.key, required this.account, required this.group});

  final AccountBalance account;
  final AssetGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = account.asset.id;
    final balance = ref.watch(balanceSheetProvider).value?.balanceOf(id) ?? account.balance;
    final period = ref.watch(_accountPeriodProvider);
    final txns = ref.watch(_accountTransactionsProvider(id)).value ?? const <Transaction>[];
    final monthly = period.kind == PeriodKind.year;
    final text = Theme.of(context).textTheme;
    // One scroll: the balance and totals scroll away with the entries so the
    // list gets the screen, while the period bar stays pinned to change it.
    return Scaffold(
      appBar: AppBar(title: Text(account.asset.name)),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                spacing: 16,
                children: [
                  Text(group.isLiability ? 'Owed' : 'Balance', style: text.labelLarge),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: MoneyText(owedOrHeld(group, balance), tone: MoneyTone.signed, style: text.titleLarge),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          PinnedHeaderSliver(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: PeriodBar(
                  _accountPeriodProvider,
                  options: [for (final v in _views) v.option],
                  selected: (monthly ? ActivityView.monthly : ActivityView.daily).option,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(children: [TotalsBar.account(AccountTotals.of(txns, id)), const Divider(height: 1)]),
          ),
          if (monthly)
            MonthList(period.start.year, _byMonth(txns, id), sliver: true)
          else
            DayList(txns, accountId: id, sliver: true),
        ],
      ),
    );
  }
}
