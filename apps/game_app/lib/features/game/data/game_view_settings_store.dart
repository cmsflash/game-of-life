import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class GameViewSettingsStore {
  Future<bool?> readVisualizeDeathsInPreview();
  Future<void> writeVisualizeDeathsInPreview(bool value);
}

class SecureGameViewSettingsStore implements GameViewSettingsStore {
  SecureGameViewSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _visualizeDeathsKey =
      'game_of_life.visualize_deaths_in_preview.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<bool?> readVisualizeDeathsInPreview() async {
    return switch (await _storage.read(key: _visualizeDeathsKey)) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  @override
  Future<void> writeVisualizeDeathsInPreview(bool value) =>
      _storage.write(key: _visualizeDeathsKey, value: value.toString());
}

class MemoryGameViewSettingsStore implements GameViewSettingsStore {
  MemoryGameViewSettingsStore({this.visualizeDeathsInPreview});

  bool? visualizeDeathsInPreview;

  @override
  Future<bool?> readVisualizeDeathsInPreview() async =>
      visualizeDeathsInPreview;

  @override
  Future<void> writeVisualizeDeathsInPreview(bool value) async {
    visualizeDeathsInPreview = value;
  }
}
