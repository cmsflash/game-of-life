import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/game/data/game_view_settings_store.dart';
import 'package:game_of_life/features/game/domain/game_view_settings.dart';

void main() {
  test('restores and persists the death visualization preference', () async {
    final store = MemoryGameViewSettingsStore(visualizeDeathsInPreview: false);
    final controller = GameViewSettingsController(store);
    addTearDown(controller.dispose);

    await Future<void>.delayed(Duration.zero);
    expect(controller.state.visualizeDeathsInPreview, isFalse);

    controller.setVisualizeDeathsInPreview(true);
    await Future<void>.delayed(Duration.zero);
    expect(store.visualizeDeathsInPreview, isTrue);
  });
}
