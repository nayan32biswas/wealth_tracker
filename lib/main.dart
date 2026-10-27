import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/device_files.dart';
import 'data/device_security.dart';
import 'data/io/backup.dart';
import 'data/ledger_store.dart';
import 'domain/repositories/repositories.dart';
import 'domain/services/security.dart';
import 'presentation/app/app.dart';
import 'presentation/app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final path = p.join((await getApplicationDocumentsDirectory()).path, 'wealthtracker.sqlite');
  final store = LedgerStore(path, NativeDatabase.createInBackground);
  try {
    await store.open();
  } on Object catch (e) {
    return runApp(_StartupError('$e'));
  }
  // Cleanup must never stop the app from starting.
  DeviceFiles().clearExports().ignore();
  runApp(_LedgerHost(store, PinVault(KeychainSecretStore()), NativeScreenPrivacy()));
}

/// Rebuilds every provider after a restore swaps the database.
class _LedgerHost extends StatefulWidget {
  const _LedgerHost(this.store, this.vault, this.privacy);

  final LedgerStore store;
  final PinVault vault;
  final ScreenPrivacy privacy;

  @override
  State<_LedgerHost> createState() => _LedgerHostState();
}

class _LedgerHostState extends State<_LedgerHost> {
  Key _scope = UniqueKey();
  LockStart? _lockOnStart;

  @override
  void initState() {
    super.initState();
    _checkLock();
  }

  Future<void> _checkLock() async {
    final settings = await widget.store.repos.settings.get();
    final start = await LockStart.read(lockEnabled: settings.lockEnabled, vault: widget.vault);
    await widget.privacy.setSecure(start.locked);
    setState(() => _lockOnStart = start);
  }

  // Screens out of view keep paused listeners on the database, and closing it
  // waits for them. So the old screens are removed before the file is swapped.
  Future<void> _restore(String path) async {
    setState(() => _lockOnStart = null);
    await WidgetsBinding.instance.endOfFrame;
    try {
      await widget.store.restore(path);
    } finally {
      setState(() {
        _lockOnStart = LockStart.open;
        _scope = UniqueKey();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lockOnStart = _lockOnStart;
    if (lockOnStart == null) return const ColoredBox(color: Colors.black);
    final store = widget.store;
    return ProviderScope(
      key: _scope,
      overrides: [
        repositoriesProvider.overrideWithValue(store.repos),
        backupProvider.overrideWithValue(DriftBackupService(store.db, store.repos)),
        restorerProvider.overrideWithValue(_Restorer(store, _restore)),
        filesProvider.overrideWithValue(DeviceFiles()),
        pinVaultProvider.overrideWithValue(widget.vault),
        biometricsProvider.overrideWithValue(DeviceBiometrics()),
        screenPrivacyProvider.overrideWithValue(widget.privacy),
        lockOnStartProvider.overrideWithValue(lockOnStart),
      ],
      child: const WealthTrackerApp(),
    );
  }
}

class _Restorer implements DatabaseRestorer {
  _Restorer(this._store, this._restore);

  final LedgerStore _store;
  final Future<void> Function(String path) _restore;

  @override
  String? check(String path) => _store.check(path);

  @override
  Future<void> restore(String path) => _restore(path);
}

class _StartupError extends StatelessWidget {
  const _StartupError(this.details);

  final String details;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text('Wealth Tracker could not open your data', style: Theme.of(context).textTheme.titleLarge),
              const Text(
                'Your data file was not changed. Restart the app; if this keeps happening, keep your backup file safe.',
              ),
              Text(details, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    ),
  );
}
