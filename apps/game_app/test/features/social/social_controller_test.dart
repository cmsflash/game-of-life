import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/social/data/social_models.dart';
import 'package:game_of_life/features/social/data/social_repository.dart';
import 'package:game_of_life/features/social/presentation/social_controller.dart';

void main() {
  test(
    'account switch ignores a late snapshot from the previous player',
    () async {
      final repository = ScriptedSocialRepository();
      final first = Completer<SocialOverview>();
      final second = Completer<SocialOverview>();
      repository.overviews
        ..add(first.future)
        ..add(second.future);
      final controller = SocialController(repository)..connectAccount('a');

      final firstLoad = controller.load();
      controller.connectAccount('b');
      final secondLoad = controller.load();
      second.complete(const SocialOverview(version: 2, friends: [_briar]));
      await secondLoad;
      first.complete(const SocialOverview(version: 1, friends: [_cedar]));
      await firstLoad;

      expect(controller.state.friends.single.displayName, 'Briar');
      controller.dispose();
    },
  );

  test('shorter search input cancels an older in-flight result', () async {
    final repository = ScriptedSocialRepository();
    final search = Completer<List<PublicPlayer>>();
    repository.searches.add(search.future);
    final controller = SocialController(repository)..connectAccount('a');

    final pending = controller.search('abc');
    controller.cancelSearch(); // The user has edited the field back to "ab".
    search.complete(const [_cedar]);
    await pending;

    expect(controller.state.searchResults, isEmpty);
    expect(controller.state.searchQuery, isEmpty);
    expect(controller.state.searching, isFalse);
    controller.dispose();
  });

  test(
    'a slower old refresh cannot replace a newer canonical version',
    () async {
      final repository = ScriptedSocialRepository();
      final old = Completer<SocialOverview>();
      final fresh = Completer<SocialOverview>();
      repository.overviews
        ..add(old.future)
        ..add(fresh.future);
      final controller = SocialController(repository)..connectAccount('a');

      final oldLoad = controller.load();
      final freshLoad = controller.load(force: true);
      fresh.complete(const SocialOverview(version: 5, friends: [_briar]));
      await freshLoad;
      old.complete(const SocialOverview(version: 4, friends: [_cedar]));
      await oldLoad;

      expect(controller.state.snapshotVersion, 5);
      expect(controller.state.friends.single, same(_briar));
      controller.dispose();
    },
  );

  test(
    'discoverability is off by default and uses canonical toggle result',
    () async {
      final repository = ScriptedSocialRepository()
        ..discoverability.add(
          Future.value(
            const DiscoverabilityResult(discoverable: true, version: 3),
          ),
        );
      final controller = SocialController(repository)..connectAccount('a');

      expect(controller.state.discoverable, isFalse);
      await controller.setDiscoverable(true);

      expect(controller.state.discoverable, isTrue);
      expect(controller.state.snapshotVersion, 3);
      expect(repository.discoverabilityValues, [true]);
      controller.dispose();
    },
  );

  test(
    'discoverability can be disabled without removing Social data',
    () async {
      final repository = ScriptedSocialRepository();
      repository.discoverability
        ..add(
          Future.value(
            const DiscoverabilityResult(discoverable: true, version: 3),
          ),
        )
        ..add(
          Future.value(
            const DiscoverabilityResult(discoverable: false, version: 4),
          ),
        );
      final controller = SocialController(repository)..connectAccount('a');

      await controller.setDiscoverable(true);
      await controller.setDiscoverable(false);

      expect(controller.state.discoverable, isFalse);
      expect(controller.state.snapshotVersion, 4);
      expect(repository.discoverabilityValues, [true, false]);
      expect(
        controller.state.notice,
        contains('Existing friends are unchanged'),
      );
      controller.dispose();
    },
  );

  test(
    'failed discoverability toggle rolls back to the canonical value',
    () async {
      final repository = ScriptedSocialRepository()
        ..discoverability.add(
          Future.error(
            const ApiException(
              statusCode: 503,
              code: 'temporarilyUnavailable',
              message: 'Try later.',
            ),
          ),
        );
      final controller = SocialController(repository)..connectAccount('a');

      await controller.setDiscoverable(true);

      expect(controller.state.discoverable, isFalse);
      expect(controller.state.error, 'Try later.');
      controller.dispose();
    },
  );

  test('account switch ignores a late discoverability response', () async {
    final repository = ScriptedSocialRepository();
    final toggle = Completer<DiscoverabilityResult>();
    repository.discoverability.add(toggle.future);
    final controller = SocialController(repository)..connectAccount('a');

    final pending = controller.setDiscoverable(true);
    controller.connectAccount('b');
    toggle.complete(
      const DiscoverabilityResult(discoverable: true, version: 2),
    );
    await pending;

    expect(controller.state.discoverable, isFalse);
    expect(controller.state.status, SocialStatus.idle);
    controller.dispose();
  });

  test(
    'accepted match opens even when the following snapshot reload fails',
    () async {
      final repository = ScriptedSocialRepository()
        ..accepts.add(Future.value('match-1'))
        ..nextOverviewError = StateError('offline');
      final controller = SocialController(repository)..connectAccount('a');

      await controller.acceptChallenge(_challenge);

      expect(controller.state.matchId, 'match-1');
      expect(controller.state.error, isNull);
      controller.dispose();
    },
  );

  test(
    'timeout after commit retries idempotent accept and recovers match ID',
    () async {
      final repository = ScriptedSocialRepository();
      repository.accepts
        ..add(
          Future.error(
            const ApiException(
              statusCode: 0,
              code: 'requestTimeout',
              message: 'Timed out.',
            ),
          ),
        )
        ..add(Future.value('match-recovered'));
      final controller = SocialController(repository)..connectAccount('a');

      await controller.acceptChallenge(_challenge);

      expect(repository.acceptCalls, 2);
      expect(controller.state.matchId, 'match-recovered');
      controller.dispose();
    },
  );

  test(
    'successful mutation is not reported as failure when reload fails',
    () async {
      final repository = ScriptedSocialRepository()
        ..nextOverviewError = StateError('offline');
      final controller = SocialController(repository)..connectAccount('a');

      await controller.createChallenge(_briar);

      expect(controller.state.error, isNull);
      expect(controller.state.notice, contains('Rated challenge sent'));
      expect(controller.state.notice, contains('Refresh to confirm'));
      controller.dispose();
    },
  );

  test(
    'disconnect clears cached private state and ignores late search',
    () async {
      final repository = ScriptedSocialRepository();
      final search = Completer<List<PublicPlayer>>();
      repository.searches.add(search.future);
      final controller = SocialController(repository)..connectAccount('a');

      final pending = controller.search('ced');
      controller.disconnectAccount();
      search.complete(const [_cedar]);
      await pending;

      expect(controller.state.status, SocialStatus.idle);
      expect(controller.state.searchResults, isEmpty);
      expect(controller.state.friends, isEmpty);
      controller.dispose();
    },
  );
}

const _briar = PublicPlayer(id: 'briar', displayName: 'Briar', elo: 1300);
const _cedar = PublicPlayer(id: 'cedar', displayName: 'Cedar', elo: -12);
final _challenge = PlayerChallenge(
  id: 'challenge-1',
  player: _briar,
  status: 'pending',
  createdAt: DateTime.utc(2026, 8, 14),
  expiresAt: DateTime.utc(2026, 8, 21),
);

class ScriptedSocialRepository implements SocialRepository {
  final overviews = Queue<Future<SocialOverview>>();
  final searches = Queue<Future<List<PublicPlayer>>>();
  final accepts = Queue<Future<String>>();
  final discoverability = Queue<Future<DiscoverabilityResult>>();
  final discoverabilityValues = <bool>[];
  var acceptCalls = 0;
  Object? nextOverviewError;

  @override
  Future<SocialOverview> getOverview() {
    final error = nextOverviewError;
    if (error != null) {
      nextOverviewError = null;
      return Future.sync(() => throw error);
    }
    return overviews.isEmpty
        ? Future.value(const SocialOverview())
        : overviews.removeFirst();
  }

  @override
  Future<List<PublicPlayer>> searchPlayers(String query) =>
      searches.isEmpty ? Future.value(const []) : searches.removeFirst();

  @override
  Future<String> acceptChallenge(String challengeId) {
    acceptCalls++;
    return accepts.isEmpty
        ? Future.value('match-default')
        : accepts.removeFirst();
  }

  @override
  Future<DiscoverabilityResult> setDiscoverable(bool value) {
    discoverabilityValues.add(value);
    return discoverability.isEmpty
        ? Future.value(DiscoverabilityResult(discoverable: value, version: 1))
        : discoverability.removeFirst();
  }

  @override
  Future<void> acceptFriendRequest(String requestId) async {}

  @override
  Future<void> createChallenge(String opponentId) async {}

  @override
  Future<void> removeChallenge(String challengeId) async {}

  @override
  Future<void> removeFriendRequest(String requestId) async {}

  @override
  Future<void> sendFriendRequest(String playerId) async {}

  @override
  Future<void> unfriend(String playerId) async {}
}
