import '../models/enums.dart';
import '../models/transactions.dart';
import '../repositories/repositories.dart';
import 'calendar.dart';

class DueOccurrences {
  const DueOccurrences(this.dates, this.nextDate, {required this.finished});

  final List<DateTime> dates;
  final DateTime nextDate;

  /// True when the rule passed its end date and will never fire again.
  final bool finished;
}

/// Every date from the rule's next date up to [today] (inclusive), so days
/// missed while the app was closed are caught up.
DueOccurrences dueOccurrences(RecurringRule rule, DateTime today) {
  final dates = <DateTime>[];
  for (var k = 0; ; k++) {
    final date = occurrence(rule, k);
    if (rule.endDate != null && date.isAfter(rule.endDate!)) {
      return DueOccurrences(dates, date, finished: true);
    }
    if (date.isAfter(today)) return DueOccurrences(dates, date, finished: false);
    if (!date.isBefore(rule.nextDate)) dates.add(date);
  }
}

// Occurrences are counted from the start date, not from the previous one,
// so a rule on the 31st falls back to the 30th/28th in short months but
// returns to the 31st afterwards.
DateTime occurrence(RecurringRule rule, int index) {
  final s = rule.startDate;
  final step = index * rule.interval;
  return switch (rule.frequency) {
    Frequency.daily => DateTime(s.year, s.month, s.day + step),
    Frequency.weekly => DateTime(s.year, s.month, s.day + 7 * step),
    Frequency.monthly => _clamped(s.year, s.month + step, s.day),
    Frequency.yearly => _clamped(s.year + step, s.month, s.day),
  };
}

DateTime _clamped(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDay ? lastDay : day);
}

/// Creates every due transaction for the active rules. Safe to run on each
/// app start and resume: dates already created are skipped.
Future<void> applyDueRecurring(RecurringRuleRepository repo, DateTime now) async {
  final today = dateOnly(now);
  for (final rule in await repo.active()) {
    final due = dueOccurrences(rule, today);
    if (due.dates.isNotEmpty || due.nextDate != rule.nextDate) {
      await repo.applyOccurrences(rule, due.dates, due.nextDate);
    }
    if (due.finished) await repo.save(rule.copyWith(nextDate: due.nextDate, isActive: false));
  }
}

/// Turns a new transaction into the first occurrence of a repeating rule,
/// saved together so the first entry is linked to its rule.
Future<void> startRecurring(RecurringRuleRepository repo, Transaction first, Frequency frequency) async {
  final start = dateOnly(first.dateTime);
  final draft = RecurringRule(
    id: 0,
    type: first.type,
    amount: first.amount,
    fee: first.fee,
    assetId: first.assetId,
    toAssetId: first.toAssetId,
    categoryId: first.categoryId,
    note: first.note,
    frequency: frequency,
    startDate: start,
    nextDate: start,
  );
  final rule = draft.copyWith(id: await repo.save(draft));
  await repo.applyOccurrences(rule, [first.dateTime], occurrence(rule, 1));
}

String frequencyLabel(Frequency frequency, int interval) {
  final unit = switch (frequency) {
    Frequency.daily => 'day',
    Frequency.weekly => 'week',
    Frequency.monthly => 'month',
    Frequency.yearly => 'year',
  };
  return interval == 1 ? 'Every $unit' : 'Every $interval ${unit}s';
}

/// A paused rule restarts from today: dates missed while it was paused are
/// skipped, not created in a burst.
RecurringRule resumeRule(RecurringRule rule, DateTime today) {
  final day = dateOnly(today);
  var k = 0;
  while (occurrence(rule, k).isBefore(day)) {
    k++;
  }
  return rule.copyWith(isActive: true, nextDate: occurrence(rule, k));
}
