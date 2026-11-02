import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

// The look every Stats chart shares: faint horizontal lines on round
// values, labels along the bottom and the left, and dark tooltips.

/// Round bounds and step for the left axis, so every grid line sits on a
/// labelled value like 20K rather than 17,342.
class AxisScale {
  const AxisScale._(this.min, this.max, this.step);

  /// [minStep] keeps labels apart when the values barely differ, e.g. one
  /// whole currency unit for money. Charts start at zero so heights compare
  /// honestly; [fromZero] off lets net worth use its own range instead.
  factory AxisScale.of(Iterable<num> values, {num minStep = 1, bool fromZero = true}) {
    final all = [for (final v in values) v.toDouble()];
    var low = all.isEmpty ? 0.0 : all.reduce(math.min);
    var high = all.isEmpty ? 0.0 : all.reduce(math.max);
    if (fromZero) {
      low = math.min(low, 0);
      high = math.max(high, 0);
    }
    final rough = math.max((high - low) / 4, minStep.toDouble());
    final magnitude = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
    final step = [1, 2, 5, 10].map((m) => m * magnitude).firstWhere((s) => s >= rough * (1 - 1e-9));
    final min = (low / step).floor() * step;
    final max = (high / step).ceil() * step;
    return AxisScale._(min, max > min ? max : min + step, step);
  }

  final double min;
  final double max;
  final double step;

  Iterable<double> get values => [for (var i = 0; i <= ((max - min) / step).round(); i++) min + i * step];
}

FlGridData chartGrid(ColorScheme scheme, AxisScale scale) => FlGridData(
  drawVerticalLine: false,
  horizontalInterval: scale.step,
  getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant, strokeWidth: 0.5),
);

/// [bottom] returns null to leave a slot blank. [left] labels the values
/// of [scale].
FlTitlesData chartTitles(
  BuildContext context, {
  required String? Function(int index) bottom,
  double? interval,
  required AxisScale scale,
  required String Function(double value) left,
}) {
  final scheme = Theme.of(context).colorScheme;
  final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
  const gap = 6.0;
  var widest = 0.0;
  for (final value in scale.values) {
    final painter = TextPainter(
      text: TextSpan(text: left(value), style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  return FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: scale.step,
        reservedSize: widest.ceilToDouble() + gap,
        getTitlesWidget: (value, meta) => SideTitleWidget(
          meta: meta,
          space: gap,
          child: Text(left(value), style: style),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: interval,
        getTitlesWidget: (value, meta) {
          final text = bottom(value.toInt());
          return text == null
              ? const SizedBox()
              : SideTitleWidget(
                  meta: meta,
                  child: Text(text, style: style),
                );
        },
      ),
    ),
  );
}

LineTouchData lineTooltip(ColorScheme scheme, String Function(LineBarSpot spot) text) => LineTouchData(
  touchTooltipData: LineTouchTooltipData(
    getTooltipColor: (_) => scheme.inverseSurface,
    getTooltipItems: (spots) => [
      for (final s in spots) LineTooltipItem(text(s), TextStyle(color: scheme.onInverseSurface)),
    ],
  ),
);

BarTouchData barTooltip(
  ColorScheme scheme,
  String Function(BarChartGroupData group, double value, int rodIndex) text,
) => BarTouchData(
  touchTooltipData: BarTouchTooltipData(
    getTooltipColor: (_) => scheme.inverseSurface,
    getTooltipItem: (group, _, rod, rodIndex) =>
        BarTooltipItem(text(group, rod.toY, rodIndex), TextStyle(color: scheme.onInverseSurface)),
  ),
);

/// Square swatches for bar charts, thin strokes ([lines]) for line charts.
class ChartLegend extends StatelessWidget {
  const ChartLegend(this.items, {super.key, this.lines = false});

  final List<(String, Color)> items;
  final bool lines;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    children: [
      for (final (label, color) in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Container(
              width: 12,
              height: lines ? 3 : 12,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(lines ? 2 : 3)),
            ),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
    ],
  );
}
