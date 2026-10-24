import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/services/recurring.dart';
import '../features/accounts/accounts_screen.dart';
import '../features/security/app_lock.dart';
import '../features/settings/settings_screen.dart';
import '../features/stats/stats_screen.dart';
import '../features/transactions/transactions_screen.dart';
import 'providers.dart';
import 'theme.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final router = buildRouter();
  ref.onDispose(router.dispose);
  return router;
});

class WealthTrackerApp extends ConsumerStatefulWidget {
  const WealthTrackerApp({super.key});

  @override
  ConsumerState<WealthTrackerApp> createState() => _WealthTrackerAppState();
}

class _WealthTrackerAppState extends ConsumerState<WealthTrackerApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _runRecurring);
    _runRecurring();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _runRecurring() => applyDueRecurring(ref.read(repositoriesProvider).recurring, ref.read(clockProvider)());

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Wealth Tracker',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    routerConfig: ref.watch(routerProvider),
    builder: (context, child) => LockGate(child: child!),
  );
}

const _sections = [
  (path: '/transactions', label: 'Activity', icon: Icons.receipt_long_outlined, screen: TransactionsScreen()),
  (path: '/stats', label: 'Stats', icon: Icons.pie_chart_outline, screen: StatsScreen()),
  (path: '/accounts', label: 'Accounts', icon: Icons.account_balance_wallet_outlined, screen: AccountsScreen()),
  (path: '/settings', label: 'Settings', icon: Icons.settings_outlined, screen: SettingsScreen()),
];

/// Only the open tab is built, so switching tabs throws away the old tab and
/// any screen opened on it: every visit starts fresh.
GoRouter buildRouter() {
  final shellKey = GlobalKey<NavigatorState>();
  return GoRouter(
    initialLocation: '/transactions',
    routes: [
      ShellRoute(
        navigatorKey: shellKey,
        builder: (context, state, child) => _Shell(shellKey, state.uri.path, child),
        routes: [
          for (final s in _sections)
            GoRoute(
              path: s.path,
              pageBuilder: (_, state) => NoTransitionPage(key: state.pageKey, child: s.screen),
            ),
        ],
      ),
    ],
  );
}

class _Shell extends StatelessWidget {
  const _Shell(this.navigatorKey, this.location, this.child);

  final GlobalKey<NavigatorState> navigatorKey;
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final current = _sections.indexWhere((s) => s.path == location);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final close = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Close Wealth Tracker?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Close')),
            ],
          ),
        );
        if (close ?? false) await SystemNavigator.pop();
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: current,
          onDestinationSelected: (i) =>
              i == current ? navigatorKey.currentState?.popUntil((r) => r.isFirst) : context.go(_sections[i].path),
          destinations: [for (final s in _sections) NavigationDestination(icon: Icon(s.icon), label: s.label)],
        ),
      ),
    );
  }
}
