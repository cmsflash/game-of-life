import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/social_models.dart';
import '../data/social_repository.dart';

enum SocialStatus { idle, loading, ready, failed }

class SocialState {
  const SocialState({
    this.status = SocialStatus.idle,
    this.friends = const [],
    this.incomingFriendRequests = const [],
    this.outgoingFriendRequests = const [],
    this.incomingChallenges = const [],
    this.outgoingChallenges = const [],
    this.searchResults = const [],
    this.searchQuery = '',
    this.searching = false,
    this.actionId,
    this.error,
    this.notice,
    this.matchId,
    this.snapshotVersion = 0,
    this.discoverable = false,
  });

  final SocialStatus status;
  final List<PublicPlayer> friends;
  final List<FriendRequest> incomingFriendRequests;
  final List<FriendRequest> outgoingFriendRequests;
  final List<PlayerChallenge> incomingChallenges;
  final List<PlayerChallenge> outgoingChallenges;
  final List<PublicPlayer> searchResults;
  final String searchQuery;
  final bool searching;
  final String? actionId;
  final String? error;
  final String? notice;
  final String? matchId;
  final int snapshotVersion;
  final bool discoverable;

  bool get hasOverviewData =>
      friends.isNotEmpty ||
      incomingFriendRequests.isNotEmpty ||
      outgoingFriendRequests.isNotEmpty ||
      incomingChallenges.isNotEmpty ||
      outgoingChallenges.isNotEmpty;

  SocialState copyWith({
    SocialStatus? status,
    List<PublicPlayer>? friends,
    List<FriendRequest>? incomingFriendRequests,
    List<FriendRequest>? outgoingFriendRequests,
    List<PlayerChallenge>? incomingChallenges,
    List<PlayerChallenge>? outgoingChallenges,
    List<PublicPlayer>? searchResults,
    String? searchQuery,
    bool? searching,
    String? actionId,
    String? error,
    String? notice,
    String? matchId,
    int? snapshotVersion,
    bool? discoverable,
    bool clearAction = false,
    bool clearError = false,
    bool clearNotice = false,
    bool clearMatch = false,
  }) => SocialState(
    status: status ?? this.status,
    friends: friends ?? this.friends,
    incomingFriendRequests:
        incomingFriendRequests ?? this.incomingFriendRequests,
    outgoingFriendRequests:
        outgoingFriendRequests ?? this.outgoingFriendRequests,
    incomingChallenges: incomingChallenges ?? this.incomingChallenges,
    outgoingChallenges: outgoingChallenges ?? this.outgoingChallenges,
    searchResults: searchResults ?? this.searchResults,
    searchQuery: searchQuery ?? this.searchQuery,
    searching: searching ?? this.searching,
    actionId: clearAction ? null : actionId ?? this.actionId,
    error: clearError ? null : error ?? this.error,
    notice: clearNotice ? null : notice ?? this.notice,
    matchId: clearMatch ? null : matchId ?? this.matchId,
    snapshotVersion: snapshotVersion ?? this.snapshotVersion,
    discoverable: discoverable ?? this.discoverable,
  );
}

class SocialController extends StateNotifier<SocialState> {
  SocialController(this._repository) : super(const SocialState());

  final SocialRepository _repository;
  String? _accountId;
  var _generation = 0;
  var _searchGeneration = 0;
  var _overviewRequest = 0;

  void connectAccount(String accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    _generation++;
    _searchGeneration++;
    _overviewRequest++;
    state = const SocialState();
  }

  Future<void> load({bool force = false}) async {
    if (_accountId == null) {
      disconnectAccount();
      return;
    }
    if (!force &&
        (state.status == SocialStatus.loading ||
            state.status == SocialStatus.ready)) {
      return;
    }
    final generation = _generation;
    final request = ++_overviewRequest;
    state = state.copyWith(
      status: SocialStatus.loading,
      clearError: true,
      clearNotice: true,
    );
    try {
      final overview = await _repository.getOverview();
      if (!_isCurrent(generation) || request != _overviewRequest) return;
      _applyOverview(overview);
    } catch (error) {
      if (!_isCurrent(generation) || request != _overviewRequest) return;
      state = state.copyWith(
        status: state.hasOverviewData
            ? SocialStatus.ready
            : SocialStatus.failed,
        error: _message(error),
      );
    }
  }

  Future<void> refresh() => load(force: true);

  Future<void> setDiscoverable(bool discoverable) async {
    if (state.actionId != null || _accountId == null) return;
    final generation = _generation;
    state = state.copyWith(
      actionId: 'discoverability',
      clearError: true,
      clearNotice: true,
    );
    try {
      final result = await _repository.setDiscoverable(discoverable);
      if (!_isCurrent(generation)) return;
      if (result.version < state.snapshotVersion) {
        state = state.copyWith(clearAction: true);
        await refresh();
        return;
      }
      state = state.copyWith(
        discoverable: result.discoverable,
        snapshotVersion: result.version,
        clearAction: true,
        notice: result.discoverable
            ? 'You now appear in signed-in player search.'
            : 'You are hidden from player search. Existing friends are unchanged.',
      );
      try {
        await _reloadOverview(generation);
      } catch (_) {
        // The canonical toggle result is already safe to display.
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(clearAction: true, error: _message(error));
    }
  }

  void cancelSearch() {
    _searchGeneration++;
    state = state.copyWith(
      searchQuery: '',
      searchResults: const [],
      searching: false,
      clearError: true,
      clearNotice: true,
    );
  }

  Future<void> search(String query) async {
    final normalized = query.trim();
    final generation = _generation;
    final searchGeneration = ++_searchGeneration;
    if (_accountId == null) return;
    state = state.copyWith(clearError: true, clearNotice: true);
    if (normalized.isEmpty) {
      state = state.copyWith(
        searchQuery: '',
        searchResults: const [],
        searching: false,
      );
      return;
    }
    if (normalized.length < 3 || normalized.length > 48) {
      state = state.copyWith(
        searchQuery: normalized,
        searchResults: const [],
        searching: false,
        error: 'Enter 3 to 48 characters of a public display name.',
      );
      return;
    }
    state = state.copyWith(searchQuery: normalized, searching: true);
    try {
      final results = await _repository.searchPlayers(normalized);
      if (!_isCurrent(generation) || searchGeneration != _searchGeneration) {
        return;
      }
      state = state.copyWith(searchResults: results, searching: false);
    } catch (error) {
      if (!_isCurrent(generation) || searchGeneration != _searchGeneration) {
        return;
      }
      state = state.copyWith(searching: false, error: _message(error));
    }
  }

  Future<void> sendFriendRequest(PublicPlayer player) => _runAction(
    'friend-${player.id}',
    () => _repository.sendFriendRequest(player.id),
    'Friend request sent to ${player.displayName}.',
  );

  Future<void> acceptFriendRequest(FriendRequest request) => _runAction(
    'friend-request-${request.id}',
    () => _repository.acceptFriendRequest(request.id),
    'You and ${request.player.displayName} are now friends.',
  );

  Future<void> declineFriendRequest(FriendRequest request) => _runAction(
    'friend-request-${request.id}',
    () => _repository.removeFriendRequest(request.id),
    'Friend request declined.',
  );

  Future<void> cancelFriendRequest(FriendRequest request) => _runAction(
    'friend-request-${request.id}',
    () => _repository.removeFriendRequest(request.id),
    'Friend request cancelled.',
  );

  Future<void> unfriend(PublicPlayer player) => _runAction(
    'friend-${player.id}',
    () => _repository.unfriend(player.id),
    '${player.displayName} was removed from your friends.',
  );

  Future<void> createChallenge(PublicPlayer player) => _runAction(
    'friend-${player.id}',
    () => _repository.createChallenge(player.id),
    'Rated challenge sent to ${player.displayName}.',
  );

  Future<void> acceptChallenge(PlayerChallenge challenge) async {
    if (state.actionId != null || _accountId == null) return;
    final generation = _generation;
    state = state.copyWith(
      actionId: 'challenge-${challenge.id}',
      clearError: true,
      clearNotice: true,
    );
    try {
      final matchId = await _repository.acceptChallenge(challenge.id);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        clearAction: true,
        notice: 'Challenge accepted. Opening your rated match…',
        matchId: matchId,
      );
      try {
        await _reloadOverview(generation);
      } catch (_) {
        // Opening the authoritative match must not depend on list refresh.
      }
    } on ApiException catch (error) {
      if (!_isCurrent(generation)) return;
      final recoveredMatchId = error.details?['matchId'] as String?;
      if (error.statusCode == 409 && recoveredMatchId?.isNotEmpty == true) {
        _openRecoveredMatch(recoveredMatchId!);
        return;
      }
      if (_isUncertain(error)) {
        final retryMatchId = await _retryAcceptedChallenge(
          challenge.id,
          generation,
        );
        if (retryMatchId != null) {
          _openRecoveredMatch(retryMatchId);
          return;
        }
      }
      await _recoverAfterFailure(generation, error);
    } catch (error) {
      if (!_isCurrent(generation)) return;
      await _recoverAfterFailure(generation, error);
    }
  }

  Future<void> declineChallenge(PlayerChallenge challenge) => _runAction(
    'challenge-${challenge.id}',
    () => _repository.removeChallenge(challenge.id),
    'Challenge declined.',
  );

  Future<void> cancelChallenge(PlayerChallenge challenge) => _runAction(
    'challenge-${challenge.id}',
    () => _repository.removeChallenge(challenge.id),
    'Challenge cancelled.',
  );

  void acknowledgeMatch() => state = state.copyWith(clearMatch: true);

  void clearMessages() =>
      state = state.copyWith(clearError: true, clearNotice: true);

  void disconnectAccount() {
    if (_accountId == null && state.status == SocialStatus.idle) return;
    _accountId = null;
    _generation++;
    _searchGeneration++;
    _overviewRequest++;
    state = const SocialState();
  }

  Future<void> _runAction(
    String actionId,
    Future<void> Function() action,
    String notice,
  ) async {
    if (state.actionId != null || _accountId == null) return;
    final generation = _generation;
    state = state.copyWith(
      actionId: actionId,
      clearError: true,
      clearNotice: true,
    );
    try {
      await action();
      if (!_isCurrent(generation)) return;
      try {
        await _reloadOverview(generation);
        if (!_isCurrent(generation)) return;
        state = state.copyWith(clearAction: true, notice: notice);
      } catch (_) {
        if (!_isCurrent(generation)) return;
        state = state.copyWith(
          clearAction: true,
          notice: '$notice Refresh to confirm the latest list.',
        );
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      await _recoverAfterFailure(generation, error);
    }
  }

  Future<void> _recoverAfterFailure(int generation, Object error) async {
    try {
      await _reloadOverview(generation);
    } catch (_) {
      // Preserve the last canonical snapshot when recovery cannot be loaded.
    }
    if (!_isCurrent(generation)) return;
    state = state.copyWith(clearAction: true, error: _message(error));
  }

  Future<String?> _retryAcceptedChallenge(
    String challengeId,
    int generation,
  ) async {
    try {
      final matchId = await _repository.acceptChallenge(challengeId);
      return _isCurrent(generation) ? matchId : null;
    } on ApiException catch (error) {
      if (!_isCurrent(generation)) return null;
      final matchId = error.details?['matchId'] as String?;
      return error.statusCode == 409 && matchId?.isNotEmpty == true
          ? matchId
          : null;
    } catch (_) {
      return null;
    }
  }

  void _openRecoveredMatch(String matchId) {
    state = state.copyWith(
      clearAction: true,
      notice: 'Challenge accepted. Opening your rated match…',
      matchId: matchId,
    );
  }

  Future<void> _reloadOverview(int generation) async {
    final request = ++_overviewRequest;
    final overview = await _repository.getOverview();
    if (!_isCurrent(generation) || request != _overviewRequest) return;
    _applyOverview(overview, preserveAction: true);
  }

  void _applyOverview(SocialOverview overview, {bool preserveAction = false}) {
    if (overview.version < state.snapshotVersion) return;
    state = state.copyWith(
      status: SocialStatus.ready,
      friends: overview.friends,
      incomingFriendRequests: overview.incomingFriendRequests,
      outgoingFriendRequests: overview.outgoingFriendRequests,
      incomingChallenges: overview.incomingChallenges,
      outgoingChallenges: overview.outgoingChallenges,
      clearAction: !preserveAction,
      clearError: true,
      snapshotVersion: overview.version,
      discoverable: overview.discoverable,
    );
  }

  bool _isCurrent(int generation) =>
      _accountId != null && generation == _generation;
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'Social could not be updated. Check your connection and try again.';
}

bool _isUncertain(ApiException error) =>
    error.statusCode == 0 || error.statusCode >= 500;
