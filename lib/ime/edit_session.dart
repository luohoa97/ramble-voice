// SPDX-License-Identifier: GPL-3.0-or-later

/// Voice editing inside the keyboard: picks what to edit, runs the
/// [EditController], writes the revision into the field and offers Undo.
///
/// Normal dictation never follows spoken instructions. Only this flow does,
/// and only after the user taps the Edit key; the model gets the text and the
/// spoken instruction and can only return replacement text.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/cleanup/cleanup_engine.dart' show CleanupRequest;
import '../core/dictation/edit_controller.dart';
import '../platform/android/ime_bridge.dart';
import 'ime_app.dart';

/// How much text on each side of the cursor is edited when nothing is
/// selected and no recent dictation is available.
const editContextLimit = 2000;

/// Where the text being edited came from.
enum EditSource {
  selection('Editing selection'),
  lastDictation('Editing last dictation'),
  field('Editing the text in this field');

  const EditSource(this.label);
  final String label;
}

/// The text Ramble last typed into a field, so Edit can target exactly it.
class LastDictation {
  const LastDictation({required this.text, this.packageName});
  final String text;
  final String? packageName;
}

class LastDictationNotifier extends Notifier<LastDictation?> {
  @override
  LastDictation? build() => null;
  void set(LastDictation? value) => state = value;
}

final lastDictationProvider = NotifierProvider<LastDictationNotifier, LastDictation?>(LastDictationNotifier.new);

enum EditPhase {
  /// Nothing happening.
  idle,

  /// Reading the field.
  resolving,
  listening,
  processing,

  /// The revision was written; Undo is available.
  applied,
  failed,
}

class ImeEditState {
  const ImeEditState({
    this.phase = EditPhase.idle,
    this.source,
    this.message,
    this.listening,
    this.undoable = false,
    this.unchanged = false,
  });

  final EditPhase phase;
  final EditSource? source;

  /// Failure or hint text for the UI.
  final String? message;

  /// Live level/elapsed while [phase] is [EditPhase.listening].
  final EditListening? listening;
  final bool undoable;

  /// The model returned the text as it was (the instruction was unclear).
  final bool unchanged;

  /// The edit panel replaces the mic area while this is true.
  bool get active => phase != EditPhase.idle;
}

class ImeEditNotifier extends Notifier<ImeEditState> {
  EditSource? _source;

  /// What is in the field now for the applied edit: used to undo.
  String? _original;
  String? _revised;
  StreamSubscription<EditState>? _sub;
  Timer? _idleTimer;

  @override
  ImeEditState build() {
    final controller = ref.watch(editControllerProvider);
    _sub = controller.states.listen(_onEditState);
    ref.onDispose(() {
      _sub?.cancel();
      _idleTimer?.cancel();
    });
    return const ImeEditState();
  }

  ImeBridge get _bridge => ref.read(imeBridgeProvider);
  EditController get _controller => ref.read(editControllerProvider);

  /// Starts an edit: resolves the source text, then listens for the
  /// instruction.
  Future<void> begin() async {
    if (state.phase == EditPhase.listening || state.phase == EditPhase.processing || state.phase == EditPhase.resolving) {
      return;
    }
    if (_bridge.current.isPassword) {
      _fail('Editing is off in password fields.');
      return;
    }
    _idleTimer?.cancel();
    state = const ImeEditState(phase: EditPhase.resolving);
    final resolved = await resolveSource();
    if (resolved == null) {
      _fail('Nothing to edit here. Select text, or dictate first.');
      return;
    }
    _source = resolved.source;
    _original = null;
    _revised = null;
    state = ImeEditState(phase: EditPhase.listening, source: resolved.source);
    await _controller.startEdit(resolved.text, contextBefore: resolved.before, contextAfter: resolved.after);
  }

  /// Tap-to-finish while the instruction is being spoken.
  Future<void> finish() => _controller.stop();

  /// Cancels listening or dismisses the panel.
  Future<void> dismiss() async {
    _idleTimer?.cancel();
    if (_controller.isBusy) await _controller.cancel();
    _controller.reset();
    _source = null;
    state = const ImeEditState();
  }

  /// Puts the original text back after an applied edit.
  Future<void> undo() async {
    final original = _original;
    final revised = _revised;
    if (original == null || revised == null) return;
    final ok = await _bridge.replaceBeforeCursor(revised.length, original, expected: revised);
    if (!ok) {
      _fail('Could not undo: the text changed.');
      return;
    }
    _setLastDictation(original);
    _original = _revised = null;
    _controller.reset();
    state = const ImeEditState();
  }

  /// The field changed (new field or keyboard hidden): drop any pending edit.
  void reset() {
    _idleTimer?.cancel();
    if (_controller.isBusy) unawaited(_controller.cancel());
    _controller.reset();
    _original = _revised = null;
    _source = null;
    if (state.phase != EditPhase.idle) state = const ImeEditState();
  }

  /// Characters of the field text after the cursor, for [EditSource.field].
  int _afterLength = 0;

  /// Chooses what to edit: the selection, else the text Ramble last typed here
  /// (if it is still right before the cursor), else the field's text on both
  /// sides of the cursor.
  Future<({EditSource source, String text, String? before, String? after})?> resolveSource() async {
    _afterLength = 0;
    final selected = await _bridge.getSelectedText();
    if (selected != null && selected.trim().isNotEmpty) {
      // The text around the selection is context only, so the revision fits
      // in place (case, spacing, punctuation).
      return (
        source: EditSource.selection,
        text: selected,
        before: await _bridge.getTextBeforeCursor(CleanupRequest.contextBeforeLimit),
        after: await _bridge.getTextAfterCursor(CleanupRequest.contextAfterLimit),
      );
    }
    final last = ref.read(lastDictationProvider);
    if (last != null && last.text.isNotEmpty && last.packageName == _bridge.current.packageName) {
      final before = await _bridge.getTextBeforeCursor(last.text.length);
      if (before == last.text) return (source: EditSource.lastDictation, text: last.text, before: null, after: null);
    }
    final before = await _bridge.getTextBeforeCursor(editContextLimit) ?? '';
    final after = await _bridge.getTextAfterCursor(editContextLimit) ?? '';
    final text = before + after;
    if (text.trim().isEmpty) return null;
    _afterLength = after.length;
    return (source: EditSource.field, text: text, before: null, after: null);
  }

  void _onEditState(EditState s) {
    switch (s) {
      case EditIdle(:final notice):
        if (state.phase == EditPhase.listening || state.phase == EditPhase.processing) {
          if (notice != null) {
            _fail(notice);
          } else {
            state = const ImeEditState();
          }
        }
      case EditStarting():
        break;
      case EditListening():
        if (state.phase == EditPhase.listening) {
          state = ImeEditState(phase: EditPhase.listening, source: _source, listening: s);
        }
      case EditProcessing():
        state = ImeEditState(phase: EditPhase.processing, source: _source);
      case EditFailed(:final message):
        _fail(message);
      case EditDone(:final outcome):
        unawaited(_apply(outcome));
    }
  }

  Future<void> _apply(EditOutcome outcome) async {
    final source = _source;
    if (source == null) return;
    if (!outcome.changed) {
      state = ImeEditState(phase: EditPhase.applied, source: source, unchanged: true);
      _scheduleIdle(const Duration(seconds: 3));
      return;
    }
    final bool ok;
    if (source == EditSource.selection) {
      // The selection may have moved while the user was talking.
      final now = await _bridge.getSelectedText();
      ok = now == outcome.original && await _bridge.replaceSelection(outcome.revised);
    } else if (source == EditSource.field && _afterLength > 0) {
      final splitAt = outcome.original.length - _afterLength;
      ok = await _bridge.replaceAroundCursor(
        outcome.original.substring(0, splitAt),
        outcome.original.substring(splitAt),
        outcome.revised,
      );
    } else {
      ok = await _bridge.replaceBeforeCursor(
        outcome.original.length,
        outcome.revised,
        expected: outcome.original,
      );
    }
    if (!ok) {
      _fail('The text changed while you were speaking. Try again.');
      return;
    }
    _original = outcome.original;
    _revised = outcome.revised;
    _setLastDictation(outcome.revised);
    state = ImeEditState(phase: EditPhase.applied, source: source, undoable: true);
    _scheduleIdle(const Duration(seconds: 8));
  }

  /// The edited text now sits right before the cursor, so a further Edit
  /// targets it.
  void _setLastDictation(String text) {
    ref.read(lastDictationProvider.notifier).set(LastDictation(text: text, packageName: _bridge.current.packageName));
  }

  void _fail(String message) {
    _controller.reset();
    state = ImeEditState(phase: EditPhase.failed, source: _source, message: message);
  }

  void _scheduleIdle(Duration after) {
    _idleTimer?.cancel();
    _idleTimer = Timer(after, () {
      if (ref.mounted && state.phase == EditPhase.applied) {
        _original = _revised = null;
        state = const ImeEditState();
      }
    });
  }
}

final imeEditProvider = NotifierProvider<ImeEditNotifier, ImeEditState>(ImeEditNotifier.new);
