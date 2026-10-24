/// The app relocks after being away this long at most.
const maxLockTimeoutSeconds = 60;

class AppSettings {
  const AppSettings({
    this.currencySymbol = '৳',
    this.currencyCode = 'BDT',
    this.decimals = 2,
    this.weekStart = DateTime.saturday,
    this.monthStartDay = 1,
    this.lockEnabled = false,
    this.biometricEnabled = false,
    this.lockTimeoutSeconds = 10,
  });

  factory AppSettings.fromMap(Map<String, String> map) {
    const d = AppSettings();
    int intOf(String key, int fallback) => int.tryParse(map[key] ?? '') ?? fallback;
    bool boolOf(String key, bool fallback) => map[key] == null ? fallback : map[key] == 'true';
    return AppSettings(
      currencySymbol: map['currency_symbol'] ?? d.currencySymbol,
      currencyCode: map['currency_code'] ?? d.currencyCode,
      decimals: intOf('decimals', d.decimals),
      weekStart: intOf('week_start', d.weekStart),
      monthStartDay: intOf('month_start_day', d.monthStartDay),
      lockEnabled: boolOf('lock_enabled', d.lockEnabled),
      biometricEnabled: boolOf('biometric_enabled', d.biometricEnabled),
      lockTimeoutSeconds: intOf('lock_timeout_seconds', d.lockTimeoutSeconds).clamp(0, maxLockTimeoutSeconds),
    );
  }

  final String currencySymbol;
  final String currencyCode;
  final int decimals;

  /// Uses [DateTime.monday]..[DateTime.sunday].
  final int weekStart;

  /// Day of month (1–28) on which a "month" period begins.
  final int monthStartDay;
  final bool lockEnabled;
  final bool biometricEnabled;

  /// How long the app may be away (another app, home screen, screen off)
  /// before it asks for the PIN again. Closing the app always locks it.
  final int lockTimeoutSeconds;

  AppSettings copyWith({
    String? currencySymbol,
    String? currencyCode,
    int? decimals,
    int? weekStart,
    int? monthStartDay,
    bool? lockEnabled,
    bool? biometricEnabled,
    int? lockTimeoutSeconds,
  }) => AppSettings(
    currencySymbol: currencySymbol ?? this.currencySymbol,
    currencyCode: currencyCode ?? this.currencyCode,
    decimals: decimals ?? this.decimals,
    weekStart: weekStart ?? this.weekStart,
    monthStartDay: monthStartDay ?? this.monthStartDay,
    lockEnabled: lockEnabled ?? this.lockEnabled,
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    lockTimeoutSeconds: lockTimeoutSeconds ?? this.lockTimeoutSeconds,
  );

  Map<String, String> toMap() => {
    'currency_symbol': currencySymbol,
    'currency_code': currencyCode,
    'decimals': '$decimals',
    'week_start': '$weekStart',
    'month_start_day': '$monthStartDay',
    'lock_enabled': '$lockEnabled',
    'biometric_enabled': '$biometricEnabled',
    'lock_timeout_seconds': '$lockTimeoutSeconds',
  };
}
