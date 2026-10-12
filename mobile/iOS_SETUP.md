# Running the Cafe app on iOS

The Dart code in `lib/` is already cross-platform. You only need to add the iOS
platform folder and two iOS-specific settings. **A Mac with Xcode is required** —
iOS apps cannot be built on Windows/Linux.

## 1. One-time tooling (on the Mac)

```bash
# Xcode from the App Store, then:
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
brew install cocoapods         # or: sudo gem install cocoapods
flutter doctor                 # should show a tick for Xcode
```

## 2. Generate the iOS project

Your project currently has only `lib/` + `pubspec.yaml`. This command adds the
`ios/` (and `android/`) folders **without touching your `lib/` code**:

```bash
cd mobile
flutter create .
flutter pub get
```

## 3. Allow local HTTP (important)

iOS blocks plain `http://` by default (App Transport Security). Your dev backend
is `http://localhost:9999`, so add an exception. Open
`ios/Runner/Info.plist` and add this inside the top-level `<dict>`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

`NSAllowsLocalNetworking` covers `localhost` and your LAN, which is all you need
for development. In production you'd serve the API over HTTPS and remove this.

## 4. Run

**iOS Simulator** (easiest — uses `localhost` automatically):

```bash
open -a Simulator
flutter run              # config.dart already targets http://localhost:9999 on iOS
```

**Physical iPhone** (needs your Mac's LAN IP, since the phone can't see the Mac's
localhost):

```bash
ipconfig getifaddr en0   # e.g. 192.168.1.50
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:9999
```

Your Mac and iPhone must be on the same Wi-Fi, and the backend must bind to all
interfaces — it already does (`app.run(host="0.0.0.0", ...)` in `run.py`).

## 5. Signing (physical device only)

```bash
open ios/Runner.xcworkspace
```

In Xcode → Runner target → **Signing & Capabilities** → pick your Team (a free
Apple ID works for on-device testing). Set a unique Bundle Identifier if the
default is taken, then Run from Xcode or `flutter run`.

## Notes specific to this app

- **flutter_secure_storage** (admin token) uses the iOS Keychain automatically —
  no extra setup for dev.
- **cached_network_image** and **fl_chart** are pure Dart/Flutter — no iOS config.
- Minimum iOS: Flutter defaults to iOS 12+, which is fine for all these packages.
- To ship to the App Store later you'd use `flutter build ipa` and upload via
  Xcode/Transporter, plus a paid Apple Developer account ($99/yr).
