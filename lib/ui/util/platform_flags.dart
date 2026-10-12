// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which platform-specific UI to show. Overridable in tests.
final isLinuxProvider = Provider<bool>((ref) => Platform.isLinux);
final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid);

const appVersion = '0.1.0';
const appSourceUrl = 'https://github.com/luohoa97/RambleVoice';
const geminiConsoleUrl = 'https://aistudio.google.com';
