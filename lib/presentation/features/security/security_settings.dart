import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/app_settings.dart';
import '../../../domain/services/security.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';
import 'app_lock.dart';
import 'secret_input.dart';

String _lockAfterLabel(int seconds) => seconds == 0 ? 'Immediately' : 'After $seconds seconds';

/// The Security rows shown in Settings.
class SecuritySettings extends ConsumerWidget {
  const SecuritySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(lockProvider).kind;
    final lock = ref.read(lockProvider.notifier);
    final current = 'Enter your current ${secretName(kind)}';
    final settings = ref.watch(settingsProvider);
    final active = lock.isActive;
    final repo = ref.read(repositoriesProvider).settings;
    void tell(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

    return SettingsSection(
      title: 'Security',
      children: [
        SwitchListTile(
          title: const Text('App lock'),
          subtitle: Text(
            active
                ? 'Asks for your ${secretName(kind)} when the app opens'
                : 'Ask for a PIN or password. Fingerprint or Face ID can be added after.',
          ),
          value: active,
          onChanged: (on) async {
            if (on) {
              final chosen = await _newSecret(context);
              if (chosen != null) await lock.enable(chosen.secret, chosen.kind);
            } else {
              await _checkSecret(context, current, kind, lock.disable);
            }
          },
        ),
        if (active) ...[
          ListTile(
            title: const Text('Change PIN or password'),
            onTap: () async {
              final right = await _checkSecret(context, current, kind, lock.check);
              if (!right || !context.mounted) return;
              final chosen = await _newSecret(context);
              if (chosen != null) await lock.change(chosen.secret, chosen.kind);
            },
          ),
          SwitchListTile(
            title: const Text('Use fingerprint or Face ID'),
            subtitle: const Text("Uses the fingerprint or face saved in your phone's settings"),
            value: settings.biometricEnabled,
            onChanged: (on) async {
              final biometrics = ref.read(biometricsProvider);
              if (on && !await biometrics.isAvailable()) {
                tell("Add a fingerprint or face in your phone's settings first, then turn this on");
                return;
              }
              if (on && !await biometrics.authenticate('Confirm to turn on')) return;
              await repo.save(settings.copyWith(biometricEnabled: on));
            },
          ),
          ListTile(
            title: const Text('Lock after'),
            subtitle: Text(_lockAfterLabel(settings.lockTimeoutSeconds)),
            onTap: () async {
              final result = await showDialog<EditResult<int>>(
                context: context,
                builder: (_) => _LockAfterDialog(settings.lockTimeoutSeconds),
              );
              if (result case (DialogAction.save, final seconds?)) {
                await repo.save(settings.copyWith(lockTimeoutSeconds: seconds));
              }
            },
          ),
        ],
      ],
    );
  }

  /// Asks for a new PIN or password twice. Returns it once both entries match.
  static Future<({String secret, SecretKind kind})?> _newSecret(BuildContext context) =>
      Navigator.push<({String secret, SecretKind kind})>(
        context,
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _NewSecretScreen()),
      );

  /// Returns true once [check] accepts the entered PIN or password.
  static Future<bool> _checkSecret(
    BuildContext context,
    String title,
    SecretKind? kind,
    Future<UnlockResult> Function(String) check,
  ) async =>
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CheckSecretScreen(title, kind, check)),
      ) ??
      false;
}

class _NewSecretScreen extends StatefulWidget {
  const _NewSecretScreen();

  @override
  State<_NewSecretScreen> createState() => _NewSecretScreenState();
}

class _NewSecretScreenState extends State<_NewSecretScreen> {
  SecretKind _kind = SecretKind.pin;
  String? _first;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final pin = _kind == SecretKind.pin;
    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _kind = pin ? SecretKind.password : SecretKind.pin;
              _first = null;
              _error = null;
            }),
            child: Text(pin ? 'Use a password' : 'Use a PIN'),
          ),
        ],
      ),
      body: SecretInput(
        key: ValueKey((_kind, _first)),
        kind: _kind,
        title: _first != null
            ? 'Enter it again'
            : pin
            ? 'Choose a PIN'
            : 'Choose a password',
        hint: pin ? '4 to 8 digits' : 'At least $minPasswordLength characters of any kind',
        error: _error,
        onSubmit: (secret) async {
          if (_first == null) {
            setState(() {
              _first = secret;
              _error = null;
            });
          } else if (secret == _first) {
            Navigator.pop(context, (secret: secret, kind: _kind));
          } else {
            setState(() {
              _first = null;
              _error = "They didn't match. Try again.";
            });
          }
          return true;
        },
      ),
    );
  }
}

class _CheckSecretScreen extends ConsumerStatefulWidget {
  const _CheckSecretScreen(this.title, this.kind, this.check);

  final String title;
  final SecretKind? kind;
  final Future<UnlockResult> Function(String) check;

  @override
  ConsumerState<_CheckSecretScreen> createState() => _CheckSecretScreenState();
}

class _CheckSecretScreenState extends ConsumerState<_CheckSecretScreen> {
  String? _error;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: SecretInput(
      kind: widget.kind,
      title: widget.title,
      error: _error,
      onSubmit: (secret) async {
        final result = await widget.check(secret);
        if (!context.mounted) return result.ok;
        if (result.ok) {
          Navigator.pop(context, true);
        } else {
          setState(() => _error = wrongSecretMessage(result, widget.kind, ref.read(clockProvider)()));
        }
        return result.ok;
      },
    ),
  );
}

class _LockAfterDialog extends StatefulWidget {
  const _LockAfterDialog(this.initial);

  final int initial;

  @override
  State<_LockAfterDialog> createState() => _LockAfterDialogState();
}

class _LockAfterDialogState extends State<_LockAfterDialog> {
  late var _seconds = widget.initial;

  @override
  Widget build(BuildContext context) => EditDialog<int>(
    title: 'Lock after',
    value: () => _seconds,
    children: [
      const Text(
        'How long you can be in another app before you need to unlock again. Closing the app always locks it.',
      ),
      Text(_lockAfterLabel(_seconds), style: Theme.of(context).textTheme.titleMedium),
      Slider(
        value: _seconds.toDouble(),
        max: maxLockTimeoutSeconds.toDouble(),
        divisions: maxLockTimeoutSeconds ~/ 5,
        label: '$_seconds s',
        onChanged: (v) => setState(() => _seconds = v.round()),
      ),
    ],
  );
}
