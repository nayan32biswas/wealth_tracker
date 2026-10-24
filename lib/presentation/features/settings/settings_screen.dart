import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/app_settings.dart';
import '../../../domain/services/demo_data.dart';
import '../../../temporary/old_app_import/old_app_import_tile.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';
import '../security/security_settings.dart';
import 'accounts_settings_screen.dart';
import 'backup_settings.dart';
import 'categories_screen.dart';
import 'recurring_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final repos = ref.watch(repositoriesProvider);
    Future<void> save(AppSettings s) => repos.settings.save(s);
    void open(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SettingsSection(
            title: 'Data',
            children: [
              ListTile(title: const Text('Categories'), onTap: () => open(const CategoriesScreen())),
              ListTile(title: const Text('Accounts and groups'), onTap: () => open(const AccountsSettingsScreen())),
              ListTile(title: const Text('Recurring'), onTap: () => open(const RecurringScreen())),
            ],
          ),
          SettingsSection(
            title: 'Preferences',
            children: [
              ListTile(
                title: const Text('Currency'),
                subtitle: Text('${settings.currencySymbol} · ${settings.currencyCode}'),
                onTap: () async {
                  final edited = await showDialog<AppSettings>(
                    context: context,
                    builder: (_) => _CurrencyDialog(settings),
                  );
                  if (edited != null) await save(edited);
                },
              ),
              ListTile(
                title: const Text('First day of week'),
                subtitle: Text(_weekdayName(settings.weekStart)),
                onTap: () async {
                  final day = await _pick(context, 'First day of week', [
                    for (var d = DateTime.monday; d <= DateTime.sunday; d++) (d, _weekdayName(d)),
                  ]);
                  if (day != null) await save(settings.copyWith(weekStart: day));
                },
              ),
              ListTile(
                title: const Text('First day of month'),
                subtitle: Text('Day ${settings.monthStartDay}'),
                onTap: () async {
                  final day = await _pick(context, 'First day of month', [for (var d = 1; d <= 28; d++) (d, '$d')]);
                  if (day != null) await save(settings.copyWith(monthStartDay: day));
                },
              ),
            ],
          ),
          const BackupSettings(),
          const SecuritySettings(),
          SettingsSection(
            title: 'Developer',
            children: [
              const OldAppImportTile(), // Temporary: remove with lib/temporary/old_app_import/.
              if (kDebugMode)
                ListTile(
                  title: const Text('Load demo data'),
                  subtitle: const Text('Fills the ledger with sample entries'),
                  onTap: () => guarded(context, () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final hasData = await repos.transactions.hasAny();
                    if (!context.mounted) return;
                    final choice = await showDialog<EditResult<(int, bool)>>(
                      context: context,
                      builder: (_) => _DemoDataDialog(hasData: hasData),
                    );
                    if (choice == null || !context.mounted) return;
                    final (months, reset) = choice.$2!;
                    // One transaction: much faster than a write per entry, and a
                    // failure part-way leaves the ledger as it was.
                    await whileBusy(
                      context,
                      'Loading demo data…',
                      repos.inTransaction(() async {
                        if (reset) await repos.resetToStarter();
                        await loadDemoData(repos, ref.read(clockProvider)(), months: months);
                      }),
                    );
                    messenger.showSnackBar(
                      SnackBar(content: Text('Loaded $months ${months == 1 ? 'month' : 'months'} of demo data.')),
                    );
                  }),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _weekdayName(int weekday) => DateFormat('EEEE').format(DateTime(2024, 1, weekday));

  static Future<int?> _pick(BuildContext context, String title, List<(int, String)> options) => showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final (value, label) in options)
          SimpleDialogOption(onPressed: () => Navigator.pop(context, value), child: Text(label)),
      ],
    ),
  );
}

class _CurrencyDialog extends StatefulWidget {
  const _CurrencyDialog(this.settings);

  final AppSettings settings;

  @override
  State<_CurrencyDialog> createState() => _CurrencyDialogState();
}

class _CurrencyDialogState extends State<_CurrencyDialog> {
  late final _symbol = TextEditingController(text: widget.settings.currencySymbol);
  late final _code = TextEditingController(text: widget.settings.currencyCode);

  @override
  void dispose() {
    _symbol.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _symbol.text.trim().isNotEmpty && _code.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Currency'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          TextField(
            controller: _symbol,
            decoration: const InputDecoration(labelText: 'Symbol'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Code'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: valid
              ? () => Navigator.pop(
                  context,
                  widget.settings.copyWith(
                    currencySymbol: _symbol.text.trim(),
                    currencyCode: _code.text.trim().toUpperCase(),
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Returns how many months of demo data to load, and whether to reset the
/// ledger first.
class _DemoDataDialog extends StatefulWidget {
  const _DemoDataDialog({required this.hasData});

  final bool hasData;

  @override
  State<_DemoDataDialog> createState() => _DemoDataDialogState();
}

class _DemoDataDialogState extends State<_DemoDataDialog> {
  final _months = TextEditingController(text: '12');
  var _reset = false;

  @override
  void dispose() {
    _months.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final months = int.tryParse(_months.text);
    final valid = months != null && months >= 1;
    return EditDialog<(int, bool)>(
      title: 'Load demo data',
      saveLabel: 'Load',
      value: () => valid ? (months, _reset) : null,
      children: [
        TextField(
          controller: _months,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: 'Months', errorText: valid ? null : 'Enter 1 or more'),
          onChanged: (_) => setState(() {}),
        ),
        if (widget.hasData)
          CheckboxListTile(
            value: _reset,
            onChanged: (value) => setState(() => _reset = value!),
            contentPadding: EdgeInsets.zero,
            title: const Text('Remove existing data first'),
            subtitle: const Text('Resets accounts and categories to the starter set'),
          ),
      ],
    );
  }
}
