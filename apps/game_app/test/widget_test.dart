import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/app.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/presentation/online_match_screen.dart';
import 'package:game_of_life/providers.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    FakeAuthRepository? authRepository,
    FakeTurnNotificationRepository? notificationRepository,
    FakeTurnNotificationGateway? notificationGateway,
    LocalGameStore? localGameStore,
    FakeOnlineRepository? onlineRepository,
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
          localGameStoreProvider.overrideWithValue(
            localGameStore ?? MemoryLocalGameStore(),
          ),
          onlineRepositoryProvider.overrideWithValue(
            onlineRepository ?? FakeOnlineRepository(),
          ),
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

    expect(find.text('Choose your next game'), findsOneWidget);
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

    expect(find.text('Choose your next game'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-local')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Set the terms of life'), findsOneWidget);
    expect(find.text('Choose your next game'), findsNothing);
  });

  testWidgets('victory mode transition keeps only the current panel mounted', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('play-local')));
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
    await tester.tap(find.byKey(const Key('play-local')));
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
    expect(
      displayName.decoration?.helperText,
      'Shown to players you are matched with',
    );
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

    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.text('Account deletion'), findsOneWidget);
  });

  testWidgets('privacy policy discloses opponent display names', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Effective August 14, 2026'), findsOneWidget);
    expect(
      find.textContaining('Your display name is shown to players'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Display names are shared with matched opponents'),
      findsOneWidget,
    );
  });

  testWidgets('mobile layout reaches and starts a local match', (tester) async {
    await pumpApp(tester, size: const Size(390, 844));

    await tester.tap(find.byKey(const Key('play-local')));
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

    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('delete-account')));
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this account permanently?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-account')));
    await tester.pumpAndSettle();

    expect(repository.current, isNull);
    expect(find.text('Choose your next game'), findsOneWidget);
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

    await tester.tap(find.text('Player'));
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

  testWidgets('home has two destinations and four play choices', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));

    expect(find.byType(NavigationDestination), findsNWidgets(2));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Player'), findsOneWidget);
    expect(find.byKey(const Key('play-local')), findsOneWidget);
    expect(find.byKey(const Key('find-opponent')), findsOneWidget);
    expect(find.byKey(const Key('create-room')), findsOneWidget);
    expect(find.byKey(const Key('join-by-code')), findsOneWidget);
    expect(find.byKey(const Key('current-games')), findsOneWidget);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Online'), findsNothing);
    expect(find.text('Profile'), findsNothing);
  });

  testWidgets('create room offers public and private choices', (tester) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final online = FakeOnlineRepository();
    await pumpApp(tester, authRepository: auth, onlineRepository: online);

    final create = find.byKey(const Key('create-room'));
    await tester.ensureVisible(create);
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(find.text('Public room'), findsOneWidget);
    expect(find.text('Private room'), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-public-room')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(online.quickMatchCalls, 1);
    expect(find.text('Public room open'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('matchmaking-status')),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    online.ticketPoll.complete(
      const MatchmakingTicket(
        id: 'ticket-test-000001',
        status: 'cancelled',
        pollAfter: Duration.zero,
      ),
    );
    await tester.pump();
  });

  testWidgets('current online games put your turn first and hide history', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final online = FakeOnlineRepository(
      matches: [
        OnlineMatchSummary(
          id: 'waiting',
          status: 'active',
          updatedAt: DateTime.utc(2026, 8, 14, 10),
          opponentName: 'Waiting Player',
        ),
        OnlineMatchSummary(
          id: 'your-turn',
          status: 'active',
          updatedAt: DateTime.utc(2026, 8, 14, 9),
          opponentName: 'Your Turn Player',
          yourTurn: true,
        ),
        OnlineMatchSummary(
          id: 'completed',
          status: 'completed',
          updatedAt: DateTime.utc(2026, 8, 14, 11),
          opponentName: 'Past Player',
        ),
      ],
    );
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      onlineRepository: online,
    );

    expect(find.text('Online · Your turn'), findsOneWidget);
    expect(find.text('Online · Waiting for opponent'), findsOneWidget);
    expect(find.text('vs Past Player'), findsNothing);
    expect(find.byKey(const Key('finished-games')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('online-your-turn'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('online-waiting'))).dy),
    );

    await tester.ensureVisible(find.byKey(const Key('finished-games')));
    await tester.tap(find.byKey(const Key('finished-games')));
    await tester.pumpAndSettle();
    expect(find.text('vs Past Player'), findsOneWidget);
    expect(find.text('Online · Completed'), findsOneWidget);
  });

  testWidgets('signing out removes cached online games from Home', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final online = FakeOnlineRepository(
      matches: [
        OnlineMatchSummary(
          id: 'private-match',
          status: 'active',
          updatedAt: DateTime.utc(2026, 8, 14),
          opponentName: 'Private Opponent',
          yourTurn: true,
        ),
      ],
    );
    await pumpApp(tester, authRepository: auth, onlineRepository: online);
    expect(find.text('vs Private Opponent'), findsOneWidget);

    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    final signOut = find.widgetWithText(OutlinedButton, 'Sign out');
    await tester.ensureVisible(signOut);
    await tester.tap(signOut);
    await tester.pumpAndSettle();

    expect(find.text('vs Private Opponent'), findsNothing);
    expect(find.text('Choose your next game'), findsOneWidget);
  });

  testWidgets('recovered private room exposes copy and close controls', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final online = FakeOnlineRepository(
      matches: [
        OnlineMatchSummary(
          id: 'waiting-room',
          status: 'waiting',
          updatedAt: DateTime.utc(2026, 8, 14),
          opponentName: 'Waiting for player',
          joinCode: 'LIFE42',
        ),
      ],
    );
    await pumpApp(tester, authRepository: auth, onlineRepository: online);

    expect(find.text('Online · Private room waiting'), findsOneWidget);
    expect(find.byTooltip('Copy join code'), findsOneWidget);
    expect(
      find.byKey(const Key('find-opponent')).evaluate().single.widget,
      isA<FilledButton>().having(
        (button) => button.onPressed,
        'onPressed',
        isNull,
      ),
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('create-room')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('join-by-code')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Private room actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close private room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-close-private-room')));
    await tester.pumpAndSettle();

    expect(online.closeLobbyCalls, 1);
    expect(find.text('Online · Private room waiting'), findsNothing);
  });

  testWidgets('failed local load can be retried from Home', (tester) async {
    final store = MemoryLocalGameStore()..readError = StateError('disk');
    await pumpApp(tester, localGameStore: store);

    expect(find.byKey(const Key('retry-local-games')), findsOneWidget);
    final playLocal = tester.widget<FilledButton>(
      find.byKey(const Key('play-local')),
    );
    expect(playLocal.onPressed, isNull);

    store.readError = null;
    await tester.tap(find.byKey(const Key('retry-local-games')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('retry-local-games')), findsNothing);
    expect(find.text('No current games'), findsOneWidget);
  });

  testWidgets('match found away from Home opens when Home is revisited', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final online = FakeOnlineRepository();
    await pumpApp(tester, authRepository: auth, onlineRepository: online);

    final findOpponent = find.byKey(const Key('find-opponent'));
    await tester.ensureVisible(findOpponent);
    await tester.tap(findOpponent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();

    online.ticketPoll.complete(
      const MatchmakingTicket(
        id: 'ticket-test-000001',
        status: 'matched',
        pollAfter: Duration.zero,
        matchId: 'match-found-away',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byType(OnlineMatchScreen), findsOneWidget);
  });

  testWidgets('local current game can be deleted from Home', (tester) async {
    const config = LocalGameConfig();
    final createdAt = DateTime.utc(2026, 8, 14);
    final session = LocalGameSession(
      id: 'local-1',
      title: 'Couch match',
      opponentLabel: 'White',
      createdAt: createdAt,
      updatedAt: createdAt,
      config: config,
      game: const engine.GameEngine().initialState(config.rules),
    );
    final store = MemoryLocalGameStore(games: [session]);
    await pumpApp(tester, localGameStore: store);

    expect(find.text('Couch match'), findsOneWidget);
    expect(find.text('Local · Black to move'), findsOneWidget);
    await tester.tap(find.byTooltip('Local game actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete local game'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-local-game')));
    await tester.pumpAndSettle();

    expect(find.text('Couch match'), findsNothing);
    expect(store.games, isEmpty);
  });
}
