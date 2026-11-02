import 'package:flutter/material.dart';

import 'common.dart';

/// A form field that picks one of [choices] in a dialog. A dropdown's menu
/// has no header, so a long list that fills a phone screen has nothing to
/// close it with; this dialog has a title and a close button.
class PickField<T> extends StatelessWidget {
  const PickField({
    super.key,
    required this.label,
    required this.choices,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<(T, String)> choices;
  final T? value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final name = choices.where((c) => c.$1 == value).firstOrNull?.$2;
    return InkWell(
      onTap: () async {
        final picked = await pickOne(context, title: label, choices: choices, selected: value);
        if (picked != null) onChanged(picked.$1);
      },
      child: InputDecorator(
        isEmpty: name == null,
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.arrow_drop_down)),
        child: Text(
          name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}

/// One of [choices] in a dialog with a title and a close cross, the current
/// one ticked. Null when closed without picking.
Future<(T,)?> pickOne<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> choices,
  T? selected,
}) => showDialog<(T,)>(
  context: context,
  builder: (_) => _PickDialog<T>(title: title, choices: choices, selected: selected),
);

class _PickDialog<T> extends StatelessWidget {
  const _PickDialog({required this.title, required this.choices, required this.selected});

  final String title;
  final List<(T, String)> choices;
  final T? selected;

  @override
  Widget build(BuildContext context) => Dialog(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              const CloseButton(),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final (i, (value, name)) in choices.indexed) ...[
                if (i > 0) const RowDivider(),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(name),
                  selected: value == selected,
                  trailing: value == selected ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, (value,)),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
