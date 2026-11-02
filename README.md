# WealthTracker

Personal finance app for Android and iOS: income, expenses, transfers, accounts, net worth, stats. All data stays on the device in SQLite. Backups are SQLite files (optionally password-protected) or CSV files, saved to Downloads or shared to another app.

- Install the tools (Flutter, Android SDK, emulator, VS Code): [doc/install.md](doc/install.md)
- Build, install on your own phone, publish to the stores: [doc/publish.md](doc/publish.md)
- Open a password-protected backup on a computer: [doc/backup.md](doc/backup.md)
- Rules for contributors and AI agents: [AGENTS.md](AGENTS.md)

| | |
|---|---|
| Bundle / application id | `com.nayanbiswas.wealthtracker` |
| Version | `version` in `pubspec.yaml` |
| Min OS | Android: Flutter default `minSdk` · iOS 15.0 |

## Run

First time, after each pull, and after changing a Drift table or query (`lib/data/`):

```
flutter pub get
tool/codegen.sh   # Drift codegen (build_runner, then dart format)
```

Then:

```
flutter emulators --launch WealthTracker_Pixel   # or plug in a phone
flutter run                                      # add -d <device> if several are connected
```

The first build takes 5–10 minutes. In `flutter run`: `r` hot reload, `R` restart, `q` quit.

To run from VS Code, see [doc/install.md](doc/install.md#vs-code).

### Without a running terminal

```bash
flutter build apk --debug
ADB="$HOME/Android/Sdk/platform-tools/adb.exe"   # on Ubuntu: ADB=adb
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk   # -r keeps app data
"$ADB" shell monkey -p com.nayanbiswas.wealthtracker -c android.intent.category.LAUNCHER 1
```

### Demo data

Debug builds only (release builds don't have the Developer section): Settings → Developer → **Load demo data** asks how many months of sample entries to add (1 or more, default 12). If there are transactions already, tick **Remove existing data first** to reset accounts and categories to the starter set before loading; otherwise the demo is added next to what's there. Settings are kept either way.

## Test

```
flutter analyze
flutter test                     # unit + widget, no device
flutter test integration_test    # on a phone/emulator, uses real storage
```
