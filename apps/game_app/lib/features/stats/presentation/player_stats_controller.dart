import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/player_stats.dart';
import '../data/player_stats_repository.dart';

enum PlayerStatsStatus { idle, loading, ready, failed }

class PlayerStatsState {
  const PlayerStatsState({
    this.status = PlayerStatsStatus.idle,
    this.stats,
    this.error,
  });

  final PlayerStatsStatus status;
  final PlayerStats? stats;
  final String? error;
}

class PlayerStatsController extends StateNotifier<PlayerStatsState> {
  PlayerStatsController(this._repository) : super(const PlayerStatsState());

  final PlayerStatsRepository _repository;
  String? _accountId;
  var _requestGeneration = 0;

  void connectAccount(String accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    _requestGeneration++;
    state = const PlayerStatsState();
  }

  Future<void> load({bool force = false}) async {
    if (_accountId == null) {
      disconnectAccount();
      return;
    }
    if (!force &&
        (state.status == PlayerStatsStatus.loading ||
            state.status == PlayerStatsStatus.ready)) {
      return;
    }
    final generation = ++_requestGeneration;
    state = PlayerStatsState(
      status: PlayerStatsStatus.loading,
      stats: state.stats,
    );
    try {
      final stats = await _repository.getMyStats();
      if (generation != _requestGeneration) return;
      state = PlayerStatsState(status: PlayerStatsStatus.ready, stats: stats);
    } catch (error) {
      if (generation != _requestGeneration) return;
      state = PlayerStatsState(
        status: PlayerStatsStatus.failed,
        stats: state.stats,
        error: _message(error),
      );
    }
  }

  Future<void> refresh() => load(force: true);

  void disconnectAccount() {
    if (_accountId == null && state.status == PlayerStatsStatus.idle) return;
    _accountId = null;
    _requestGeneration++;
    state = const PlayerStatsState();
  }
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'Your player stats could not be loaded. Please try again.';
}
