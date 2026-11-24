import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';

import 'lock_probe.dart';
import 'probe.dart';

void main() => runApp(const MaterialApp(home: ProbeScreen()));

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});
  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  String _result = 'Running canonical JSON and hash vectors';
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _runVectors();
  }

  void _record(String value) {
    debugPrintSynchronously(value);
    if (mounted) setState(() => _result = value);
  }

  Future<void> _runVectors() async {
    try {
      _record(await vectors());
      if (const bool.fromEnvironment('AUTO_R8')) {
        await _runMemory();
      }
    } catch (error) {
      _record('P14 FAIL $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runMemory() async {
    final before = _result;
    setState(() => _busy = true);
    try {
      _record('$before\n${await Isolate.run(memory)}');
    } catch (error) {
      _record('$before\nR8 FAIL $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runLockWait() async {
    final before = _result;
    setState(() => _busy = true);
    try {
      _record('$before\n${await Isolate.run(historyLockWait)}');
    } catch (error) {
      _record('$before\nA4 FAIL $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Venera-V Sync Probe')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(_result),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _runMemory,
            child: const Text('Measure 50,000 records'),
          ),
          FilledButton(
            onPressed: _busy ? null : _runLockWait,
            child: const Text('Measure SQLite lock waits'),
          ),
        ],
      ),
    ),
  );
}
