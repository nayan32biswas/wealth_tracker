# Install the tools

You need Flutter stable (Dart `^3.13`), Java 17, the Android SDK, and an emulator or a phone with USB debugging on. iPhone builds need a Mac with Xcode and CocoaPods. `flutter doctor` lists what's missing.

## Android Studio (Windows or Ubuntu)

1. Install [Android Studio](https://developer.android.com/studio) and open it once. The setup wizard installs the SDK.
2. In **Device Manager**, create a virtual phone (for example, Pixel on Android 16).
3. Run `flutter doctor --android-licenses`.

## Command-line tools: Windows

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
     "build-tools;36.0.0" "system-images;android-36;google_apis;x86_64"

   flutter config --android-sdk "$(cygpath -w "$ANDROID_HOME")" --jdk-dir "$(cygpath -w "$JAVA_HOME")"

   echo no | "$S/avdmanager.bat" create avd -n WealthTracker_Pixel \
     -k "system-images;android-36;google_apis;x86_64" -d pixel_7
   ```

`adb` is in `Android\Sdk\platform-tools\` and is not on your PATH.

## Command-line tools: Ubuntu 22.04+

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

## VS Code

1. Install the Flutter extension: `code --install-extension Dart-Code.flutter` (on Ubuntu, VS Code itself: `sudo snap install code --classic`).
2. Open the `WealthTracker` folder.
3. Pick the device in the bottom status bar (or `Ctrl+Shift+P` → **Flutter: Select Device**). Picking `WealthTracker_Pixel` starts the emulator.
4. Press `F5`. It uses `.vscode/launch.json`, so any file can be open.

Saving a Dart file hot-reloads. `Ctrl+Shift+F5` restarts, `Shift+F5` stops.

- **Select debugger** popup: the Flutter extension is missing or disabled.
- Asked for the Flutter SDK on Ubuntu: pick `~/snap/flutter/common/flutter`.
- To regenerate Drift code on save, run `dart run build_runner watch --delete-conflicting-outputs` in a terminal, then `dart format lib/data/db/app_database.g.dart` (the generator writes 80-column code; the project uses 120).
