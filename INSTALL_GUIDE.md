# Installation & Setup Guide — good_sleep_test

## FlutterFlow Custom Package

```yaml
good_sleep_test:
  git:
    url: https://github.com/VirtuousTechlogicMobile/good_sleep_test.git
```

Also add if not already present: `path_provider`, `permission_handler`.

In Custom Code:

```dart
import 'package:good_sleep_test/good_sleep_test.dart';
```

Upload files with existing Resdent multipart API (`UploadSleepTestFileCall`).

## Android

Plugin merges BLE/location permissions. Host still needs FlutterFlow permission
prompts enabled for Bluetooth + Location.

`minSdk` ≥ 23.

Overnight FGS stays in host custom code (same as snore).

## iOS

Add usage strings in FlutterFlow / Info.plist:

- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `NSLocationWhenInUseUsageDescription`

Optional background: `bluetooth-central`.

The plugin vendors `libContecBluetoothSDK.a`. Build on a **real device**
(simulator may exclude the static library).

## Verify

```bash
cd packages/good_sleep_test
flutter pub get
flutter test
```

Device smoke test: `example/` with a Contec SpO2 probe powered on.
