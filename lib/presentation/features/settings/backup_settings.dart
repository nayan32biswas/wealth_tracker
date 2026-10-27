import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../domain/repositories/repositories.dart';
import '../../../domain/services/backup_crypto.dart';
import '../../../domain/services/calendar.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';

const _minPasswordLength = 8;

/// The Backup rows shown in Settings.
class BackupSettings extends ConsumerWidget {
  const BackupSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.read(filesProvider);
    final backup = ref.read(backupProvider);
    final cipher = ref.read(backupCipherProvider);
    final messenger = ScaffoldMessenger.of(context);
    void tell(String message) => messenger.showSnackBar(SnackBar(content: Text(message)));

    Future<String> exportPath(String extension) async {
      await files.clearExports();
      return p.join(await files.tempDirectory(), '$exportFilePrefix${dateKey(ref.read(clockProvider)())}.$extension');
    }

    return SettingsSection(
      title: 'Backup',
      children: [
        ListTile(
          title: const Text('Export backup'),
          subtitle: const Text('A full copy of your data'),
          onTap: () => _safely(context, () async {
            final choice = await showDialog<EditResult<String>>(
              context: context,
              builder: (_) => const _ExportPasswordDialog(),
            );
            if (choice == null) return;
            final password = choice.$2!;
            final plainPath = await exportPath('sqlite');
            await backup.exportSqlite(plainPath);
            if (password.isEmpty) return files.share(plainPath);

            // The unencrypted copy must not stay behind in the temp folder.
            final Uint8List plain;
            try {
              plain = File(plainPath).readAsBytesSync();
            } finally {
              File(plainPath).deleteSync();
            }
            if (!context.mounted) return;
            final sealed = await whileBusy(context, 'Encrypting backup…', cipher.encrypt(plain, password));
            final path = p.setExtension(plainPath, '.wtbackup');
            File(path).writeAsBytesSync(sealed);
            await files.share(path);
          }),
        ),
        ListTile(
          title: const Text('Restore from backup'),
          subtitle: const Text('Replaces all data on this phone'),
          onTap: () => _safely(context, () async {
            var bytes = await files.pickFile();
            if (bytes == null || !context.mounted) return;
            if (cipher.isEncrypted(bytes)) {
              bytes = await _unlockBackup(context, cipher, bytes);
              if (bytes == null) return;
            }
            final path = p.join(await files.tempDirectory(), 'restore.sqlite');
            File(path).writeAsBytesSync(bytes);
            try {
              final restorer = ref.read(restorerProvider);
              final problem = restorer.check(path);
              if (problem != null) return tell(problem);
              if (!context.mounted) return;
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Replace all data?'),
                  content: const Text(
                    'Everything on this phone will be replaced by the backup. This cannot be undone.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
                  ],
                ),
              );
              if (confirmed == true) await restorer.restore(path);
            } finally {
              // Restore works on its own copy, so the decrypted file can go.
              if (File(path).existsSync()) File(path).deleteSync();
            }
          }),
        ),
        ListTile(
          title: const Text('Export CSV'),
          subtitle: const Text('Transactions for a spreadsheet'),
          onTap: () => _safely(context, () async {
            final path = await exportPath('csv');
            File(path).writeAsStringSync(await backup.exportCsv());
            await files.share(path);
          }),
        ),
        ListTile(
          title: const Text('Import CSV'),
          subtitle: const Text('Adds transactions from a spreadsheet'),
          onTap: () => _safely(context, () async {
            final bytes = await files.pickFile();
            if (bytes == null) return;
            final preview = await backup.previewCsv(utf8.decode(bytes, allowMalformed: true));
            if (!context.mounted) return;
            await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _CsvPreviewScreen(preview)));
          }),
        ),
      ],
    );
  }
}

/// Like [guarded], and also explains file errors such as a full disk.
Future<void> _safely(BuildContext context, Future<void> Function() action) => guarded(context, () async {
  try {
    await action();
  } on FileSystemException {
    throw const RuleViolation('Could not read or write the file. Check free space and try again.');
  }
});

/// Asks for the password until it opens [file]. Null when the user gives up.
Future<Uint8List?> _unlockBackup(BuildContext context, BackupCipher cipher, Uint8List file) async {
  String? error;
  while (context.mounted) {
    final choice = await showDialog<EditResult<String>>(
      context: context,
      builder: (_) => _UnlockBackupDialog(error: error),
    );
    if (choice == null || !context.mounted) return null;
    try {
      return await whileBusy(context, 'Opening backup…', cipher.decrypt(file, choice.$2!));
    } on WrongBackupPassword catch (e) {
      error = e.message;
    }
  }
  return null;
}

/// Returns '' for a plain backup, or the new password.
class _ExportPasswordDialog extends StatefulWidget {
  const _ExportPasswordDialog();

  @override
  State<_ExportPasswordDialog> createState() => _ExportPasswordDialogState();
}

class _ExportPasswordDialogState extends State<_ExportPasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  var _protect = false;
  var _show = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final password = _password.text;
    final confirm = _confirm.text;
    final tooShort = password.isNotEmpty && password.length < _minPasswordLength;
    final mismatch = confirm.isNotEmpty && confirm != password;
    return EditDialog<String>(
      title: 'Export backup',
      saveLabel: 'Export',
      value: () {
        if (!_protect) return '';
        return password.isEmpty || tooShort || password != confirm ? null : password;
      },
      children: [
        const Text('A full copy of your data that you can restore later.'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Protect with a password'),
          value: _protect,
          onChanged: (on) => setState(() {
            _protect = on;
            // A password typed and then switched off must not linger.
            if (!on) {
              _password.clear();
              _confirm.clear();
            }
          }),
        ),
        if (_protect) ...[
          const Text("If you forget the password, the backup can't be opened."),
          _PasswordField(
            _password,
            'Password',
            autofocus: true,
            show: _show,
            onChanged: () => setState(() {}),
            onToggle: () => setState(() => _show = !_show),
            error: tooShort ? 'Use at least $_minPasswordLength characters' : null,
          ),
          _PasswordField(
            _confirm,
            'Confirm password',
            show: _show,
            onChanged: () => setState(() {}),
            error: mismatch ? 'Passwords do not match' : null,
          ),
        ],
      ],
    );
  }
}

class _UnlockBackupDialog extends StatefulWidget {
  const _UnlockBackupDialog({this.error});

  final String? error;

  @override
  State<_UnlockBackupDialog> createState() => _UnlockBackupDialogState();
}

class _UnlockBackupDialogState extends State<_UnlockBackupDialog> {
  final _password = TextEditingController();
  var _show = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog<String>(
    title: 'Backup password',
    saveLabel: 'Open',
    value: () => _password.text.isEmpty ? null : _password.text,
    children: [
      const Text('This backup is protected. Enter the password used when it was exported.'),
      _PasswordField(
        _password,
        'Password',
        show: _show,
        onChanged: () => setState(() {}),
        onToggle: () => setState(() => _show = !_show),
        error: widget.error,
      ),
    ],
  );
}

class _PasswordField extends StatelessWidget {
  const _PasswordField(
    this.controller,
    this.label, {
    required this.show,
    required this.onChanged,
    this.onToggle,
    this.error,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final bool show;
  final VoidCallback onChanged;
  final VoidCallback? onToggle;
  final String? error;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: !show,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(
      labelText: label,
      errorText: error,
      suffixIcon: onToggle == null
          ? null
          : IconButton(
              tooltip: show ? 'Hide password' : 'Show password',
              icon: Icon(show ? Icons.visibility_off : Icons.visibility),
              onPressed: onToggle,
            ),
    ),
    onChanged: (_) => onChanged(),
  );
}

class _CsvPreviewScreen extends ConsumerWidget {
  const _CsvPreviewScreen(this.preview);

  final CsvPreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final error = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: const Text('Import CSV')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${preview.rows.length} transactions ready', style: text.titleMedium),
          if (preview.newAccounts.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('New accounts', style: text.labelLarge),
            Text(preview.newAccounts.join(', ')),
          ],
          if (preview.newCategories.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('New categories', style: text.labelLarge),
            Text(preview.newCategories.join(', ')),
          ],
          if (preview.errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Fix these lines and try again', style: text.labelLarge?.copyWith(color: error)),
            for (final e in preview.errors) Text(e, style: TextStyle(color: error)),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: preview.canImport
                ? () async {
                    final work = ref.read(backupProvider).importCsv(preview);
                    await whileBusy(context, 'Importing transactions…', work);
                    if (context.mounted) Navigator.pop(context);
                  }
                : null,
            child: const Text('Import'),
          ),
        ),
      ),
    );
  }
}
