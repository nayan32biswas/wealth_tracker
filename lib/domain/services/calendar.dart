String dateKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

String monthKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}';

DateTime parseDateKey(String key) {
  final [y, m, d] = key.split('-').map(int.parse).toList();
  return DateTime(y, m, d);
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _two(int n) => n.toString().padLeft(2, '0');

enum PeriodKind { month, year, custom }

class Period {
  const Period._(this.kind, this.start, this.endExclusive, this.monthStartDay);

  factory Period.containing(PeriodKind kind, DateTime date, {int monthStartDay = 1}) {
    final d = dateOnly(date);
    final (start, end) = switch (kind) {
      PeriodKind.month => _month(d, monthStartDay),
      PeriodKind.year => (DateTime(d.year), DateTime(d.year + 1)),
      PeriodKind.custom => (d, DateTime(d.year, d.month, d.day + 1)),
    };
    return Period._(kind, start, end, monthStartDay);
  }

  factory Period.custom(DateTime first, DateTime last) {
    final l = dateOnly(last);
    return Period._(PeriodKind.custom, dateOnly(first), DateTime(l.year, l.month, l.day + 1), 1);
  }

  final PeriodKind kind;
  final DateTime start;
  final DateTime endExclusive;
  final int monthStartDay;

  DateTime get lastDay => DateTime(endExclusive.year, endExclusive.month, endExclusive.day - 1);

  Period next() => _shift(1);

  Period previous() => _shift(-1);

  Period _shift(int step) {
    if (kind == PeriodKind.custom) {
      final days = _calendarDays(start, endExclusive) * step;
      return Period.custom(_addDays(start, days), _addDays(lastDay, days));
    }
    final anchor = step > 0 ? endExclusive : _addDays(start, -1);
    return Period.containing(kind, anchor, monthStartDay: monthStartDay);
  }

  // A month period runs from monthStartDay to the day before the next
  // monthStartDay, so salary-cycle months (e.g. 25th to 24th) work.
  static (DateTime, DateTime) _month(DateTime d, int startDay) {
    final start = d.day >= startDay ? DateTime(d.year, d.month, startDay) : DateTime(d.year, d.month - 1, startDay);
    return (start, DateTime(start.year, start.month + 1, startDay));
  }

  // Counted on UTC dates: a local day can be 23 or 25 hours long when
  // daylight saving starts or ends.
  static int _calendarDays(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  static DateTime _addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);
}
