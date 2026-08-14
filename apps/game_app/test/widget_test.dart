import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/app.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/providers.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    FakeAuthRepository? authRepository,
    FakeTurnNotificationRepository? notificationRepository,
    FakeTurnNotificationGateway? notificationGateway,
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
          sessionStoreProvider.overrideWithValue(MemorySessionStore()),
          turnNotificationRepositoryProvider.overrideWithValue(
            notificationRepository ?? FakeTurnNotificationRepository(),
          ),
          turnNotificationGatewayProvider.overrideWithValue(
            notificationGateway ?? FakeTurnNotificationGateway(),
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

  testWidgets('registration exposes a standard new-password autofill form', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    final usernameFinder = find.byKey(const Key('register-username'));
    expect(
      find.ancestor(of: usernameFinder, matching: find.byType(AutofillGroup)),
      findsOneWidget,
    );

    TextField field(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );

    final username = field('Username');
    final displayName = field('Display name');
    final email = field('Email');
    final password = field('Password');

    expect(username.autofillHints, const [
      AutofillHints.username,
      AutofillHints.newUsername,
    ]);
    expect(displayName.autofillHints, const [AutofillHints.nickname]);
    expect(email.autofillHints, const [AutofillHints.email]);
    expect(email.keyboardType, TextInputType.emailAddress);
    expect(password.autofillHints, const [AutofillHints.newPassword]);
    expect(password.obscureText, isTrue);
    expect(password.autocorrect, isFalse);
    expect(password.enableSuggestions, isFalse);
  });

  testWidgets('login and password reset use the right password contracts', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();

    TextField passwordField(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );

    expect(passwordField('Password').autofillHints, const [
      AutofillHints.password,
    ]);

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'alice');
    await tester.tap(find.text('Send reset code'));
    await tester.pumpAndSettle();

    expect(find.byType(AutofillGroup), findsOneWidget);
    expect(passwordField('New password').autofillHints, const [
      AutofillHints.newPassword,
    ]);
    expect(passwordField('Reset code').keyboardType, TextInputType.number);
    expect(passwordField('Reset code').autofillHints, const [
      AutofillHints.oneTimeCode,
    ]);
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

  testWidgets('signed-in player can opt into the reminder schedule', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.webPush(
        endpoint: 'https://push.example.test/subscription',
        p256dh: 'key',
        auth: 'secret',
      );
    await pumpApp(
      tester,
      authRepository: auth,
      notificationRepository: repository,
      notificationGateway: gateway,
    );

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Turn notifications'), findsOneWidget);
    expect(find.textContaining('8 hours'), findsOneWidget);
    expect(find.textContaining('24 hours'), findsOneWidget);
    expect(find.textContaining('72 hours'), findsOneWidget);

    await tester.tap(find.byKey(const Key('turn-notifications-toggle')));
    await tester.pumpAndSettle();

    expect(repository.upserts, hasLength(1));
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('turn-notifications-toggle')),
    );
    expect(toggle.value, isTrue);
  });
}
