import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/services/calendar.dart';
import 'package:wealthtracker/domain/services/recurring.dart';

void main() {
  group('Period', () {
    test('calendar month when the month starts on day 1', () {
      final p = Period.containing(PeriodKind.month, DateTime(2026, 9, 23), monthStartDay: 1);

      expect(p.start, DateTime(2026, 9));
      expect(p.endExclusive, DateTime(2026, 10));
    });

    test('custom month start keeps days before it in the previous period', () {
      final p = Period.containing(PeriodKind.month, DateTime(2026, 9, 3), monthStartDay: 25);

      expect(p.start, DateTime(2026, 8, 25));
      expect(p.endExclusive, DateTime(2026, 9, 25));
    });

    test('year period', () {
      final p = Period.containing(PeriodKind.year, DateTime(2026, 9, 23));

      expect(p.start, DateTime(2026));
      expect(p.endExclusive, DateTime(2027));
    });

    test('next and previous move by one period', () {
      final p = Period.containing(PeriodKind.month, DateTime(2026, 12, 5), monthStartDay: 1);

      expect(p.next().start, DateTime(2027));
      expect(p.previous().start, DateTime(2026, 11));
    });

    // Bangladesh used daylight saving from 19 June 2009, so this range has a
    // 23-hour day in the device's local time zone.
    test('stepping a custom range counts calendar days, not hours', () {
      final p = Period.custom(DateTime(2009, 6, 15), DateTime(2009, 6, 24));

      expect(p.next().start, DateTime(2009, 6, 25));
      expect(p.next().lastDay, DateTime(2009, 7, 4));
      expect(p.previous().start, DateTime(2009, 6, 5));
    });

    test('custom range covers both chosen days', () {
      final p = Period.custom(DateTime(2026, 9, 1), DateTime(2026, 9, 10));

      expect(p.start, DateTime(2026, 9));
      expect(p.endExclusive, DateTime(2026, 9, 11));
    });
  });

  group('recurring schedule', () {
    RecurringRule rule(Frequency frequency, DateTime start, {DateTime? next, int interval = 1, DateTime? end}) =>
        RecurringRule(
          id: 1,
          type: TransactionType.expense,
          amount: 100,
          assetId: 1,
          frequency: frequency,
          interval: interval,
          startDate: start,
          nextDate: next ?? start,
          endDate: end,
        );

    test('catches up on every missed date up to today', () {
      final due = dueOccurrences(rule(Frequency.daily, DateTime(2026, 9, 20)), DateTime(2026, 9, 23));

      expect(due.dates, [DateTime(2026, 9, 20), DateTime(2026, 9, 21), DateTime(2026, 9, 22), DateTime(2026, 9, 23)]);
      expect(due.nextDate, DateTime(2026, 9, 24));
    });

    test('skips dates already created', () {
      final due = dueOccurrences(
        rule(Frequency.weekly, DateTime(2026, 9, 1), next: DateTime(2026, 9, 15)),
        DateTime(2026, 9, 23),
      );

      expect(due.dates, [DateTime(2026, 9, 15), DateTime(2026, 9, 22)]);
      expect(due.nextDate, DateTime(2026, 9, 29));
    });

    test('nothing is due before the start date', () {
      final due = dueOccurrences(rule(Frequency.monthly, DateTime(2026, 10, 1)), DateTime(2026, 9, 23));

      expect(due.dates, isEmpty);
      expect(due.nextDate, DateTime(2026, 10, 1));
    });

    test('monthly on the 31st falls back to the last day and returns to the 31st', () {
      final due = dueOccurrences(rule(Frequency.monthly, DateTime(2026, 1, 31)), DateTime(2026, 5, 1));

      expect(due.dates, [DateTime(2026, 1, 31), DateTime(2026, 2, 28), DateTime(2026, 3, 31), DateTime(2026, 4, 30)]);
      expect(due.nextDate, DateTime(2026, 5, 31));
    });

    test('yearly on 29 February uses 28 February in other years', () {
      final due = dueOccurrences(rule(Frequency.yearly, DateTime(2024, 2, 29)), DateTime(2026, 3, 1));

      expect(due.dates, [DateTime(2024, 2, 29), DateTime(2025, 2, 28), DateTime(2026, 2, 28)]);
    });

    test('interval skips periods', () {
      final due = dueOccurrences(rule(Frequency.monthly, DateTime(2026, 1, 10), interval: 3), DateTime(2026, 9, 23));

      expect(due.dates, [DateTime(2026, 1, 10), DateTime(2026, 4, 10), DateTime(2026, 7, 10)]);
    });

    test('turning a paused rule back on skips the dates missed while paused', () {
      final paused = rule(
        Frequency.monthly,
        DateTime(2026, 1, 1),
        next: DateTime(2026, 2, 1),
      ).copyWith(isActive: false);

      final resumed = resumeRule(paused, DateTime(2026, 6, 15));

      expect(resumed.isActive, isTrue);
      expect(resumed.nextDate, DateTime(2026, 7, 1));
      expect(dueOccurrences(resumed, DateTime(2026, 6, 15)).dates, isEmpty);
    });

    test('resuming on a due day keeps that day', () {
      final paused = rule(
        Frequency.monthly,
        DateTime(2026, 1, 1),
        next: DateTime(2026, 2, 1),
      ).copyWith(isActive: false);

      expect(resumeRule(paused, DateTime(2026, 6, 1)).nextDate, DateTime(2026, 6, 1));
    });

    test('stops at the end date', () {
      final due = dueOccurrences(
        rule(Frequency.daily, DateTime(2026, 9, 20), end: DateTime(2026, 9, 21)),
        DateTime(2026, 9, 23),
      );

      expect(due.dates, [DateTime(2026, 9, 20), DateTime(2026, 9, 21)]);
      expect(due.finished, isTrue);
    });
  });

  group('applying due rules', () {
    late AppDatabase db;
    late DriftRepositories repos;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repos = DriftRepositories(db);
    });
    tearDown(() => db.close());

    Future<int> addRule({DateTime? end}) async => repos.recurring.save(
      RecurringRule(
        id: 0,
        type: TransactionType.expense,
        amount: 2500000,
        assetId: (await repos.assets.all()).first.id,
        categoryId: (await repos.categories.all()).first.id,
        frequency: Frequency.monthly,
        startDate: DateTime(2026, 7, 5),
        nextDate: DateTime(2026, 7, 5),
        endDate: end,
      ),
    );

    test('creates every due transaction up to today', () async {
      await addRule();

      await applyDueRecurring(repos.recurring, DateTime(2026, 9, 23, 15));

      final txns = await repos.transactions.find(const TransactionQuery());
      expect(txns.map((t) => t.dateTime), [DateTime(2026, 9, 5), DateTime(2026, 8, 5), DateTime(2026, 7, 5)]);
      expect((await repos.recurring.active()).single.nextDate, DateTime(2026, 10, 5));
    });

    test('running again the same day creates nothing new', () async {
      await addRule();

      await applyDueRecurring(repos.recurring, DateTime(2026, 9, 23));
      await applyDueRecurring(repos.recurring, DateTime(2026, 9, 23));

      expect(await repos.transactions.find(const TransactionQuery()), hasLength(3));
    });

    test('a rule past its end date is switched off', () async {
      await addRule(end: DateTime(2026, 8, 31));

      await applyDueRecurring(repos.recurring, DateTime(2026, 9, 23));

      expect(await repos.transactions.find(const TransactionQuery()), hasLength(2));
      expect(await repos.recurring.active(), isEmpty);
    });
  });
}
