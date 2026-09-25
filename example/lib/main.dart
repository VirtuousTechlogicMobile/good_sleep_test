import 'package:flutter/material.dart';
import 'package:good_sleep_test/good_sleep_test.dart';

void main() {
  runApp(const MaterialApp(home: _Home()));
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _session = GoodSleepSession(
    onLog: (l, c, m, [d]) => debugPrint('[$l] $c $m'),
  );
  String _status = 'idle';

  Future<void> _run() async {
    setState(() => _status = 'permissions…');
    await _session.requestPermissions();
    setState(() => _status = 'searching…');
    await _session.startSearch();
    await Future<void>.delayed(const Duration(seconds: 8));
    setState(() => _status = 'connecting ${_session.selectedDeviceName}…');
    await _session.connect();
    setState(() => _status = 'recording…');
    await _session.startRealtimeRecording();
  }

  Future<void> _stop() async {
    final r = await _session.stopRecording();
    await _session.disconnect();
    setState(() => _status =
        'done spo2=${r.spo2RowCount} wave=${r.waveRowCount}\n${r.spo2Path}');
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('good_sleep_test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status),
            ElevatedButton(onPressed: _run, child: const Text('Search & Record')),
            ElevatedButton(onPressed: _stop, child: const Text('Stop')),
          ],
        ),
      ),
    );
  }
}
