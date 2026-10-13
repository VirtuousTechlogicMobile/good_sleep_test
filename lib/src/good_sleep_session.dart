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
///
/// Dart-only guards mirror the old Sleepcare host: one channel owner, no
/// overlapping search/connect, and no extra stopSearch after native already
/// finished discovery (avoids MethodChannel "Reply already submitted").
class GoodSleepSession {
  GoodSleepSession({this.onLog}) {
    _active = this;
    _method.setMethodCallHandler(_onNativeCallStatic);
  }

  final void Function(
      String level,
      String code,
      String message, [
      Map<String, dynamic>? data,
      ])? onLog;

  static const MethodChannel _method = MethodChannel(kGoodSleepMethodChannel);
  static const EventChannel _events = EventChannel(kGoodSleepEventChannel);

  /// Only the newest session owns native DEVICE_NAME / ERROR callbacks.
  static GoodSleepSession? _active;

  /// Serialize MethodChannel invokes so stop/search/connect never overlap.
  static Future<void> _invokeGate = Future.value();

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
  Future<String>? _searchInFlight;

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
    final previous = _invokeGate;
    final gate = Completer<void>();
    _invokeGate = gate.future;
    await previous;
    try {
      onLog?.call('event', 'native_invoke', method, {'args': args?.toString()});
      return await _method.invokeMethod(method, args);
    } catch (e) {
      onLog?.call('warn', 'native_invoke_error', '$method: $e');
      rethrow;
    } finally {
      gate.complete();
    }
  }

  static Future<void> _onNativeCallStatic(MethodCall call) async {
    await _active?._onNativeCall(call);
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
    if (_searchInFlight != null) {
      onLog?.call('warn', 'start_search_skipped', 'already_in_flight');
      return _searchInFlight!;
    }
    if (phase == GoodSleepSessionPhase.scanning ||
        phase == GoodSleepSessionPhase.connecting ||
        phase == GoodSleepSessionPhase.connected ||
        phase == GoodSleepSessionPhase.recording) {
      onLog?.call('warn', 'start_search_skipped', 'phase=$phase');
      return 'search_skipped';
    }

    _active = this;
    phase = GoodSleepSessionPhase.scanning;
    discoveredDevices.clear();
    selectedDeviceName = null;

    final future = () async {
      try {
        final res = await _invoke('startSearch');
        return res?.toString() ?? '';
      } finally {
        // Native stops itself on SpO2 find or timeout — leave phase idle unless
        // we already moved on to connecting/connected.
        if (phase == GoodSleepSessionPhase.scanning) {
          phase = GoodSleepSessionPhase.idle;
        }
        _searchInFlight = null;
      }
    }();
    _searchInFlight = future;
    return future;
  }

  /// Stop discovery only while a scan is actually running.
  Future<String> stopSearch() async {
    if (phase != GoodSleepSessionPhase.scanning && _searchInFlight == null) {
      onLog?.call('warn', 'stop_search_skipped', 'phase=$phase');
      return 'stop_skipped';
    }
    try {
      final res = await _invoke('stopSearch');
      if (phase == GoodSleepSessionPhase.scanning) {
        phase = GoodSleepSessionPhase.idle;
      }
      return res?.toString() ?? '';
    } catch (e) {
      onLog?.call('warn', 'stop_search_error', '$e');
      if (phase == GoodSleepSessionPhase.scanning) {
        phase = GoodSleepSessionPhase.idle;
      }
      return 'stop_error';
    }
  }

  Future<bool> isConnected() async {
    try {
      final res = await _invoke('isConnected');
      return res?.toString() == 'Connected';
    } catch (_) {
      return false;
    }
  }

  /// Connect to the SpO2 device found during [startSearch].
  ///
  /// Prefer awaiting the in-flight [startSearch] (native already stops on SpO2)
  /// instead of calling stopSearch while the startSearch Result is still open —
  /// that race causes MethodChannel "Reply already submitted" on stock native.
  Future<String> connect({String? deviceName}) async {
    _active = this;

    final pendingSearch = _searchInFlight;
    if (pendingSearch != null) {
      try {
        await pendingSearch.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Timed out waiting for native startSearch reply — soft-stop once.
        try {
          await stopSearch();
        } catch (_) {}
      }
    } else if (phase == GoodSleepSessionPhase.scanning) {
      try {
        await stopSearch();
      } catch (_) {}
    }

    phase = GoodSleepSessionPhase.connecting;
    final name = deviceName ?? selectedDeviceName;
    try {
      final res = await _invoke('connectDevice', {'selectedDevice': name});
      final text = res?.toString() ?? '';
      final ok = text.toLowerCase().contains('connected') &&
          !text.toLowerCase().contains('not') &&
          !text.toLowerCase().contains('no spo2');
      phase = ok ? GoodSleepSessionPhase.connected : GoodSleepSessionPhase.idle;
      return text;
    } catch (e) {
      phase = GoodSleepSessionPhase.idle;
      onLog?.call('error', 'connect_error', '$e');
      return 'not connected';
    }
  }

  Future<String> disconnect() async {
    await stopRecordingSilent();
    try {
      await stopSearch();
    } catch (_) {}
    try {
      final res = await _invoke('disconnectDevice');
      phase = GoodSleepSessionPhase.idle;
      selectedDeviceName = null;
      return res?.toString() ?? '';
    } catch (e) {
      phase = GoodSleepSessionPhase.idle;
      selectedDeviceName = null;
      return 'disconnect_error';
    }
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
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
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

  /// Soft dispose — stop scan only if still scanning; disconnect if linked.
  Future<void> dispose() async {
    await stopRecordingSilent();
    try {
      if (phase == GoodSleepSessionPhase.scanning || _searchInFlight != null) {
        await stopSearch();
      }
    } catch (_) {}
    try {
      if (phase == GoodSleepSessionPhase.connected ||
          phase == GoodSleepSessionPhase.recording ||
          phase == GoodSleepSessionPhase.connecting) {
        await _invoke('disconnectDevice');
      }
    } catch (_) {}
    if (identical(_active, this)) {
      _active = null;
    }
    phase = GoodSleepSessionPhase.idle;
  }
}
