import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/services/security.dart';
import '../../app/providers.dart';
import 'secret_input.dart';

class LockState {
  const LockState({required this.locked, required this.covered, required this.hasPin, this.kind});

  final bool locked;

  /// A blank cover over the app while it is in the background.
  final bool covered;
  final bool hasPin;

  /// Whether the lock asks for a PIN or a password; null until the keystore
  /// has been read.
  final SecretKind? kind;

  LockState copyWith({bool? locked, bool? covered, bool? hasPin, SecretKind? kind}) => LockState(
    locked: locked ?? this.locked,
    covered: covered ?? this.covered,
    hasPin: hasPin ?? this.hasPin,
    kind: kind ?? this.kind,
  );
}

final lockProvider = NotifierProvider<LockController, LockState>(LockController.new);

class LockController extends Notifier<LockState> {
  DateTime? _awaySince;

  // The biometric prompt itself sends the app to the background; that must
  // not count as leaving the app, or it would relock straight away.
  bool _authenticating = false;

  PinVault get _vault => ref.read(pinVaultProvider);

  @override
  LockState build() {
    final start = ref.read(lockOnStartProvider);
    _checkPin();
    return LockState(locked: start.locked, covered: false, hasPin: start.locked, kind: start.kind);
  }

  /// A lock setting restored from another phone has no PIN here, so it must
  /// never lock the user out.
  bool get isActive => state.hasPin && ref.read(settingsProvider).lockEnabled;

  // A keystore that fails to read leaves the state as it is: locked stays
  // locked.
  Future<void> _checkPin() async {
    try {
      final kind = await _vault.kind();
      state = state.copyWith(hasPin: kind != null, locked: state.locked && kind != null, kind: kind);
    } on SecretStoreException {
      return;
    }
  }

  DateTime get _now => ref.read(clockProvider)();

  /// A counted try that also opens the lock screen when right.
  Future<UnlockResult> unlock(String secret) async {
    final result = await check(secret);
    if (result.ok) {
      state = state.copyWith(locked: false);
      if (state.kind == null) await _checkPin();
    }
    return result;
  }

  /// A counted try for Settings, which must not open anything by itself.
  Future<UnlockResult> check(String secret) async {
    try {
      return await _vault.attempt(secret, _now);
    } on SecretStoreException {
      return const UnlockResult.unreadable();
    }
  }

  Future<void> unlockWithBiometrics() async {
    final settings = await ref.read(settingsStreamProvider.future);
    if (!settings.biometricEnabled || !state.locked) return;
    _authenticating = true;
    final ok = await ref.read(biometricsProvider).authenticate('Unlock Wealth Tracker');
    _authenticating = false;
    if (ok) {
      state = state.copyWith(locked: false);
      try {
        await _vault.forgetWrongTries();
      } on SecretStoreException {
        // The fingerprint already proved it is the owner.
      }
    }
  }

  void cover() {
    if (isActive && !_authenticating) state = state.copyWith(covered: true);
  }

  void away(DateTime now) {
    if (!_authenticating) _awaySince = now;
  }

  void back(DateTime now) {
    if (_authenticating) return;
    final timeout = ref.read(settingsProvider).lockTimeoutSeconds;
    final relock = isActive && shouldLockOnReturn(awaySince: _awaySince, now: now, timeoutSeconds: timeout);
    _awaySince = null;
    state = state.copyWith(covered: false, locked: state.locked || relock);
  }

  Future<void> enable(String secret, SecretKind kind) async {
    await _vault.setSecret(secret, kind);
    await _saveLock(enabled: true);
    state = state.copyWith(hasPin: true, kind: kind);
  }

  Future<void> change(String secret, SecretKind kind) async {
    await _vault.setSecret(secret, kind);
    state = state.copyWith(kind: kind);
  }

  /// Turns the lock off only when [secret] is right.
  Future<UnlockResult> disable(String secret) async {
    final result = await check(secret);
    if (!result.ok) return result;
    await _vault.clear();
    await _saveLock(enabled: false);
    state = state.copyWith(hasPin: false, locked: false);
    return result;
  }

  Future<void> _saveLock({required bool enabled}) async {
    final repo = ref.read(repositoriesProvider).settings;
    final current = await repo.get();
    await repo.save(current.copyWith(lockEnabled: enabled, biometricEnabled: enabled && current.biometricEnabled));
    await ref.read(screenPrivacyProvider).setSecure(enabled);
  }
}

/// Sits above every screen: shows the lock screen or the privacy cover.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final lock = ref.read(lockProvider.notifier);
    DateTime now() => ref.read(clockProvider)();
    _lifecycle = AppLifecycleListener(
      onInactive: lock.cover,
      onHide: () => lock.away(now()),
      onResume: () => lock.back(now()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lockProvider);
    return Stack(
      children: [
        // While locked, the screens behind must not keep the keyboard: typing
        // would go to them instead of the lock screen.
        ExcludeFocus(
          excluding: state.locked,
          child: ExcludeSemantics(excluding: state.locked, child: widget.child),
        ),
        if (state.covered)
          KeyedSubtree(
            key: const ValueKey('privacy-cover'),
            child: ColoredBox(color: Theme.of(context).colorScheme.surface, child: const SizedBox.expand()),
          ),
        if (state.locked && !state.covered) Overlay.wrap(child: const LockScreen()),
      ],
    );
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(lockProvider.notifier).unlockWithBiometrics());
  }

  @override
  Widget build(BuildContext context) {
    final biometric = ref.watch(settingsProvider).biometricEnabled;
    final kind = ref.watch(lockProvider.select((s) => s.kind));
    return Scaffold(
      body: SafeArea(
        child: SecretInput(
          kind: kind,
          title: 'Enter your ${secretName(kind)}',
          error: _error,
          submitLabel: 'Unlock',
          extraKey: biometric
              ? IconButton(
                  tooltip: 'Use fingerprint or Face ID',
                  icon: const Icon(Icons.fingerprint),
                  onPressed: ref.read(lockProvider.notifier).unlockWithBiometrics,
                )
              : null,
          onSubmit: (secret) async {
            final result = await ref.read(lockProvider.notifier).unlock(secret);
            if (mounted) setState(() => _error = wrongSecretMessage(result, kind, ref.read(clockProvider)()));
            return result.ok;
          },
        ),
      ),
    );
  }
}
