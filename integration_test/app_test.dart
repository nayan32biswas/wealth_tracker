import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wealthtracker/main.dart' as app;

/// Smoke test on a real device or emulator: `flutter test integration_test`.
/// Uses the real database, keychain and plugins, so run it on a test device
/// or a fresh install, not on a phone holding your real data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app starts and every tab opens', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    expect(find.byTooltip('Add transaction'), findsOneWidget);

    for (final tab in ['Stats', 'Accounts', 'Settings', 'Activity']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
    }

    expect(find.byTooltip('Add transaction'), findsOneWidget);
  });
}
