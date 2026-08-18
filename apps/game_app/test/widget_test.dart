import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/app.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/auth/data/profile_avatar.dart';
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/presentation/online_match_screen.dart';
import 'package:game_of_life/features/social/data/social_models.dart';
import 'package:game_of_life/features/social/data/social_repository.dart';
import 'package:game_of_life/features/stats/data/player_stats.dart';
import 'package:game_of_life/features/stats/data/player_stats_repository.dart';
import 'package:game_of_life/providers.dart';
import 'package:go_router/go_router.dart';

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
    SocialRepository? socialRepository,
    PlayerStatsRepository? playerStatsRepository,
    ProfileAvatarPicker? profileAvatarPicker,
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
          socialRepositoryProvider.overrideWithValue(
            socialRepository ?? FakeSocialRepository(),
          ),
          playerStatsRepositoryProvider.overrideWithValue(
            playerStatsRepository ?? FakePlayerStatsRepository(),
          ),
          turnNotificationRepositoryProvider.overrideWithValue(
            notificationRepository ?? FakeTurnNotificationRepository(),
          ),
          turnNotificationGatewayProvider.overrideWithValue(
            notificationGateway ?? FakeTurnNotificationGateway(),
          ),
          profileAvatarPickerProvider.overrideWithValue(
            profileAvatarPicker ?? FakeProfileAvatarPicker(),
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
      'Public to signed-in players in search, friends, and matches',
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

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.text('Account deletion'), findsOneWidget);
  });

  testWidgets(
    'privacy policy discloses Social, avatars, and automatic notifications',
    (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy Policy'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Effective August 18, 2026'), findsOneWidget);
      expect(
        find.textContaining(
          'profile picture, and current Elo rating are searchable',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Display names, profile pictures, and ratings'),
        findsOneWidget,
      );
      expect(
        find.textContaining('stored as a private object at rest'),
        findsOneWidget,
      );
      expect(
        find.textContaining('shared caches may retain a prior response'),
        findsOneWidget,
      );
      expect(
        find.textContaining('immediately fail closed with a 404 response'),
        findsOneWidget,
      );
      expect(
        find.textContaining('immediately prevents public delivery'),
        findsOneWidget,
      );
      expect(
        find.textContaining('A spawn is every new cell of your color'),
        findsOneWidget,
      );
      expect(
        find.textContaining('normal cleanup checks it after about 15 minutes'),
        findsOneWidget,
      );
      expect(
        find.textContaining('eligible for storage lifecycle cleanup'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Durable retries and alarms cover rare'),
        findsOneWidget,
      );
      expect(
        find.textContaining('configured maximum, currently 14 days'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'automatically registers and refreshes a push endpoint',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('browser or system settings'),
        findsAtLeastNWidgets(1),
      );
    },
  );

  testWidgets('terms disclose avatar rights, license, and content rules', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terms of Use'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('confirm that you own it or have permission'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'limited, non-exclusive, worldwide, royalty-free license',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('crop, re-encode, host, reproduce'),
      findsOneWidget,
    );
    expect(
      find.textContaining('privacy-invasive, sexually exploitative'),
      findsOneWidget,
    );
    expect(
      find.textContaining('infringes intellectual-property or other rights'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'may remove or disable a picture and restrict access',
      ),
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
    final notifications = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.prompt,
      );
    await pumpApp(
      tester,
      authRepository: repository,
      notificationRepository: notifications,
      notificationGateway: gateway,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('delete-account')));
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this account permanently?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-account')));
    await tester.pumpAndSettle();

    expect(repository.current, isNull);
    expect(notifications.deletedInstallationIds, ['test-device']);
    expect(gateway.deactivateCalls, 1);
    expect(find.text('Choose your next game'), findsOneWidget);
  });

  testWidgets('Settings uploads and removes a profile picture', (tester) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final picker = FakeProfileAvatarPicker()
      ..result = ProfileAvatarUpload(
        bytes: Uint8List.fromList(const [0xff, 0xd8, 0xff]),
        filename: 'profile.jpg',
        contentType: 'image/jpeg',
      );
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      profileAvatarPicker: picker,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-avatar')), findsOneWidget);
    expect(
      find.text(
        'Shown publicly in player search, friends, and online matches.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('choose-profile-picture')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(auth.current?.avatarVersion, 1);
    expect(find.text('Profile picture updated.'), findsOneWidget);
    expect(find.byKey(const Key('remove-profile-picture')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-profile-picture')));
    await tester.pumpAndSettle();

    expect(auth.removeAvatarCalls, 1);
    expect(auth.current?.avatarUrl, isNull);
    expect(find.text('Profile picture removed.'), findsOneWidget);
    expect(find.byKey(const Key('remove-profile-picture')), findsNothing);
  });

  testWidgets('profile picture failure offers an explicit retry', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final picker = FakeProfileAvatarPicker()
      ..error = const ProfileAvatarPickException(
        'Choose a JPEG, PNG, or WebP image smaller than 3 MB.',
      );
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      profileAvatarPicker: picker,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-profile-picture')));
    await tester.pumpAndSettle();

    expect(find.textContaining('smaller than 3 MB'), findsOneWidget);
    expect(find.byKey(const Key('retry-profile-picture')), findsOneWidget);
  });

  testWidgets('profile picture picker result is fenced after sign out', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final pickerGate = Completer<ProfileAvatarUpload?>();
    final picker = FakeProfileAvatarPicker()..gate = pickerGate;
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      profileAvatarPicker: picker,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-profile-picture')));
    await tester.pump();
    final choose = tester.widget<FilledButton>(
      find.byKey(const Key('choose-profile-picture')),
    );
    expect(choose.onPressed, isNull);

    await tester.ensureVisible(find.text('Sign out').last);
    await tester.tap(find.text('Sign out').last);
    await tester.pump();
    pickerGate.complete(
      ProfileAvatarUpload(
        bytes: Uint8List.fromList(const [0xff, 0xd8, 0xff]),
        filename: 'profile.jpg',
        contentType: 'image/jpeg',
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.uploadAvatarCalls, 0);
    expect(auth.current, isNull);
    expect(find.text('Choose your next game'), findsOneWidget);
  });

  testWidgets('legacy player routes redirect to Settings', (tester) async {
    await pumpApp(tester, size: const Size(390, 844));
    final context = tester.element(find.byType(NavigationBar));

    GoRouter.of(context).go('/player');
    await tester.pumpAndSettle();
    expect(find.text('Make it your own'), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);

    GoRouter.of(tester.element(find.byType(NavigationBar))).go('/profile');
    await tester.pumpAndSettle();
    expect(find.text('Make it your own'), findsOneWidget);
  });

  testWidgets('wide signed-in rail has no redundant account avatar', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    await pumpApp(tester, authRepository: auth);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.bySemanticsLabel('Profile picture for alice'), findsNothing);
    expect(find.byTooltip('Sign in'), findsNothing);
  });

  testWidgets('signed-in player automatically receives granted turn alerts', (
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

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Turn alerts'), findsOneWidget);
    expect(find.textContaining('8 hours'), findsOneWidget);
    expect(find.textContaining('24 hours'), findsOneWidget);
    expect(find.textContaining('72 hours'), findsOneWidget);
    expect(find.byKey(const Key('turn-notifications-toggle')), findsNothing);
    expect(find.byKey(const Key('allow-turn-notifications')), findsNothing);
    expect(find.text('Active for this browser or device.'), findsOneWidget);
    expect(repository.upserts, hasLength(1));
  });

  testWidgets(
    'notification permission is requested only from an allow action',
    (tester) async {
      final auth = FakeAuthRepository();
      await auth.login(username: 'alice', password: 'password');
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway()
        ..capabilityValue = const TurnNotificationCapability(
          configured: true,
          supported: true,
          permission: TurnNotificationPermission.prompt,
        )
        ..capabilityAfterRequest = const TurnNotificationCapability(
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
        size: const Size(390, 844),
        authRepository: auth,
        notificationRepository: repository,
        notificationGateway: gateway,
      );

      expect(gateway.requestCalls, 0);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('allow-turn-notifications')),
      );

      await tester.tap(find.byKey(const Key('allow-turn-notifications')));
      await tester.pumpAndSettle();

      expect(gateway.requestCalls, 1);
      expect(repository.upserts, hasLength(1));
      expect(find.text('Active for this browser or device.'), findsOneWidget);
    },
  );

  testWidgets('blocked notifications offer settings help without a toggle', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.denied,
      );
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      notificationGateway: gateway,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('notification-settings-help')),
    );
    await tester.tap(find.byKey(const Key('notification-settings-help')));
    await tester.pumpAndSettle();

    expect(find.text('Allow notifications in settings'), findsOneWidget);
    expect(find.byKey(const Key('turn-notifications-toggle')), findsNothing);
    expect(
      find.byKey(const Key('check-notification-permission')),
      findsOneWidget,
    );
  });

  testWidgets('app resume reconciles permission granted in system settings', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.prompt,
      );
    await pumpApp(
      tester,
      authRepository: auth,
      notificationRepository: repository,
      notificationGateway: gateway,
    );
    expect(repository.upserts, isEmpty);

    gateway
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'ios',
        token: 'settings-token',
      );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(repository.upserts, hasLength(1));
    expect(repository.upserts.single.token, 'settings-token');
  });

  testWidgets('home has three destinations and four play choices', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));

    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Social'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('play-local')), findsOneWidget);
    expect(find.byKey(const Key('find-opponent')), findsOneWidget);
    expect(find.byKey(const Key('create-room')), findsOneWidget);
    expect(find.byKey(const Key('join-by-code')), findsOneWidget);
    expect(find.byKey(const Key('current-games')), findsOneWidget);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Online'), findsNothing);
    expect(find.text('Profile'), findsNothing);
  });

  testWidgets('wide Home keeps each action-card pair the same height', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1200, 900));

    Finder actionCard(Key key) =>
        find.ancestor(of: find.byKey(key), matching: find.byType(Card)).first;

    expect(
      tester.getSize(actionCard(const Key('create-room'))).height,
      tester.getSize(actionCard(const Key('join-by-code'))).height,
    );
  });

  testWidgets('mobile Home keeps primary play actions ahead of metrics', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    await pumpApp(tester, size: const Size(390, 844), authRepository: auth);

    final playLocal = find.byKey(const Key('play-local'));
    final joinByCode = find.byKey(const Key('join-by-code'));
    final metrics = find.byKey(const Key('player-metrics'));
    expect(tester.getBottomRight(playLocal).dy, lessThan(844));
    expect(
      tester.getBottomRight(joinByCode).dy,
      lessThan(tester.getTopLeft(metrics).dy),
    );
  });

  testWidgets('signed-out Social stays accessible with a concise sign-in CTA', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 844));

    await tester.tap(find.text('Social'));
    await tester.pumpAndSettle();

    expect(find.text('Play with friends'), findsOneWidget);
    expect(find.byKey(const Key('social-sign-in')), findsOneWidget);
    expect(find.byKey(const Key('social-search')), findsNothing);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
  });

  testWidgets('signed-in Social exposes privacy-safe friend workflows', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'private_alice', password: 'password');
    const friend = PublicPlayer(
      id: 'friend-1',
      displayName: 'Briar',
      elo: 1312,
    );
    const searchResult = PublicPlayer(
      id: 'search-1',
      displayName: 'Cedar',
      elo: -12,
    );
    const incomingPlayer = PublicPlayer(
      id: 'incoming-1',
      displayName: 'Dahlia',
      elo: 1240,
    );
    const outgoingPlayer = PublicPlayer(
      id: 'outgoing-1',
      displayName: 'Elm',
      elo: 1188,
    );
    final now = DateTime.utc(2026, 8, 14);
    final challengeExpiry = DateTime.utc(2026, 8, 21);
    final social = FakeSocialRepository(
      searchResults: const [searchResult],
      overview: SocialOverview(
        version: 4,
        friends: const [friend],
        incomingFriendRequests: [
          FriendRequest(
            id: 'request-in',
            player: incomingPlayer,
            createdAt: now,
          ),
        ],
        outgoingFriendRequests: [
          FriendRequest(
            id: 'request-out',
            player: outgoingPlayer,
            createdAt: now,
          ),
        ],
        incomingChallenges: [
          PlayerChallenge(
            id: 'challenge-in',
            player: incomingPlayer,
            status: 'pending',
            createdAt: now,
            expiresAt: challengeExpiry,
          ),
        ],
      ),
    );
    await pumpApp(
      tester,
      size: const Size(390, 844),
      authRepository: auth,
      socialRepository: social,
    );

    await tester.tap(find.text('Social'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friend-friend-1')), findsOneWidget);
    expect(
      find.byKey(const Key('incoming-friend-request-request-in')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('outgoing-friend-request-request-out')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('incoming-challenge-challenge-in')),
      findsOneWidget,
    );
    final localExpiry = challengeExpiry.toLocal();
    expect(
      find.textContaining('Expires ${localExpiry.month}/${localExpiry.day}'),
      findsOneWidget,
    );
    expect(find.textContaining('private_alice'), findsNothing);

    expect(find.byKey(const Key('social-discoverability')), findsNothing);

    await tester.enterText(find.byKey(const Key('social-search')), 'Ced');
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-player-search-1')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('add-friend-search-1')));
    await tester.tap(find.byKey(const Key('add-friend-search-1')));
    await tester.pumpAndSettle();
    expect(social.sentFriendRequests, ['search-1']);

    await tester.ensureVisible(find.byKey(const Key('play-friend-friend-1')));
    await tester.tap(find.byKey(const Key('play-friend-friend-1')));
    await tester.pumpAndSettle();
    expect(social.createdChallenges, ['friend-1']);
  });

  testWidgets('accepting a friend challenge opens its rated match', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    const friend = PublicPlayer(
      id: 'friend-1',
      displayName: 'Briar',
      elo: 1288,
    );
    final challenge = PlayerChallenge(
      id: 'challenge-1',
      player: friend,
      status: 'pending',
      createdAt: DateTime.utc(2026, 8, 14),
      expiresAt: DateTime.utc(2026, 8, 21),
    );
    final social = FakeSocialRepository(
      overview: SocialOverview(incomingChallenges: [challenge]),
    )..acceptedMatchId = 'social-match-1';
    final online = FakeOnlineRepository(
      match: _activeOnlineMatch(id: 'social-match-1'),
    );
    await pumpApp(
      tester,
      authRepository: auth,
      socialRepository: social,
      onlineRepository: online,
    );

    await tester.tap(find.text('Social'));
    await tester.pumpAndSettle();
    final accept = find.byKey(const Key('accept-challenge-challenge-1'));
    await tester.ensureVisible(accept);
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(social.acceptedChallenges, ['challenge-1']);
    expect(find.byType(OnlineMatchScreen), findsOneWidget);
    expect(find.text('vs Briar'), findsOneWidget);
    expect(find.textContaining('RATED'), findsOneWidget);
  });

  testWidgets(
    'Home and Settings show authoritative rated metrics and refresh',
    (tester) async {
      final auth = FakeAuthRepository();
      await auth.login(username: 'alice', password: 'password');
      final stats = FakePlayerStatsRepository(
        stats: const PlayerStats(
          elo: -24,
          victories: 6,
          totalGames: 10,
          kills: 42,
          spawns: 73,
          losses: 3,
          draws: 1,
        ),
      );
      await pumpApp(tester, authRepository: auth, playerStatsRepository: stats);

      expect(find.byKey(const Key('player-metrics')), findsOneWidget);
      expect(find.text('-24'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Total kills'), findsOneWidget);
      expect(find.text('73'), findsOneWidget);
      expect(find.text('Total spawns'), findsOneWidget);
      expect(
        find.textContaining('update after every rated move'),
        findsNothing,
      );
      expect(stats.calls, 1);
      final metricsTop = tester
          .getTopLeft(find.byKey(const Key('player-metrics')))
          .dy;
      for (final key in const [
        Key('play-local'),
        Key('find-opponent'),
        Key('create-room'),
        Key('join-by-code'),
      ]) {
        expect(tester.getTopLeft(find.byKey(key)).dy, lessThan(metricsTop));
      }

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('player-metrics')), findsOneWidget);
      expect(stats.calls, 2);
    },
  );

  testWidgets('rated metrics expose a retry and recover from a load failure', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    await auth.login(username: 'alice', password: 'password');
    final stats = FakePlayerStatsRepository()..error = StateError('offline');
    await pumpApp(tester, authRepository: auth, playerStatsRepository: stats);

    expect(find.byKey(const Key('retry-player-metrics')), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsOneWidget);

    stats
      ..error = null
      ..stats = const PlayerStats(
        elo: 1200,
        victories: 0,
        totalGames: 0,
        kills: 0,
        spawns: 0,
        losses: 0,
        draws: 0,
      );
    await tester.tap(find.byKey(const Key('retry-player-metrics')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Your Elo starts at 1200.'), findsNothing);
    expect(find.text('Total spawns'), findsOneWidget);
    expect(stats.calls, 2);
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

    expect(find.text('Online · Rated · Your turn'), findsOneWidget);
    expect(find.text('Online · Rated · Waiting for opponent'), findsOneWidget);
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
    expect(find.text('Online · Rated · Completed'), findsOneWidget);
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

    await tester.tap(find.text('Settings'));
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

    expect(find.text('Online · Rated · Private room waiting'), findsOneWidget);
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
    await tester.ensureVisible(find.byTooltip('Private room actions'));
    await tester.tap(find.byTooltip('Private room actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close private room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-close-private-room')));
    await tester.pumpAndSettle();

    expect(online.closeLobbyCalls, 1);
    expect(find.text('Online · Rated · Private room waiting'), findsNothing);
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
    await tester.tap(find.text('Settings'));
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
    expect(find.text('Local · Unrated · Black to move'), findsOneWidget);
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

OnlineMatch _activeOnlineMatch({required String id}) {
  final state = const engine.GameEngine().initialState();
  return OnlineMatch(
    id: id,
    status: 'active',
    revision: state.revision,
    board: state.board,
    rules: state.rules,
    players: const [
      OnlinePlayer(
        id: 'user-1',
        username: 'private_alice',
        displayName: 'Alice',
        color: engine.Player.black,
      ),
      OnlinePlayer(
        id: 'friend-1',
        username: 'private_briar',
        displayName: 'Briar',
        color: engine.Player.white,
      ),
    ],
    blackPopulation: state.blackPopulation,
    whitePopulation: state.whitePopulation,
    yourColor: engine.Player.black,
    nextPlayer: engine.Player.black,
  );
}
