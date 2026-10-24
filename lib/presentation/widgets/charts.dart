import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

// The look every Stats chart shares: faint horizontal lines, labels only
// along the bottom, and dark tooltips.

FlGridData chartGrid(ColorScheme scheme) => FlGridData(
  drawVerticalLine: false,
  getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant, strokeWidth: 0.5),
);

/// [label] returns null to leave a slot blank.
FlTitlesData bottomTitles(BuildContext context, String? Function(int index) label, {double? interval}) {
  final scheme = Theme.of(context).colorScheme;
  final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
  return FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: const AxisTitles(),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: interval,
        getTitlesWidget: (value, meta) {
          final text = label(value.toInt());
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
