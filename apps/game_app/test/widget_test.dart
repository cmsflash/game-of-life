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
    FakeAuthRepository? authRepository,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            authRepository ?? FakeAuthRepository(),
          ),
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

  testWidgets('route changes never paint old and new screens together', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));

    expect(find.text('Give life\na side.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-local')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Set the terms of life'), findsOneWidget);
    expect(find.text('Give life\na side.'), findsNothing);
  });

  testWidgets('victory mode transition keeps only the current panel mounted', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('elimination')), findsOneWidget);
    await tester.tap(find.text('Turn limit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));

    expect(find.byKey(const Key('elimination')), findsNothing);
    expect(find.byKey(const Key('turn-limit')), findsOneWidget);
  });

  testWidgets('shell-to-game navigation never keeps the setup screen mounted', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();

    final start = find.byKey(const Key('start-local-game'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('local-life-board')), findsOneWidget);
    expect(find.text('Set the terms of life'), findsNothing);
  });

  testWidgets('sign-in page keeps password and local play always available', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login-username')), findsOneWidget);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    expect(find.text('Play locally without an account'), findsOneWidget);
  });

  testWidgets('about page exposes privacy, terms, and deletion guidance', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.text('Account deletion'), findsOneWidget);
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

  testWidgets('signed-in player can confirm permanent account deletion', (
    tester,
  ) async {
    final repository = FakeAuthRepository();
    await repository.login(username: 'alice', password: 'password');
    await pumpApp(tester, authRepository: repository);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('delete-account')));
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this account permanently?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-account')));
    await tester.pumpAndSettle();

    expect(repository.current, isNull);
    expect(find.text('Give life\na side.'), findsOneWidget);
  });
}
