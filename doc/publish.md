# Build and publish

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

## Google Play

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

## Apple App Store (Mac needed)

One-time setup: join the Apple Developer Program ($99/year), create the app in App Store Connect with bundle id `com.nayanbiswas.wealthtracker`, and pick your paid team in Xcode with **Automatically manage signing** on.

Each release: raise `version`, pass `flutter analyze` and `flutter test`, run `flutter build ipa --release`, and upload `build/ios/ipa/*.ipa` with **Transporter** (or Xcode → **Distribute App**). Test in TestFlight, then submit. Privacy answer: "Data Not Collected". The Face ID prompt text is in `ios/Runner/Info.plist`.

## Before any public release

- Replace the default launcher icons (`android/app/src/main/res/mipmap-*`, `ios/Runner/Assets.xcassets/AppIcon.appiconset`).
- Set up a real Android signing key.
- Test restoring a backup made by the previous version.
- From then on, every schema change bumps `schemaVersion` and ships with a tested migration (see AGENTS.md, Data rules).
