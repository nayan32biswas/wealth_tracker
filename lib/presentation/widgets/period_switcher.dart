import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/services/calendar.dart';
import '../app/providers.dart';

/// A choice in the period bar's menu and the kind of period it shows.
/// Two choices may share a kind (Activity's Daily and Calendar are both a
/// month).
typedef PeriodOption = ({String label, PeriodKind kind});

const periodKindOptions = <PeriodOption>[
  (label: 'Month', kind: PeriodKind.month),
  (label: 'Year', kind: PeriodKind.year),
  (label: 'Custom', kind: PeriodKind.custom),
];

/// One line: previous / period label / next on the left, a menu of
/// [options] on the right. Tapping the label jumps straight to any past or
/// future period.
class PeriodBar extends ConsumerWidget {
  const PeriodBar(
    this.provider, {
    super.key,
    this.options = periodKindOptions,
    this.selected,
    this.onSelected,
    this.menuInset = 0,
  });

  final NotifierProvider<PeriodController, Period> provider;
  final List<PeriodOption> options;

  /// The option shown in the menu; defaults to the one matching the
  /// current period's kind.
  final PeriodOption? selected;

  /// Called once the period has changed to match the chosen option (not
  /// when a custom range is cancelled).
  final ValueChanged<PeriodOption>? onSelected;

  /// Space kept to the right of the menu.
  final double menuInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final current = selected ?? options.firstWhere((o) => o.kind == period.kind, orElse: () => options.first);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Previous',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left),
                onPressed: controller.previous,
              ),
              Flexible(
                child: TextButton(
                  onPressed: () => _jump(context, ref),
                  child: Text(
                    periodLabel(period),
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right),
                onPressed: controller.next,
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.only(right: menuInset),
          child: PeriodMenu<PeriodOption>(
            options: [for (final o in options) (o, o.label)],
            selected: current,
            onSelected: (option) => _choose(context, ref, option),
          ),
        ),
      ],
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref, PeriodOption option) async {
    final current = ref.read(provider);
    if (option.kind == PeriodKind.custom) {
      final range = await _pickRange(context, current);
      if (range == null || !context.mounted) return;
      ref.read(provider.notifier).set(Period.custom(range.start, range.end));
    } else {
      ref
          .read(provider.notifier)
          .set(
            Period.containing(
              option.kind,
              switchAnchor(current, ref.read(clockProvider)()),
              monthStartDay: ref.read(settingsProvider).monthStartDay,
            ),
          );
    }
    onSelected?.call(option);
  }

  Future<void> _jump(BuildContext context, WidgetRef ref) async {
    final current = ref.read(provider);
    final s = ref.read(settingsProvider);
    Period at(DateTime d) => Period.containing(current.kind, d, monthStartDay: s.monthStartDay);
    final Future<Period?> pick = switch (current.kind) {
      // A month period starts on monthStartDay, so anchor there to land on
      // the month the user tapped.
      PeriodKind.month => showDialog<DateTime>(
        context: context,
        builder: (_) => _MonthPicker(initial: current.start),
      ).then((m) => m == null ? null : at(DateTime(m.year, m.month, s.monthStartDay))),
      PeriodKind.year => showDialog<DateTime>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose a year'),
          content: SizedBox(
            width: 300,
            height: 300,
            child: YearPicker(
              firstDate: _first,
              lastDate: _last,
              selectedDate: current.start,
              onChanged: (d) => Navigator.pop(context, d),
            ),
          ),
        ),
      ).then((d) => d == null ? null : at(d)),
      PeriodKind.custom => _pickRange(context, current).then((r) => r == null ? null : Period.custom(r.start, r.end)),
    };
    final picked = await pick;
    if (picked != null && context.mounted) ref.read(provider.notifier).set(picked);
  }

  Future<DateTimeRange?> _pickRange(BuildContext context, Period current) => showDateRangePicker(
    context: context,
    firstDate: _first,
    lastDate: _last,
    initialDateRange: DateTimeRange(start: current.start, end: current.lastDay),
  );
}

/// The "Month ▾" menu at the right of a period row.
class PeriodMenu<T> extends StatelessWidget {
  const PeriodMenu({super.key, required this.options, required this.selected, required this.onSelected});

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: 'Period type',
    initialValue: selected,
    onSelected: onSelected,
    itemBuilder: (_) => [for (final (value, label) in options) PopupMenuItem(value: value, child: Text(label))],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(options.firstWhere((o) => o.$1 == selected).$2, style: Theme.of(context).textTheme.labelLarge),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

final _first = DateTime(2000);
final _last = DateTime(2100);

/// Year arrows over a grid of the twelve months.
class _MonthPicker extends StatefulWidget {
  const _MonthPicker({required this.initial});

  final DateTime initial;

  @override
  State<_MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<_MonthPicker> {
  late int _year = widget.initial.year;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          IconButton(
            tooltip: 'Previous year',
            icon: const Icon(Icons.chevron_left),
            onPressed: _year > _first.year ? () => setState(() => _year--) : null,
          ),
          Expanded(child: Center(child: Text('$_year'))),
          IconButton(
            tooltip: 'Next year',
            icon: const Icon(Icons.chevron_right),
            onPressed: _year < _last.year ? () => setState(() => _year++) : null,
          ),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 3,
          childAspectRatio: 2,
          children: [
            for (var m = 1; m <= 12; m++)
              TextButton(
                style: _year == widget.initial.year && m == widget.initial.month
                    ? TextButton.styleFrom(backgroundColor: scheme.secondaryContainer)
                    : null,
                onPressed: () => Navigator.pop(context, DateTime(_year, m)),
                child: Text(DateFormat('MMM').format(DateTime(_year, m))),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// When switching between month and year, stay on today if the
/// current period holds it; otherwise stay near the period being viewed.
DateTime switchAnchor(Period current, DateTime today) =>
    !today.isBefore(current.start) && today.isBefore(current.endExclusive) ? today : current.start;

String periodLabel(Period p) {
  if (p.kind == PeriodKind.year) return DateFormat('yyyy').format(p.start);
  if (p.kind == PeriodKind.month && p.start.day == 1) return DateFormat('MMM yyyy').format(p.start);
  return rangeLabel(p.start, p.lastDay);
}

String rangeLabel(DateTime first, DateTime last) {
  final end = DateFormat('d MMM yyyy').format(last);
  if (first.year != last.year) return '${DateFormat('d MMM yyyy').format(first)} – $end';
  if (first.month != last.month) return '${DateFormat('d MMM').format(first)} – $end';
  return '${first.day} – $end';
}
