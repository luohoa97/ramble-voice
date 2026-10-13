// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/settings/app_settings.dart';
import 'package:ramble_voice/core/style/snippets.dart';
import 'package:ramble_voice/platform/android/ime_bridge.dart';

void main() {
  test('saying "my email" types the first address', () {
    const s = AppSettings(myEmails: ['me@example.com', 'work@example.com']);
    final snippets = s.effectiveStyle.snippets;
    expect(snippets.single.trigger, 'my email');
    expect(snippets.single.expansion, 'me@example.com');
    expect(AppSettings.fromJson(s.toJson()).myEmails, ['me@example.com', 'work@example.com']);
  });

  test('your own "my email" shortcut wins', () {
    const s = AppSettings(
      myEmails: ['me@example.com'],
      snippets: [Snippet(trigger: 'My email', expansion: 'other@example.com')],
    );
    expect(s.effectiveStyle.snippets.single.expansion, 'other@example.com');
  });

  test('email fields are recognized', () {
    expect(const ImeInputInfo(inputType: 0x21).isEmailField, isTrue);
    expect(const ImeInputInfo(inputType: 0xd1).isEmailField, isTrue);
    expect(const ImeInputInfo(inputType: 0x1).isEmailField, isFalse);
    expect(const ImeInputInfo(inputType: 0x2).isEmailField, isFalse);
  });
}
