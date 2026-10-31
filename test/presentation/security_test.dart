import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/services/security.dart';
import 'package:wealthtracker/presentation/features/security/app_lock.dart';
import 'package:wealthtracker/presentation/features/security/secret_input.dart';

import 'harness.dart';

Future<void> lockEnabled(DriftRepositories repos) async =>
    repos.settings.save((await repos.settings.get()).copyWith(lockEnabled: true, lockTimeoutSeconds: 60));

Future<void> pin1234(PinVault vault) => vault.setPin('1234');

Future<void> goAway(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  await tester.pump();
}

Future<void> comeBack(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

/// Whether typing goes into a text field, and whether that is the lock
/// screen's own.
(bool, bool) typingGoesTo() {
  final focused = FocusManager.instance.primaryFocus?.context;
  final field = focused?.findAncestorWidgetOfExactType<EditableText>() != null;
  return (field, field && focused!.findAncestorWidgetOfExactType<LockScreen>() != null);
}

bool lockFieldHasFocus(WidgetTester tester) => typingGoesTo() == (true, true);

void main() {
  group('turning the lock on and off', () {
    testWidgets('app lock asks for a new PIN twice and stores it', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'App lock');

      await typePin(tester, '1234');
      await typePin(tester, '1234');

      expect(await tester.runAsync(() => app.vault.verify('1234')), isTrue);
      expect((await tester.runAsync(app.repos.settings.get))!.lockEnabled, isTrue);
      expect(app.privacy.secure, isTrue);
      expect(find.text('Change PIN or password'), findsOneWidget);
    });

    testWidgets('on a short screen the PIN screen covers the tabs and its button stays above the system bar', (
      tester,
    ) async {
      final app = await pumpApp(tester);
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      // Android's own navigation bar at the bottom.
      tester.view.padding = const FakeViewPadding(bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      await tester.pumpAndSettle();
      await openTab(tester, 'Settings');
      await tester.scrollUntilVisible(find.text('App lock'), 200, scrollable: find.byType(Scrollable).first);
      await tapAndSettle(tester, find.text('App lock'));

      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationBar), findsNothing);
      for (var i = 0; i < 2; i++) {
        for (final digit in '1234'.split('')) {
          await tester.tap(find.descendant(of: find.byType(PinPad), matching: find.text(digit)));
          await tester.pump();
        }
        await tester.ensureVisible(find.text('OK'));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('OK')).bottom, lessThanOrEqualTo(560 - 48));
        await tapAndSettle(tester, find.text('OK'));
      }

      expect(await tester.runAsync(() => app.vault.verify('1234')), isTrue);
    });

    testWidgets('the lock screen fits a short landscape screen', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234, lockOnStart: true);
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Unlock'));
      await tester.pumpAndSettle();
      await typePin(tester, '1234', submit: 'Unlock');
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('a password can be chosen instead of a PIN', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'App lock');
      await tapAndSettle(tester, find.text('Use a password'));

      expect(find.text('At least 4 characters of any kind'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await tester.enterText(find.widgetWithText(TextField, 'Password'), 'my secret');
        await tapAndSettle(tester, find.text('OK'));
      }

      expect(await tester.runAsync(app.vault.kind), SecretKind.password);
      expect(await tester.runAsync(() => app.vault.verify('my secret')), isTrue);
      expect(find.text('Asks for your password when the app opens'), findsOneWidget);
    });

    testWidgets('settings say fingerprint or Face ID comes from the phone', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      await openTab(tester, 'Settings');

      final hint = find.text("Uses the fingerprint or face saved in your phone's settings");
      await tester.scrollUntilVisible(hint, 200, scrollable: find.byType(Scrollable).first);

      expect(hint, findsOneWidget);
    });

    testWidgets('mismatched PINs are not saved', (tester) async {
      final app = await pumpApp(tester);
      await openSettingsItem(tester, 'App lock');

      await typePin(tester, '1234');
      await typePin(tester, '9999');

      expect(find.text("They didn't match. Try again."), findsOneWidget);
      expect(await tester.runAsync(app.vault.hasPin), isFalse);
    });

    testWidgets('turning the lock off needs the current PIN', (tester) async {
      final app = await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      await openSettingsItem(tester, 'App lock');

      await typePin(tester, '1234');

      expect(await tester.runAsync(app.vault.hasPin), isFalse);
      expect((await tester.runAsync(app.repos.settings.get))!.lockEnabled, isFalse);
      expect(app.privacy.secure, isFalse);
    });

    testWidgets('fingerprint can be turned on when the phone supports it', (tester) async {
      final app = await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      await openTab(tester, 'Settings');

      await tapAndSettle(tester, find.text('Use fingerprint or Face ID'));

      expect((await tester.runAsync(app.repos.settings.get))!.biometricEnabled, isTrue);
    });

    testWidgets('lock after can be set anywhere from immediately to 60 seconds', (tester) async {
      final app = await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      await openSettingsItem(tester, 'Lock after');
      expect(find.text('After 60 seconds'), findsWidgets);

      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Immediately')), findsOneWidget);
      await tapAndSettle(tester, find.text('Save'));

      expect((await tester.runAsync(app.repos.settings.get))!.lockTimeoutSeconds, 0);
      expect(find.text('Immediately'), findsOneWidget);
    });

    testWidgets('cancelling lock after keeps the old time', (tester) async {
      final app = await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      await openSettingsItem(tester, 'Lock after');

      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      await tapAndSettle(tester, find.text('Cancel'));

      expect((await tester.runAsync(app.repos.settings.get))!.lockTimeoutSeconds, 60);
    });
  });

  group('lock screen', () {
    testWidgets('app starts locked and the right PIN opens it', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234, lockOnStart: true);

      expect(find.text('Enter your PIN'), findsOneWidget);
      await typePin(tester, '1234', submit: 'Unlock');

      expect(find.byType(LockScreen), findsNothing);
      expect(find.byTooltip('Add transaction'), findsOneWidget);
    });

    testWidgets('a wrong PIN keeps it locked', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234, lockOnStart: true);

      await typePin(tester, '0000', submit: 'Unlock');

      expect(find.text('Wrong PIN'), findsOneWidget);
      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('5 wrong PINs make the user wait 5 minutes, even for the right PIN', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234, lockOnStart: true);

      for (var i = 0; i < 4; i++) {
        await typePin(tester, '0000', submit: 'Unlock');
      }
      expect(find.text('Wrong PIN. 1 try left before a wait.'), findsOneWidget);
      await typePin(tester, '0000', submit: 'Unlock');
      expect(find.text('Too many wrong tries. Try again in 5 minutes.'), findsOneWidget);

      testClock = () => testToday.add(const Duration(minutes: 3));
      await typePin(tester, '1234', submit: 'Unlock');
      expect(find.text('Too many wrong tries. Try again in 2 minutes.'), findsOneWidget);
      expect(find.byType(LockScreen), findsOneWidget);

      testClock = () => testToday.add(const Duration(minutes: 5));
      await typePin(tester, '1234', submit: 'Unlock');
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('a password lock asks for the password on the keyboard', (tester) async {
      await pumpApp(
        tester,
        arrange: lockEnabled,
        arrangeVault: (vault) => vault.setSecret('open sesame', SecretKind.password),
        lockOnStart: true,
      );

      expect(find.text('Enter your password'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'open sesame');
      await tapAndSettle(tester, find.text('Unlock'));

      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('the password field is ready to type into when the app opens', (tester) async {
      await pumpApp(
        tester,
        arrange: lockEnabled,
        arrangeVault: (vault) => vault.setSecret('open sesame', SecretKind.password),
        lockOnStart: true,
      );

      expect(lockFieldHasFocus(tester), isTrue);
    });

    testWidgets('the typed password can be shown and hidden again', (tester) async {
      await pumpApp(
        tester,
        arrange: lockEnabled,
        arrangeVault: (vault) => vault.setSecret('open sesame', SecretKind.password),
        lockOnStart: true,
      );
      bool hidden() => tester.widget<EditableText>(find.byType(EditableText)).obscureText;
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'open sesame');
      expect(hidden(), isTrue);

      await tapAndSettle(tester, find.byTooltip('Show password'));
      expect(hidden(), isFalse);
      expect(lockFieldHasFocus(tester), isTrue);

      await tapAndSettle(tester, find.byTooltip('Hide password'));
      expect(hidden(), isTrue);
    });

    testWidgets('a relock takes the keyboard away from the screen behind it', (tester) async {
      await pumpApp(
        tester,
        arrange: lockEnabled,
        arrangeVault: (vault) => vault.setSecret('open sesame', SecretKind.password),
      );
      await tapAndSettle(tester, find.byTooltip('Search'));
      expect(typingGoesTo(), (true, false));

      await goAway(tester);
      testClock = () => testToday.add(const Duration(minutes: 2));
      await comeBack(tester);

      expect(lockFieldHasFocus(tester), isTrue);
    });

    testWidgets('a keystore that cannot be read keeps the app locked until it can', (tester) async {
      final secrets = MemorySecretStore();
      await pumpApp(
        tester,
        arrange: lockEnabled,
        arrangeVault: (vault) async {
          await vault.setSecret('open sesame', SecretKind.password);
          secrets.broken = true;
        },
        secrets: secrets,
        lockOnStart: true,
      );

      expect(find.text('Enter your PIN or password'), findsOneWidget);
      expect(lockFieldHasFocus(tester), isTrue);
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'open sesame');
      await tapAndSettle(tester, find.text('Unlock'));
      expect(find.text("Couldn't check your PIN or password just now. Try again."), findsOneWidget);
      expect(find.byType(LockScreen), findsOneWidget);

      secrets.broken = false;
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'open sesame');
      await tapAndSettle(tester, find.text('Unlock'));
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('fingerprint unlocks when turned on', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async {
          await lockEnabled(repos);
          await repos.settings.save((await repos.settings.get()).copyWith(biometricEnabled: true));
        },
        arrangeVault: pin1234,
        lockOnStart: true,
      );

      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('a failed fingerprint falls back to the PIN', (tester) async {
      await pumpApp(
        tester,
        arrange: (repos) async {
          await lockEnabled(repos);
          await repos.settings.save((await repos.settings.get()).copyWith(biometricEnabled: true));
        },
        arrangeVault: pin1234,
        lockOnStart: true,
        biometricSucceeds: false,
      );
      await tapAndSettle(tester, find.byTooltip('Use fingerprint or Face ID'));

      expect(find.byType(LockScreen), findsOneWidget);
      await typePin(tester, '1234', submit: 'Unlock');
      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('content is covered while the app is in the background', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);

      await goAway(tester);

      expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
    });

    testWidgets('coming back after the timeout locks the app', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);

      await goAway(tester);
      testClock = () => testToday.add(const Duration(minutes: 2));
      await comeBack(tester);

      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('coming back quickly does not lock', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);

      await goAway(tester);
      testClock = () => testToday.add(const Duration(seconds: 10));
      await comeBack(tester);

      expect(find.byType(LockScreen), findsNothing);
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
    });

    testWidgets('closing the app with back locks it on return, even within the timeout', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);

      await tester.binding.handlePopRoute();
      await goAway(tester);
      testClock = () => testToday.add(const Duration(seconds: 1));
      await comeBack(tester);

      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('after unlocking, a quick trip away does not lock again', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, arrangeVault: pin1234);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      await tester.binding.handlePopRoute();
      await goAway(tester);
      await comeBack(tester);
      await typePin(tester, '1234', submit: 'Unlock');

      await goAway(tester);
      testClock = () => testToday.add(const Duration(seconds: 1));
      await comeBack(tester);

      expect(find.byType(LockScreen), findsNothing);
    });

    testWidgets('a chosen lock after time decides when coming back locks', (tester) async {
      Future<void> after20s(DriftRepositories repos) async =>
          repos.settings.save((await repos.settings.get()).copyWith(lockEnabled: true, lockTimeoutSeconds: 20));
      await pumpApp(tester, arrange: after20s, arrangeVault: pin1234);

      await goAway(tester);
      testClock = () => testToday.add(const Duration(seconds: 19));
      await comeBack(tester);
      expect(find.byType(LockScreen), findsNothing);

      await goAway(tester);
      testClock = () => testToday.add(const Duration(seconds: 40));
      await comeBack(tester);
      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('lock after set to immediately locks on every return', (tester) async {
      Future<void> immediately(DriftRepositories repos) async =>
          repos.settings.save((await repos.settings.get()).copyWith(lockEnabled: true, lockTimeoutSeconds: 0));
      await pumpApp(tester, arrange: immediately, arrangeVault: pin1234);

      await goAway(tester);
      await comeBack(tester);

      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('a lock setting without a PIN on this phone never locks you out', (tester) async {
      await pumpApp(tester, arrange: lockEnabled, lockOnStart: true);

      expect(find.byType(LockScreen), findsNothing);
    });
  });
}
