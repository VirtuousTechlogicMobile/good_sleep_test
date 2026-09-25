# good_sleep_test

Classic **Good Sleep Test** BLE session for Contec CMS50S / `SpO2*` pulse oximeters.

This is a **Flutter plugin** (Android + iOS) that embeds the Contec SDK so FlutterFlow
projects can use overnight spo2+wave recording **without editing native host files**.

## Install (GitHub — same as snore_detection)

```yaml
dependencies:
  good_sleep_test:
    git:
      url: https://github.com/VirtuousTechlogicMobile/good_sleep_test.git
```

FlutterFlow: **Settings → Dependencies → Custom Package** → git URL above.

## Quick start

```dart
import 'package:good_sleep_test/good_sleep_test.dart';

final session = GoodSleepSession(
  onLog: (level, code, message, [data]) => print('[$level] $code: $message'),
);

await session.requestPermissions();
await session.startSearch();
// wait / listen until session.selectedDeviceName is set
await session.connect();

final paths = await session.startRealtimeRecording();
// …overnight…
final result = await session.stopRecording();
await session.disconnect();

// Upload result.spo2Path + result.wavePath via UploadSleepTestFileCall
```

Event formats (native → Dart): `spo2Data,{spo2},{pr}` and `waveData,{wave}`.

## License

Proprietary — VirtuousTechlogic / Good Sleep Co. Not published to pub.dev.
