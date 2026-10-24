# WealthTracker

Personal finance app for Android and iOS: income, expenses, transfers, accounts, net worth, stats. All data stays on the device in SQLite. Backups are SQLite or CSV files you save yourself.

- Plan and status: [doc/build-plan.md](doc/build-plan.md)
- Rules for contributors and AI agents: [AGENTS.md](AGENTS.md)

| | |
|---|---|
| Bundle / application id | `com.nayanbiswas.wealthtracker` |
| Version | `version` in `pubspec.yaml` |
| Min OS | Android: Flutter default `minSdk` · iOS 15.0 |

## Install the tools

You need Flutter stable (Dart `^3.13`), Java 17, the Android SDK, and an emulator or a phone with USB debugging on. iPhone builds need a Mac with Xcode and CocoaPods. `flutter doctor` lists what's missing.

### Android Studio (Windows or Ubuntu)

1. Install [Android Studio](https://developer.android.com/studio) and open it once. The setup wizard installs the SDK.
2. In **Device Manager**, create a virtual phone (for example, Pixel on Android 15).
3. Run `flutter doctor --android-licenses`.

### Command-line tools: Windows

No Android Studio, no admin rights, about 3–5 GB.

1. Unzip Java 17 (for example, [Temurin](https://adoptium.net/temurin/releases/?version=17)) into `C:\Users\<you>\Android\jdk\`.
2. Unzip the [command-line tools](https://developer.android.com/studio#command-line-tools-only) so `sdkmanager.bat` is at `C:\Users\<you>\Android\Sdk\cmdline-tools\latest\bin\`.
3. In Git Bash:

   ```bash
   export JAVA_HOME="$HOME/Android/jdk/jdk-17.0.20.1+1"   # match the folder you unzipped
   export ANDROID_HOME="$HOME/Android/Sdk"
   S="$ANDROID_HOME/cmdline-tools/latest/bin"

   yes | "$S/sdkmanager.bat" --licenses
   "$S/sdkmanager.bat" --install "platform-tools" "emulator" "platforms;android-36" \
     "build-tools;36.0.0" "system-images;android-35;google_apis;x86_64"

   flutter config --android-sdk "$(cygpath -w "$ANDROID_HOME")" --jdk-dir "$(cygpath -w "$JAVA_HOME")"

   echo no | "$S/avdmanager.bat" create avd -n WealthTracker_Pixel \
     -k "system-images;android-35;google_apis;x86_64" -d pixel_7
   ```

`adb` is in `Android\Sdk\platform-tools\` and is not on your PATH.

### Command-line tools: Ubuntu 22.04+

There is no Linux desktop build. Run the app on an emulator or phone.

1. Install Java, Flutter and KVM (KVM makes the emulator fast enough to use):

   ```bash
   sudo apt update
   sudo apt install -y openjdk-17-jdk git curl unzip cpu-checker qemu-system-x86
   sudo snap install flutter --classic
   flutter --version            # first run downloads the Flutter SDK
   kvm-ok                       # expect "KVM acceleration can be used"
   sudo adduser "$USER" kvm
   ```

   Log out and back in. If `kvm-ok` fails, turn on VT-x / AMD-V in the BIOS.

2. Install the Android SDK and create the emulator:

   ```bash
   mkdir -p ~/Android/Sdk/cmdline-tools
   curl -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
   unzip -q /tmp/cmdline-tools.zip -d ~/Android/Sdk/cmdline-tools
   mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
   rm /tmp/cmdline-tools.zip

   cat >> ~/.bashrc <<'EOF'

   # Android SDK, Java 17, Flutter
   export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
   export ANDROID_HOME="$HOME/Android/Sdk"
   export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
   export PATH="$PATH:$HOME/snap/flutter/common/flutter/bin"   # `dart` from the Flutter snap
   EOF
   source ~/.bashrc

   yes | sdkmanager --licenses
   sdkmanager --install "platform-tools" "emulator" "platforms;android-36" \
     "build-tools;36.0.0" "system-images;android-36;google_apis;x86_64"

   echo no | avdmanager create avd -n WealthTracker_Pixel \
     -k "system-images;android-36;google_apis;x86_64" -d pixel_7
   ```

3. Point Flutter at the SDK and Java, then check:

   ```bash
   flutter config --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
   flutter doctor --android-licenses
   flutter doctor               # ignore the Linux toolchain and Chrome warnings
   dart --version
   ```

Real phone: if `adb devices` shows `no permissions`, run `sudo apt install -y android-sdk-platform-tools-common`, replug, and tap **Allow** on the phone.

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

### VS Code

1. Install the Flutter extension: `code --install-extension Dart-Code.flutter` (on Ubuntu, VS Code itself: `sudo snap install code --classic`).
2. Open the `WealthTracker` folder.
3. Pick the device in the bottom status bar (or `Ctrl+Shift+P` → **Flutter: Select Device**). Picking `WealthTracker_Pixel` starts the emulator.
4. Press `F5`. It uses `.vscode/launch.json`, so any file can be open.

Saving a Dart file hot-reloads. `Ctrl+Shift+F5` restarts, `Shift+F5` stops.

- **Select debugger** popup: the Flutter extension is missing or disabled.
- Asked for the Flutter SDK on Ubuntu: pick `~/snap/flutter/common/flutter`.
- To regenerate Drift code on save, run `dart run build_runner watch --delete-conflicting-outputs` in a terminal, then `dart format lib/data/db/app_database.g.dart` (the generator writes 80-column code; the project uses 120).

### Without a running terminal

```bash
flutter build apk --debug
ADB="$HOME/Android/Sdk/platform-tools/adb.exe"   # on Ubuntu: ADB=adb
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk   # -r keeps app data
"$ADB" shell monkey -p com.nayanbiswas.wealthtracker -c android.intent.category.LAUNCHER 1
```

### Demo data

Debug builds only (release builds don't have the Developer section): Settings → Developer → **Load demo data** asks how many months of sample entries to add (1–24, default 12). If there are transactions already, tick **Remove existing data first** to reset accounts and categories to the starter set before loading; otherwise the demo is added next to what's there. Settings are kept either way.

## Test

```
flutter analyze
flutter test                     # unit + widget, no device
flutter test integration_test    # on a phone/emulator, uses real storage
```

## Build

Release builds hide the Developer tools.

| Target | Command | Output |
|---|---|---|
| Android APK | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| APK per CPU type | `flutter build apk --release --split-per-abi` | `build/app/outputs/flutter-apk/app-*-release.apk` |
| Google Play bundle | `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |
| iOS (Mac only) | `flutter build ipa --release` | `build/ios/ipa/` |

**Version:** in `1.0.1+2`, `1.0.1` is the visible version and `+2` the build number. Raise the build number on every store upload.

**Signing:** release builds use the debug key for now (`android/app/build.gradle.kts`). Fine for your own phone. Google Play needs a real key, see [Google Play](#google-play).

## Install on your own phone

Data lives only on the phone. **Uninstalling deletes it.** Export a backup (Settings → Backup) before you uninstall or switch to a build signed with another key. A password on the backup is optional. Any phone with the app can open it with that password, but a forgotten password can't be recovered.

**Android:** plug in the phone and run `flutter build apk --release` then `flutter install --release`, or copy `app-release.apk` to the phone and open it. Updates must use the same signing key.

**iPhone (Mac needed):**

1. Open `ios/Runner.xcworkspace` in Xcode. Under **Runner → Signing & Capabilities**, pick your Apple ID as Team. Change the bundle id if it is taken.
2. On the iPhone, turn on **Developer Mode** (Settings → Privacy & Security).
3. Run `flutter run --release`.
4. First time: trust the developer profile (Settings → General → VPN & Device Management).

A free Apple ID install stops working after 7 days; reinstall from the Mac (data is kept). A paid account ($99/year) lasts a year.

## Open a backup on a computer

A password-protected backup (`.wtbackup`) can be turned back into a plain SQLite file, opened or edited in any SQLite tool, then protected again and restored on the phone. Run this in Git Bash or a Linux shell, after `flutter pub get`:

```bash
tool/backup_crypt.sh decrypt wealthtracker-2026-10-01.wtbackup   # -> wealthtracker-2026-10-01.sqlite
tool/backup_crypt.sh encrypt wealthtracker-2026-10-01.sqlite     # -> wealthtracker-2026-10-01.wtbackup
```

The password is asked for on screen. `-o <file>` picks another output name, and `--force` replaces an existing file. The script uses the app's own encryption code, so the files open on any phone with the app. A restore only accepts the app's exact tables and columns, so edit rows, not the table layout.

The decrypted `.sqlite` file is not protected. Delete it when you're done.

## Publish

### Google Play

One-time setup:

1. Create a Play Console account ($25, one time).
2. Create an upload key. Back it up and never commit it:

   ```
   keytool -genkey -v -keystore ~/wealthtracker-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

3. Create `android/key.properties` (git ignores it):

   ```
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=C:/Users/<you>/wealthtracker-upload.jks
   ```

   On Ubuntu: `storeFile=/home/<you>/wealthtracker-upload.jks`.

4. In `android/app/build.gradle.kts`, use that key for release builds:

   ```kotlin
   import java.util.Properties
   import java.io.FileInputStream

   val keystoreProperties = Properties().apply {
       val file = rootProject.file("key.properties")
       if (file.exists()) load(FileInputStream(file))
   }

   android {
       signingConfigs {
           create("release") {
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
           }
       }
       buildTypes {
           release {
               signingConfig = signingConfigs.getByName("release")
           }
       }
   }
   ```

5. Accept **Play App Signing** when offered, so a lost upload key can be reset.

Each release: raise `version`, pass `flutter analyze` and `flutter test`, run `flutter build appbundle --release`, and upload `app-release.aab` (Internal testing first, then Production). Data safety form: the app collects and sends nothing.

### Apple App Store (Mac needed)

One-time setup: join the Apple Developer Program ($99/year), create the app in App Store Connect with bundle id `com.nayanbiswas.wealthtracker`, and pick your paid team in Xcode with **Automatically manage signing** on.

Each release: raise `version`, pass `flutter analyze` and `flutter test`, run `flutter build ipa --release`, and upload `build/ios/ipa/*.ipa` with **Transporter** (or Xcode → **Distribute App**). Test in TestFlight, then submit. Privacy answer: "Data Not Collected". The Face ID prompt text is in `ios/Runner/Info.plist`.

### Before any public release

- Replace the default launcher icons (`android/app/src/main/res/mipmap-*`, `ios/Runner/Assets.xcassets/AppIcon.appiconset`).
- Set up a real Android signing key.
- Test restoring a backup made by the previous version.
