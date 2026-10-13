// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/dictation/field_join.dart';

void main() {
  group('lists', () {
    test('new items after a filled item start on a new line', () {
      expect(FieldJoin.fit('Shopping:\n- milk', '- eggs\n- bread'), '\n- eggs\n- bread');
      expect(FieldJoin.fit('1. call mum', '2. pay rent'), '\n2. pay rent');
      expect(FieldJoin.fit('- [x] milk', '- [ ] eggs'), '\n- [ ] eggs');
    });

    test('right after an empty marker the repeated marker is dropped', () {
      expect(FieldJoin.fit('Todo\n1. call mum\n2. ', '2. Eggs\n3. Bread'), 'Eggs\n3. Bread');
      expect(FieldJoin.fit('- [x] milk\n- [ ] ', '- [ ] eggs\n- [ ] bread'), 'eggs\n- [ ] bread');
      expect(FieldJoin.fit('- ', 'eggs'), 'eggs');
    });

    test("the model's own line break wins: a paragraph after the list", () {
      expect(FieldJoin.fit('- milk', '\n\nThat is all for today.'), '\n\nThat is all for today.');
      expect(FieldJoin.fit('', '\nStart'), 'Start');
    });

    test('text continuing an item stays on its line', () {
      expect(FieldJoin.fit('- milk', 'and cheese'), ' and cheese');
    });
  });

  group('spacing', () {
    test('a space between words', () {
      expect(FieldJoin.fit('Hello', 'world'), ' world');
      expect(FieldJoin.fit('Hello.', 'Next one.'), ' Next one.');
    });

    test('no space after whitespace, an opening bracket, or before punctuation', () {
      expect(FieldJoin.fit('Hello ', 'world'), 'world');
      expect(FieldJoin.fit('(', 'aside'), 'aside');
      expect(FieldJoin.fit('Hello', ', world'), ', world');
      expect(FieldJoin.fit('', 'Start'), 'Start');
    });

    test('no spaces around Chinese or Japanese', () {
      expect(FieldJoin.fit('你好', '谢谢'), '谢谢');
      expect(FieldJoin.fit('今日は', 'いい天気'), 'いい天気');
    });

    test('a space before following words', () {
      expect(FieldJoin.fit('Hello', 'big', 'world'), ' big ');
      expect(FieldJoin.fit('Hello ', 'big', ' world'), 'big');
      expect(FieldJoin.fit('Hello ', 'big', '.'), 'big');
    });
  });
}
