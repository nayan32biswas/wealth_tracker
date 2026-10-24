// TEMPORARY: see old_app_converter.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../domain/repositories/repositories.dart';
import '../../presentation/app/providers.dart';
import '../../presentation/widgets/common.dart';
import 'old_app_converter.dart';

/// Settings row that replaces all data with the old app's database.
class OldAppImportTile extends ConsumerWidget {
  const OldAppImportTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    title: const Text('Import from old app (temporary)'),
    subtitle: const Text("Replaces all data with the old app's database file"),
    onTap: () => guarded(context, () => _import(context, ref)),
  );

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final files = ref.read(filesProvider);
    final bytes = await files.pickFile();
    if (bytes == null || !context.mounted) return;
    final dir = await files.tempDirectory();
    final oldPath = p.join(dir, 'old_app.sqlite');
    final outPath = p.join(dir, 'old_app_import.sqlite');
    try {
      File(oldPath).writeAsBytesSync(bytes);
      final settings = await ref.read(repositoriesProvider).settings.get();
      final nowMs = ref.read(clockProvider)().millisecondsSinceEpoch;
      if (!context.mounted) return;
      final OldAppData data;
      try {
        data = await whileBusy(
          context,
          'Reading the old data…',
          convertOldApp(oldPath, outPath, settings: settings, nowMs: nowMs),
        );
      } on FormatException catch (e) {
        throw RuleViolation(e.message);
      }
      final restorer = ref.read(restorerProvider);
      if (restorer.check(outPath) case final problem?) throw RuleViolation(problem);
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(context: context, builder: (_) => _SummaryDialog(data));
      if (confirmed == true) await restorer.restore(outPath);
    } finally {
      for (final path in [oldPath, outPath]) {
        if (File(path).existsSync()) File(path).deleteSync();
      }
    }
  }
}

class _SummaryDialog extends StatelessWidget {
  const _SummaryDialog(this.data);

  final OldAppData data;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Replace all data?'),
    content: SingleChildScrollView(
      child: Text(
        [
          'Found ${data.assets.length} accounts and ${data.categories.length} categories.',
          'Entries: ${data.count('income')} income, ${data.count('expense')} expense, '
              '${data.count('transfer')} transfers.',
          for (final MapEntry(key: what, value: n) in data.changed.entries) n > 1 ? '$what: $n' : what,
          for (final MapEntry(key: reason, value: ids) in data.skipped.entries)
            'Skipped, $reason: ${ids.length} (ids ${ids.join(', ')})',
          '',
          'Everything on this phone will be replaced. This cannot be undone.',
        ].join('\n'),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
    ],
  );
}
