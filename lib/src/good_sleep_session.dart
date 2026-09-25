import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Channel names match the legacy Sleepcare MainActivity / AppDelegate.
const String kGoodSleepMethodChannel = 'com.contectcms.bluetooth_cms5';
const String kGoodSleepEventChannel = 'getRealTimeDataEventChannel';

class GoodSleepRecordingResult {
  const GoodSleepRecordingResult({
    required this.spo2Path,
    required this.wavePath,
    required this.spo2RowCount,
    required this.waveRowCount,
    this.recordingStart,
    this.recordingEnd,
  });

  final String spo2Path;
  final String wavePath;
  final int spo2RowCount;
  final int waveRowCount;
  final DateTime? recordingStart;
  final DateTime? recordingEnd;
}

enum GoodSleepSessionPhase {
  idle,
  scanning,
  connecting,
  connected,
  recording,
  stopping,
}

/// Classic Good Sleep Test session (Contec CMS50S / SpO2* devices).
///
/// Native SDK is shipped inside this Flutter plugin. Host app uploads files
/// via Resdent `UploadSleepTestFileCall`.
class GoodSleepSession {
  GoodSleepSession({this.onLog}) {
    _method.setMethodCallHandler(_onNativeCall);
  }

  final void Function(
    String level,
    String code,
    String message, [
    Map<String, dynamic>? data,
  ])? onLog;

  static const MethodChannel _method = MethodChannel(kGoodSleepMethodChannel);
  static const EventChannel _events = EventChannel(kGoodSleepEventChannel);

  final List<String> discoveredDevices = [];
  GoodSleepSessionPhase phase = GoodSleepSessionPhase.idle;

  StreamSubscription? _eventSub;
  IOSink? _spo2Sink;
  IOSink? _waveSink;
  File? _spo2File;
  File? _waveFile;
  int spo2RowCount = 0;
  int waveRowCount = 0;
  DateTime? _recordingStart;
  String? selectedDeviceName;

  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every(
      (s) => s.isGranted || s.isLimited || s.isRestricted,
    );
  }

  Future<dynamic> _invoke(String method, [dynamic args]) async {
    onLog?.call('event', 'native_invoke', method, {'args': args?.toString()});
    return _method.invokeMethod(method, args);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'DEVICE_NAME') {
      final name = call.arguments?.toString() ?? '';
      if (name.isNotEmpty && !discoveredDevices.contains(name)) {
        discoveredDevices.add(name);
        if (name.contains('SpO2')) {
          selectedDeviceName = name;
        }
        onLog?.call('event', 'device_found', name);
      }
    } else if (call.method == 'ERROR' || call.method == 'CONNECT-ERROR') {
      onLog?.call('error', call.method, call.arguments?.toString() ?? '');
    }
  }

  /// Start BLE search for SpO2 devices.
  Future<String> startSearch() async {
    phase = GoodSleepSessionPhase.scanning;
    discoveredDevices.clear();
    selectedDeviceName = null;
    final res = await _invoke('startSearch');
    return res?.toString() ?? '';
  }

  Future<String> stopSearch() async {
    final res = await _invoke('stopSearch');
    phase = GoodSleepSessionPhase.idle;
    return res?.toString() ?? '';
  }

  Future<bool> isConnected() async {
    final res = await _invoke('isConnected');
    return res?.toString() == 'Connected';
  }

  /// Connect to the SpO2 device found during [startSearch].
  Future<String> connect({String? deviceName}) async {
    phase = GoodSleepSessionPhase.connecting;
    final name = deviceName ?? selectedDeviceName;
    final res = await _invoke('connectDevice', {'selectedDevice': name});
    final text = res?.toString() ?? '';
    final ok = text.toLowerCase().contains('connected') &&
        !text.toLowerCase().contains('not') &&
        !text.toLowerCase().contains('no spo2');
    phase = ok ? GoodSleepSessionPhase.connected : GoodSleepSessionPhase.idle;
    return text;
  }

  Future<String> disconnect() async {
    await stopRecordingSilent();
    final res = await _invoke('disconnectDevice');
    phase = GoodSleepSessionPhase.idle;
    return res?.toString() ?? '';
  }

  Future<String> deleteData() async {
    final res = await _invoke('deleteData');
    return res?.toString() ?? '';
  }

  Future<dynamic> getBattery() => _invoke('getBattery');

  /// Start realtime and append spo2 (`spo2,pr`) + wave (`wave`) CSV lines.
  Future<({String spo2Path, String wavePath})> startRealtimeRecording({
    String? spo2Path,
    String? wavePath,
    void Function(String event)? onRawEvent,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-');
    _spo2File = File(spo2Path ?? '${dir.path}/gst_spo2_$stamp.csv');
    _waveFile = File(wavePath ?? '${dir.path}/gst_wave_$stamp.csv');
    await _spo2File!.create(recursive: true);
    await _waveFile!.create(recursive: true);
    _spo2Sink = _spo2File!.openWrite(mode: FileMode.append);
    _waveSink = _waveFile!.openWrite(mode: FileMode.append);
    spo2RowCount = 0;
    waveRowCount = 0;
    _recordingStart = DateTime.now();

    await _eventSub?.cancel();
    _eventSub = _events.receiveBroadcastStream().listen((event) {
      final text = event?.toString() ?? '';
      onRawEvent?.call(text);
      _listenRealTimeData(text);
    });

    await _invoke('startRealtimeData');
    phase = GoodSleepSessionPhase.recording;
    return (spo2Path: _spo2File!.path, wavePath: _waveFile!.path);
  }

  void _listenRealTimeData(String realTimeData) {
    if (realTimeData.contains('waveData')) {
      final waveData = realTimeData.split('waveData,').last;
      _waveSink?.write('$waveData\n');
      waveRowCount++;
    } else if (realTimeData.contains('spo2Data')) {
      final spoTwoData = realTimeData.split('spo2Data,').last;
      if (spoTwoData.contains('null')) return;
      _spo2Sink?.write('$spoTwoData\n');
      spo2RowCount++;
    }
  }

  Future<void> stopRecordingSilent() async {
    try {
      await _invoke('stopRealtimeData');
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;
    await _spo2Sink?.flush();
    await _spo2Sink?.close();
    await _waveSink?.flush();
    await _waveSink?.close();
    _spo2Sink = null;
    _waveSink = null;
  }

  Future<GoodSleepRecordingResult> stopRecording() async {
    phase = GoodSleepSessionPhase.stopping;
    await stopRecordingSilent();
    final end = DateTime.now();
    final spo2 = _spo2File?.path;
    final wave = _waveFile?.path;
    if (spo2 == null || wave == null) {
      phase = GoodSleepSessionPhase.connected;
      throw StateError('No recording files');
    }
    phase = GoodSleepSessionPhase.connected;
    return GoodSleepRecordingResult(
      spo2Path: spo2,
      wavePath: wave,
      spo2RowCount: spo2RowCount,
      waveRowCount: waveRowCount,
      recordingStart: _recordingStart,
      recordingEnd: end,
    );
  }

  Future<void> dispose() async {
    await stopRecordingSilent();
    try {
      await _invoke('disconnectDevice');
    } catch (_) {}
  }
}
