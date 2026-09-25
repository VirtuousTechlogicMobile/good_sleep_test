import 'package:flutter_test/flutter_test.dart';
import 'package:good_sleep_test/good_sleep_test.dart';

void main() {
  test('channel constants', () {
    expect(kGoodSleepMethodChannel, 'com.contectcms.bluetooth_cms5');
    expect(kGoodSleepEventChannel, 'getRealTimeDataEventChannel');
  });

  test('GoodSleepRecordingResult holds dual paths', () {
    const r = GoodSleepRecordingResult(
      spo2Path: '/a.csv',
      wavePath: '/b.csv',
      spo2RowCount: 10,
      waveRowCount: 100,
    );
    expect(r.spo2Path, '/a.csv');
    expect(r.wavePath, '/b.csv');
  });
}
