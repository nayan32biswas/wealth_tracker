import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/repositories.dart';
import '../app/providers.dart';
import '../app/theme.dart';

enum MoneyTone { plain, income, expense, signed }

class MoneyText extends ConsumerWidget {
  const MoneyText(this.amount, {super.key, this.tone = MoneyTone.plain, this.style});

  final int amount;
  final MoneyTone tone;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      MoneyTone.plain => null,
      MoneyTone.income => scheme.income,
      MoneyTone.expense => scheme.expense,
      MoneyTone.signed => amount < 0 ? scheme.expense : null,
    };
    return Text(
      ref.watch(moneyFormatProvider).format(amount),
      style: (style ?? const TextStyle()).copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}

/// Runs [action] and shows a business-rule failure to the user instead of
/// crashing.
Future<void> guarded(BuildContext context, Future<void> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } on RuleViolation catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Shows a spinner that cannot be dismissed while [work] runs.
Future<T> whileBusy<T>(BuildContext context, String label, Future<T> work) async {
  // Above the tab bar: switching tabs would remove the screen under it.
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          spacing: 24,
          children: [
            const CircularProgressIndicator(),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    return await work;
  } finally {
    // Another dialog may already be open on top, so remove this exact one.
    navigator.removeRoute(route);
  }
}

String entryCount(int n) => n == 1 ? '1 entry' : '$n entries';

String? removeLabel(int id, int entries) => id == 0 ? null : (entries == 0 ? 'Delete' : 'Mark as deleted');

enum DialogAction { save, remove }

typedef EditResult<T> = (DialogAction, T?);

/// Shared shell for the small edit dialogs: remove (optional), Cancel, Save.
/// [value] returns null while the form is not valid.
class EditDialog<T> extends StatelessWidget {
  const EditDialog({
    super.key,
    required this.title,
    required this.children,
    required this.value,
    this.removeLabel,
    this.saveLabel = 'Save',
  });

  final String title;
  final List<Widget> children;
  final T? Function() value;
  final String? removeLabel;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final current = value();
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, spacing: 16, children: children),
      ),
      actions: [
        if (removeLabel case final label?)
          TextButton(
            onPressed: () => Navigator.pop<EditResult<T>>(context, (DialogAction.remove, null)),
            child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: current == null ? null : () => Navigator.pop<EditResult<T>>(context, (DialogAction.save, current)),
          child: Text(saveLabel),
        ),
      ],
    );
  }
}

/// A titled block of settings rows on a lighter card, with thin lines between
/// the rows.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          color: scheme.surfaceContainer,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[if (i > 0) const RowDivider(), child],
            ],
          ),
        ),
      ],
    );
  }
}

/// The light line between the rows of a list.
class RowDivider extends StatelessWidget {
  const RowDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
  );
}

/// A drag-to-reorder list (drag the handle or long-press a row) that reports
/// the new id order.
class ReorderableTiles extends StatelessWidget {
  const ReorderableTiles({super.key, required this.ids, required this.children, required this.onReorder, this.footer});

  final List<int> ids;
  final List<Widget> children;
  final Future<void> Function(List<int> idsInOrder) onReorder;

  /// Scrolls with the list, below the rows, and is not reorderable.
  final Widget? footer;

  @override
  Widget build(BuildContext context) => ReorderableListView(
    footer: footer,
    onReorderItem: (from, to) {
      final order = [...ids];
      order.insert(to, order.removeAt(from));
      onReorder(order);
    },
    children: [
      for (final (i, child) in children.indexed)
        Column(
          key: ValueKey(ids[i]),
          children: [
            if (i > 0) const RowDivider(),
            Row(
              children: [
                Expanded(child: child),
                // Long-press on a row also drags; the handle makes it visible.
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(padding: EdgeInsets.all(16), child: Icon(Icons.drag_handle)),
                ),
              ],
            ),
          ],
        ),
    ],
  );
}

typedef DeletedItem = ({String name, String? detail, Future<void> Function() restore, String restored});

/// Hidden items (deleted or archived), in titled sections, each with a
/// button that brings it back.
class DeletedList extends StatelessWidget {
  const DeletedList({
    super.key,
    required this.title,
    required this.empty,
    required this.sections,
    this.actionLabel = 'Restore',
  });

  final String title;
  final String empty;
  final List<(String, List<DeletedItem>)> sections;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final shown = sections.where((s) => s.$2.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: shown.isEmpty
          ? Center(child: Text(empty))
          : ListView(
              children: [
                for (final (heading, items) in shown) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      heading,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                  for (final (i, item) in items.indexed) ...[
                    if (i > 0) const RowDivider(),
                    ListTile(
                      title: Text(item.name),
                      subtitle: item.detail == null ? null : Text(item.detail!),
                      trailing: TextButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await guarded(context, () async {
                            await item.restore();
                            messenger.showSnackBar(SnackBar(content: Text(item.restored)));
                          });
                        },
                        child: Text(actionLabel),
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}
