import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/theme.dart';
import 'package:game_of_life/shared/life_logo.dart';

void main() {
  testWidgets('full logo uses the Game of Life wordmark', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLifeTheme(Brightness.light),
        home: const Scaffold(body: Center(child: LifeLogo())),
      ),
    );

    expect(find.text('Game of Life'), findsOneWidget);
    expect(find.text('LIFE'), findsNothing);
  });

  testWidgets('full wordmark fits a narrow mobile app bar', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLifeTheme(Brightness.light),
        home: Scaffold(
          appBar: AppBar(
            title: const LifeLogo(),
            actions: [
              TextButton(onPressed: () {}, child: const Text('Sign in')),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Game of Life'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logo paints the canonical diagonal two-player block', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLifeTheme(Brightness.light),
        home: const Scaffold(body: Center(child: LifeLogo(compact: true))),
      ),
    );

    expect(
      find.bySemanticsLabel(
        'Game of Life logo, diagonal two-player starting position',
      ),
      findsOneWidget,
    );
    expect(lifeLogoCellColors, const [
      LifeColors.sprout,
      LifeColors.paper,
      LifeColors.paper,
      LifeColors.sprout,
    ]);
    semantics.dispose();
  });
}
