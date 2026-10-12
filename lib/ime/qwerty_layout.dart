// SPDX-License-Identifier: GPL-3.0-or-later

/// Key layout and shift logic for the keyboard's QWERTY layer. Pure, so it is
/// unit tested without a widget tree.
library;

enum QwertyPage { letters, symbols, moreSymbols }

enum ShiftState { off, once, caps }

/// The three character rows of [page] (the bottom row is fixed).
List<List<String>> qwertyRows(QwertyPage page) => switch (page) {
      QwertyPage.letters => const [
          ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
          ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
          ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
        ],
      QwertyPage.symbols => const [
          ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
          ['@', '#', '\$', '_', '&', '-', '+', '(', ')', '/'],
          ['*', '"', "'", ':', ';', '!', '?'],
        ],
      QwertyPage.moreSymbols => const [
          ['~', '`', '|', '•', '√', 'π', '÷', '×', '¶', '∆'],
          ['£', '¢', '€', '¥', '^', '°', '=', '{', '}', '\\'],
          ['%', '©', '®', '™', '[', ']', '<', '>'],
        ],
    };

/// The shift state after a tap: off → once → off; a quick second tap while on
/// turns on caps lock, and a tap on caps lock turns it off.
ShiftState nextShift(ShiftState current, {required bool doubleTap}) => switch (current) {
      ShiftState.off => ShiftState.once,
      ShiftState.once => doubleTap ? ShiftState.caps : ShiftState.off,
      ShiftState.caps => ShiftState.off,
    };
