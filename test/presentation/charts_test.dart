import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/presentation/widgets/charts.dart';

void main() {
  group('AxisScale', () {
    (double, double, double) of(Iterable<num> values, {num minStep = 1, bool fromZero = true}) {
      final s = AxisScale.of(values, minStep: minStep, fromZero: fromZero);
      return (s.min, s.max, s.step);
    }

    test('picks a round step and rounds the top up to it', () {
      expect(of([0, 6796300], minStep: 100), (0, 8000000, 2000000));
      expect(AxisScale.of([0, 6796300], minStep: 100).values, [0, 2000000, 4000000, 6000000, 8000000]);
    });

    test('starts at zero unless told not to', () {
      expect(of([230000000, 236000000]), (0, 300000000, 100000000));
      expect(of([230000000, 236000000], fromZero: false), (230000000, 236000000, 2000000));
    });

    test('covers negative values on round steps', () {
      expect(of([-50, 120]), (-50, 150, 50));
    });

    test('an empty or flat chart still gets one step of the smallest size', () {
      expect(of([0, 0], minStep: 100), (0, 100, 100));
      expect(of([], minStep: 100), (0, 100, 100));
      expect(of([5000, 5000], minStep: 100, fromZero: false), (5000, 5100, 100));
    });
  });
}
