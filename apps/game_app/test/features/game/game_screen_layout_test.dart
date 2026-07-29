import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/local_game_screen.dart';
import 'package:game_of_life/providers.dart';

void main() {
  testWidgets('local game fits its board and scrolls status vertically', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = LocalGameController()..start(const LocalGameConfig());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localGameProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: LocalGameScreen()),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('local-life-board')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scrollViews = tester.widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scrollViews, isNotEmpty);
    expect(
      scrollViews.every((view) => view.scrollDirection == Axis.vertical),
      isTrue,
    );

    final statusCard = find.ancestor(
      of: find.text('TURN 1'),
      matching: find.byType(Card),
    );
    expect(statusCard, findsOneWidget);
    expect(tester.getSize(statusCard).width, lessThanOrEqualTo(320));
  });
}
