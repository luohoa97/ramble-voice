// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/style/native_script.dart';

void main() {
  test('romanized Japanese becomes kana for Japanese speakers', () {
    expect(NativeScript.apply("Okay, I'm heading out now. Sayonara, see you tomorrow!", ['en', 'ja']),
        "Okay, I'm heading out now. さようなら, see you tomorrow!");
    expect(NativeScript.apply('Arigato gozaimasu!', ['ja']), 'ありがとうございます!');
  });

  test('pinyin becomes Simplified Chinese for Chinese speakers', () {
    expect(NativeScript.apply('Ni hao, how are you? Xie xie.', ['zh']), '你好, how are you? 谢谢.');
  });

  test('no languages selected means any', () {
    expect(NativeScript.apply('Sayonara', const []), 'さようなら');
  });

  test('left alone for other languages and inside other words', () {
    expect(NativeScript.apply('Sayonara', ['en', 'fr']), 'Sayonara');
    expect(NativeScript.apply('sugoiness kawaiiest', ['ja']), 'sugoiness kawaiiest');
    expect(NativeScript.apply('My mama said nani', ['zh', 'ja']), 'My mama said nani');
  });
}
