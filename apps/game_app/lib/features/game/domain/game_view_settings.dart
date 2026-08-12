import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/game_view_settings_store.dart';

class GameViewSettings {
  const GameViewSettings({this.visualizeDeathsInPreview = true});

  final bool visualizeDeathsInPreview;

  GameViewSettings copyWith({bool? visualizeDeathsInPreview}) =>
      GameViewSettings(
        visualizeDeathsInPreview:
            visualizeDeathsInPreview ?? this.visualizeDeathsInPreview,
      );
}

class GameViewSettingsController extends StateNotifier<GameViewSettings> {
  GameViewSettingsController(this._store) : super(const GameViewSettings()) {
    scheduleMicrotask(_restore);
  }

  final GameViewSettingsStore _store;

  Future<void> _restore() async {
    try {
      final value = await _store.readVisualizeDeathsInPreview();
      if (mounted && value != null) {
        state = state.copyWith(visualizeDeathsInPreview: value);
      }
    } catch (_) {
      // Keep the accessible default when platform storage is unavailable.
    }
  }

  void setVisualizeDeathsInPreview(bool value) {
    if (value == state.visualizeDeathsInPreview) return;
    state = state.copyWith(visualizeDeathsInPreview: value);
    unawaited(_persist(value));
  }

  Future<void> _persist(bool value) async {
    try {
      await _store.writeVisualizeDeathsInPreview(value);
    } catch (_) {
      // The setting remains active for this app session if persistence fails.
    }
  }
}
