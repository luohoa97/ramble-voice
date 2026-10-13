// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/app/providers.dart';
import 'package:ramble_voice/core/history/history_db.dart';
import 'package:ramble_voice/ui/screens/history_screen.dart';

import 'fakes.dart';

HistoryEntry entry(
  String id,
  String text, {
  String engine = 'onDevice',
  bool fellBack = false,
}) => HistoryEntry(
  id: id,
  createdAt: DateTime(2020, 3, 4, 9, 30),
  durationMs: 65000,
  cleaned: text,
  engine: engine,
  fellBack: fellBack,
  stylePreset: 'casual',
);

void main() {
  testWidgets('renders entries newest first with metadata', (tester) async {
    await tester.pumpWidget(
      host(
        const HistoryScreen(embedded: true),
        overrides: [
          ...baseOverrides(),
          historyProvider.overrideWith(
            (ref, query) => Stream.value([
              entry('a', 'Pick up milk and eggs.'),
              entry(
                'b',
                'Send the report on Friday.',
                engine: 'gemini',
                fellBack: true,
              ),
            ]),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Pick up milk and eggs.'), findsOneWidget);
    expect(find.text('Send the report on Friday.'), findsOneWidget);
    expect(find.textContaining('1:05'), findsNWidgets(2));
    expect(find.textContaining('Gemini (fallback)'), findsOneWidget);
    final a = tester.getTopLeft(find.text('Pick up milk and eggs.')).dy;
    final b = tester.getTopLeft(find.text('Send the report on Friday.')).dy;
    expect(a < b, isTrue);
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(
      host(
        const HistoryScreen(embedded: true),
        overrides: [
          ...baseOverrides(),
          historyProvider.overrideWith(
            (ref, query) => Stream.value(<HistoryEntry>[]),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('No dictations yet'), findsOneWidget);
  });
}
