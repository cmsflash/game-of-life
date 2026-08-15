import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/theme.dart';
import 'package:game_of_life/shared/life_logo.dart';

void main() {
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
      find.bySemanticsLabel('Life logo, diagonal two-player starting position'),
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
