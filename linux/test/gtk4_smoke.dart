// SPDX-License-Identifier: GPL-3.0-or-later
//
// Smoke app for the GTK4 runner: pointer, text input, clipboard, scrolling,
// platform brightness, scale factor and the ramble/* channels.
// Build: tool/fl flutter build linux --release -t linux/test/gtk4_smoke.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const SmokeApp());

class SmokeApp extends StatelessWidget {
  const SmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GTK4 smoke',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFE5482D), brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFFE5482D), brightness: Brightness.dark),
      home: const SmokePage(),
    );
  }
}

class SmokePage extends StatefulWidget {
  const SmokePage({super.key});

  @override
  State<SmokePage> createState() => _SmokePageState();
}

class _SmokePageState extends State<SmokePage> {
  static const _window = MethodChannel('ramble/window');
  static const _overlay = MethodChannel('ramble/overlay');
  static const _cli = MethodChannel('ramble/cli');
  int _count = 0;
  String _log = '';
  final _ctl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cli.setMethodCallHandler((call) async {
      setState(() => _log = 'cli: ${call.method} ${call.arguments}');
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    setState(() => _log = 'clipboard: ${data?.text}');
  }

  Future<void> _overlayTest() async {
    final ok = await _overlay.invokeMethod<bool>(
        'setState', {'state': 'listening', 'level': 0.7, 'text': null});
    setState(() => _log = 'overlay supported: $ok');
    await Future<void>.delayed(const Duration(seconds: 3));
    await _overlay.invokeMethod<bool>('setState', {'state': 'idle', 'level': 0.0, 'text': null});
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ramble Voice GTK4 runner')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('brightness: ${mq.platformBrightness.name}  dpr: ${mq.devicePixelRatio}  '
              'size: ${mq.size.width.toStringAsFixed(0)}x${mq.size.height.toStringAsFixed(0)}  '
              'textScale: ${mq.textScaler.scale(1)}'),
          const SizedBox(height: 12),
          Text('count: $_count', style: Theme.of(context).textTheme.headlineMedium),
          Row(children: [
            FilledButton(onPressed: () => setState(() => _count++), child: const Text('Increment')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _paste, child: const Text('Read clipboard')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _overlayTest, child: const Text('Overlay')),
            const SizedBox(width: 8),
            OutlinedButton(
                onPressed: () => _window.invokeMethod('hide'), child: const Text('Hide window')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            decoration: const InputDecoration(labelText: 'Type here (IME, paste, Tab)'),
          ),
          const SizedBox(height: 8),
          const TextField(
            minLines: 3,
            maxLines: 5,
            decoration: InputDecoration(labelText: 'Multiline'),
          ),
          const SizedBox(height: 12),
          Text(_log),
          for (var i = 0; i < 40; i++) ListTile(title: Text('Row $i'), subtitle: const Text('scroll me')),
        ],
      ),
    );
  }
}
