import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/app.dart';
import 'package:game_of_life/providers.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const GameOfLifeApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('home opens the complete local game setup', (tester) async {
    await pumpApp(tester);

    expect(find.text('Give life\na side.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-local')));
    await tester.pumpAndSettle();

    expect(find.text('Set the terms of life'), findsOneWidget);
    expect(find.text('Elimination'), findsOneWidget);
    expect(find.byKey(const Key('start-local-game')), findsOneWidget);
  });

  testWidgets('sign-in page keeps password login independent of Google', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('google-sign-in')), findsOneWidget);
    expect(find.byKey(const Key('login-username')), findsOneWidget);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    expect(find.text('Play locally without an account'), findsOneWidget);
  });

  testWidgets('mobile layout reaches and starts a local match', (tester) async {
    await pumpApp(tester, size: const Size(390, 844));

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('Set the terms of life'), findsOneWidget);

    final start = find.byKey(const Key('start-local-game'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-life-board')), findsOneWidget);
    expect(find.textContaining('to move'), findsOneWidget);
  });
}
