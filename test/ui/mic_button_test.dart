// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ramble_voice/core/cleanup/cleanup_engine.dart';
import 'package:ramble_voice/core/dictation/dictation_controller.dart';
import 'package:ramble_voice/ui/widgets/mic_button.dart';

import 'fakes.dart';

DictationListening listening({double level = 0.4}) => DictationListening(
      elapsed: const Duration(seconds: 3),
      level: level,
      limit: const Duration(minutes: 10),
      warnBefore: const Duration(seconds: 30),
    );

void main() {
  final states = <String, DictationState>{
    'Start dictation': const DictationIdle(),
    'Starting microphone': const DictationStarting(),
    'Stop and clean up': listening(),
    'Cleaning up': const DictationProcessing(recordingId: 'r1'),
    'Start dictation ': DictationDone(DictationOutcome(
      recordingId: 'r1',
      text: 'Hello',
      engine: EngineKind.onDevice,
      duration: const Duration(seconds: 2),
      createdAt: DateTime(2026),
    )),
    'Start dictation  ': const DictationFailed(message: 'Nope'),
  };

  for (final e in states.entries) {
    testWidgets('semantics label for ${e.value.runtimeType}', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(Center(child: MicButton(state: e.value, onTap: () {}))));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel(e.key.trim()), findsWidgets);
      handle.dispose();
    });
  }

  testWidgets('tap invokes callback when idle and not when processing', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Center(child: MicButton(state: const DictationIdle(), onTap: () => taps++))));
    await tester.tap(find.byType(MicButton));
    expect(taps, 1);
    await tester.pumpWidget(host(Center(
      child: MicButton(state: const DictationProcessing(recordingId: 'r'), onTap: () => taps++),
    )));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(MicButton), warnIfMissed: false);
    expect(taps, 1);
  });

  testWidgets('Enter and Space activate when focused', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Center(
      child: MicButton(state: const DictationIdle(), onTap: () => taps++, autofocus: true),
    )));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
  });

  testWidgets('long press calls hold callbacks', (tester) async {
    var start = 0, end = 0;
    await tester.pumpWidget(host(Center(
      child: MicButton(
        state: const DictationIdle(),
        onTap: () {},
        onHoldStart: () => start++,
        onHoldEnd: () => end++,
      ),
    )));
    final g = await tester.startGesture(tester.getCenter(find.byType(MicButton)));
    await tester.pump(const Duration(milliseconds: 700));
    expect(start, 1);
    await g.up();
    await tester.pump();
    expect(end, 1);
  });

  testWidgets('morphs through all states without errors', (tester) async {
    for (final s in states.values) {
      await tester.pumpWidget(host(Center(child: MicButton(state: s, onTap: () {}))));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(tester.takeException(), isNull);
  });
}
