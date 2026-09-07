import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart' as engine;

import '../../../core/ids.dart';
import '../data/local_game_store.dart';
import '../domain/game_session.dart';
import '../domain/move_preview.dart';

enum LocalGamesLoadStatus { loading, ready, failed }

typedef LocalAiMoveChooser =
    Future<engine.GameMove> Function(
      engine.GameState state, {
      required bool Function() isCancelled,
    });

class LocalGamesState {
  const LocalGamesState({
    this.status = LocalGamesLoadStatus.loading,
    this.games = const [],
    this.selectedGameId,
    this.error,
    this.busyGameIds = const {},
  });

  final LocalGamesLoadStatus status;
  final List<LocalGameSession> games;
  final String? selectedGameId;
  final String? error;
  final Set<String> busyGameIds;

  LocalGameSession? gameById(String id) {
    for (final game in games) {
      if (game.id == id) return game;
    }
    return null;
  }

  LocalGameSession? get selectedGame {
    final selected = selectedGameId;
    if (selected != null) {
      final game = gameById(selected);
      if (game != null) return game;
    }
    return games.firstOrNull;
  }

  List<LocalGameSummary> get summaries =>
      List.unmodifiable(games.map((game) => game.summary));

  LocalGamesState copyWith({
    LocalGamesLoadStatus? status,
    List<LocalGameSession>? games,
    String? selectedGameId,
    String? error,
    Set<String>? busyGameIds,
    bool clearSelectedGame = false,
    bool clearError = false,
  }) => LocalGamesState(
    status: status ?? this.status,
    games: games ?? this.games,
    selectedGameId: clearSelectedGame
        ? null
        : selectedGameId ?? this.selectedGameId,
    error: clearError ? null : error ?? this.error,
    busyGameIds: busyGameIds ?? this.busyGameIds,
  );
}

class LocalGamesController extends StateNotifier<LocalGamesState> {
  LocalGamesController(
    this._store, {
    String Function()? idFactory,
    DateTime Function()? clock,
    LocalAiMoveChooser? level29MoveChooser,
  }) : _idFactory = idFactory ?? newRequestId,
       _clock = clock ?? DateTime.now,
       _level29MoveChooser = level29MoveChooser ?? _chooseLevel29Move,
       super(const LocalGamesState());

  static const _engine = engine.GameEngine();

  final LocalGameStore _store;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  final LocalAiMoveChooser _level29MoveChooser;
  Future<void>? _loadFuture;
  Future<void> _mutationTail = Future.value();
  final _pendingOperations = <String, _LocalGameOperation>{};

  Future<void> load() => _loadFuture ??= _restore();

  Future<void> retryLoad() {
    if (state.status != LocalGamesLoadStatus.failed) return load();
    _loadFuture = null;
    state = const LocalGamesState();
    return load();
  }

  Future<void> _restore() async {
    try {
      final games = _sorted(await _store.readGames());
      if (!mounted) return;
      state = LocalGamesState(status: LocalGamesLoadStatus.ready, games: games);
    } catch (error) {
      if (!mounted) return;
      state = LocalGamesState(
        status: LocalGamesLoadStatus.failed,
        error: 'Could not load local games: $error',
      );
    }
  }

  Future<LocalGameSession> create(
    LocalGameConfig config, {
    String? title,
    String? opponentLabel,
  }) async {
    await load();
    if (state.status != LocalGamesLoadStatus.ready) {
      throw StateError(
        'Saved local games must be loaded before creating a game',
      );
    }
    return _enqueueMutation(() async {
      final now = _clock().toUtc();
      final blackName = config.nameFor(engine.Player.black);
      final whiteName = config.nameFor(engine.Player.white);
      var game = LocalGameSession(
        id: _uniqueId(),
        title: _label(title, '$blackName vs $whiteName'),
        opponentLabel: _label(opponentLabel, whiteName),
        createdAt: now,
        updatedAt: now,
        config: config,
        game: _engine.initialState(config.rules),
      );
      game = await _autoAdvanceSingleAi(
        game,
        updatedAt: now,
        isCancelled: () => !mounted,
      );
      if (!mounted) throw const _LocalGameOperationCancelled();
      final games = _sorted([game, ...state.games]);
      await _write(games);
      if (!mounted) throw const _LocalGameOperationCancelled();
      state = state.copyWith(
        status: LocalGamesLoadStatus.ready,
        games: games,
        selectedGameId: game.id,
        clearError: true,
      );
      return game;
    });
  }

  void select(String id) {
    if (state.gameById(id) == null) return;
    state = state.copyWith(selectedGameId: id, clearError: true);
  }

  bool consider(String id, int row, int column) {
    final current = state.gameById(id);
    if (current == null || !current.game.isActive) return false;
    if (current.config.isAi(current.game.toMove!)) {
      _replace(
        current.copyWith(
          error: current.config.isAiVsAi
              ? 'Use Next step to advance this AI match.'
              : 'The AI is choosing this turn.',
        ),
        selectedGameId: id,
      );
      return false;
    }
    if (_pendingOperations.containsKey(id)) {
      _replace(
        current.copyWith(error: 'Saving this game. Try again in a moment.'),
        selectedGameId: id,
      );
      return false;
    }
    try {
      final preview = MovePreview.simulate(
        current.game,
        engine.Coordinate(row, column),
      );
      _replace(
        current.copyWith(preview: preview, clearError: true),
        selectedGameId: id,
      );
      return true;
    } on engine.GameRuleViolation catch (error) {
      _replace(current.copyWith(error: error.message), selectedGameId: id);
      return false;
    }
  }

  Future<bool> commit(String id) {
    final current = state.gameById(id);
    final preview = current?.preview;
    if (current == null || preview == null || !current.game.isActive) {
      return Future.value(false);
    }
    final operation = _beginOperation(
      id,
      canCancel: !current.config.isAiVsAi && current.config.hasAi,
    );
    if (operation == null) return Future.value(false);
    bool isCancelled() => !_isCurrentOperation(id, operation, current.game);
    final updatedAt = _clock().toUtc();
    return _enqueueMutation(() async {
      try {
        if (isCancelled()) return false;
        var next = current.copyWith(
          updatedAt: updatedAt,
          game: preview.turn.state,
          lastMove: preview.coordinate,
          lastBirths: preview.births,
          lastDeaths: preview.deaths,
          clearPreview: true,
          clearError: true,
        );
        next = await _autoAdvanceSingleAi(
          next,
          updatedAt: updatedAt,
          isCancelled: isCancelled,
        );
        if (isCancelled()) return false;
        operation.canCancel = false;
        await _write(_withReplacement(next, sort: true));
        if (!mounted) return false;
        _replace(next, selectedGameId: id, sort: true);
        return true;
      } catch (_) {
        if (isCancelled()) return false;
        rethrow;
      } finally {
        _finishOperation(id, operation);
      }
    });
  }

  void cancelPreview(String id) {
    final current = state.gameById(id);
    if (current != null &&
        current.preview != null &&
        !_pendingOperations.containsKey(id)) {
      _replace(
        current.copyWith(clearPreview: true, clearError: true),
        selectedGameId: id,
      );
    }
  }

  Future<bool> advanceAi(String id) {
    final current = state.gameById(id);
    if (current == null ||
        !current.game.isActive ||
        !current.config.isAi(current.game.toMove!)) {
      return Future.value(false);
    }
    final operation = _beginOperation(id, canCancel: true);
    if (operation == null) return Future.value(false);
    bool isCancelled() => !_isCurrentOperation(id, operation, current.game);
    final updatedAt = _clock().toUtc();
    return _enqueueMutation(() async {
      try {
        if (isCancelled()) return false;
        final next = await _advanceAiTurn(
          current,
          updatedAt: updatedAt,
          isCancelled: isCancelled,
        );
        if (isCancelled()) return false;
        operation.canCancel = false;
        await _write(_withReplacement(next, sort: true));
        if (!mounted) return false;
        _replace(next, selectedGameId: id, sort: true);
        return true;
      } catch (_) {
        if (isCancelled()) return false;
        rethrow;
      } finally {
        _finishOperation(id, operation);
      }
    });
  }

  Future<bool> restart(String id) {
    final current = state.gameById(id);
    if (current == null) return Future.value(false);
    final operation = _beginOperation(
      id,
      cancelSearch: true,
      canCancel: !current.config.isAiVsAi && current.config.hasAi,
    );
    if (operation == null) return Future.value(false);
    bool isCancelled() => !_isCurrentOperation(id, operation, current.game);
    final updatedAt = _clock().toUtc();
    return _enqueueMutation(() async {
      try {
        if (isCancelled()) return false;
        var next = current.copyWith(
          updatedAt: updatedAt,
          game: _engine.initialState(current.config.rules),
          lastBirths: const [],
          lastDeaths: const [],
          clearLastMove: true,
          clearPreview: true,
          clearError: true,
        );
        next = await _autoAdvanceSingleAi(
          next,
          updatedAt: updatedAt,
          isCancelled: isCancelled,
        );
        if (isCancelled()) return false;
        operation.canCancel = false;
        await _write(_withReplacement(next, sort: true));
        if (!mounted) return false;
        _replace(next, selectedGameId: id, sort: true);
        return true;
      } catch (_) {
        if (isCancelled()) return false;
        rethrow;
      } finally {
        _finishOperation(id, operation);
      }
    });
  }

  Future<bool> delete(String id) {
    if (state.gameById(id) == null) return Future.value(false);
    final operation = _beginOperation(id, cancelSearch: true);
    if (operation == null) return Future.value(false);
    return _enqueueMutation(() async {
      try {
        if (!mounted) return false;
        final games = state.games.where((game) => game.id != id).toList();
        await _write(games);
        if (!mounted) return false;
        state = state.copyWith(
          games: games,
          clearSelectedGame: state.selectedGameId == id,
          clearError: true,
        );
        return true;
      } finally {
        _finishOperation(id, operation);
      }
    });
  }

  Future<LocalGameSession> _autoAdvanceSingleAi(
    LocalGameSession session, {
    required DateTime updatedAt,
    required bool Function() isCancelled,
  }) async {
    if (session.config.isAiVsAi ||
        !session.game.isActive ||
        !session.config.isAi(session.game.toMove!)) {
      return session;
    }
    return _advanceAiTurn(
      session,
      updatedAt: updatedAt,
      isCancelled: isCancelled,
    );
  }

  Future<LocalGameSession> _advanceAiTurn(
    LocalGameSession session, {
    required DateTime updatedAt,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) throw const _LocalGameOperationCancelled();
    final participant = session.config.participantFor(session.game.toMove!);
    final move = switch (participant) {
      LocalParticipantType.human => throw StateError(
        'cannot advance an AI turn for a human participant',
      ),
      LocalParticipantType.aiLevel1 =>
        const OneStepMaxDifferenceAgent().chooseMove(session.game).move,
      LocalParticipantType.aiLevel2 =>
        const TwoStepMaxDifferenceAgent().chooseMove(session.game).move,
      LocalParticipantType.aiLevel29 => await _level29MoveChooser(
        session.game,
        isCancelled: isCancelled,
      ),
    };
    if (isCancelled()) throw const _LocalGameOperationCancelled();
    final turn = _engine.applyMove(session.game, move);
    return session.copyWith(
      updatedAt: updatedAt,
      game: turn.state,
      lastMove: move.coordinate,
      lastBirths: turn.delta.evolution.births
          .map((birth) => birth.coordinate)
          .toList(growable: false),
      lastDeaths: turn.delta.evolution.deaths
          .map((death) => death.coordinate)
          .toList(growable: false),
      clearPreview: true,
      clearError: true,
    );
  }

  String _uniqueId() {
    for (var attempt = 0; attempt < 10; attempt++) {
      final candidate = _idFactory();
      if (candidate.trim().isNotEmpty && state.gameById(candidate) == null) {
        return candidate;
      }
    }
    throw StateError('Could not create a unique local game ID');
  }

  void _replace(
    LocalGameSession next, {
    String? selectedGameId,
    bool sort = false,
  }) {
    state = state.copyWith(
      games: _withReplacement(next, sort: sort),
      selectedGameId: selectedGameId,
      clearError: true,
    );
  }

  List<LocalGameSession> _withReplacement(
    LocalGameSession next, {
    required bool sort,
  }) {
    final games = [
      for (final game in state.games)
        if (game.id == next.id) next else game,
    ];
    return sort ? _sorted(games) : List.unmodifiable(games);
  }

  Future<void> _write(List<LocalGameSession> games) async {
    try {
      await _store.writeGames(games);
    } catch (error) {
      if (mounted) {
        state = state.copyWith(error: 'Could not save local games: $error');
      }
      rethrow;
    }
  }

  static Future<engine.GameMove> _chooseLevel29Move(
    engine.GameState state, {
    required bool Function() isCancelled,
  }) async => (await IterativeDeepeningAgent().chooseMoveAsync(
    state,
    isCancelled: isCancelled,
  )).move;

  _LocalGameOperation? _beginOperation(
    String id, {
    bool canCancel = false,
    bool cancelSearch = false,
  }) {
    final pending = _pendingOperations[id];
    if (pending != null) {
      if (!cancelSearch || !pending.canCancel) return null;
      pending.cancelled = true;
    }
    final operation = _LocalGameOperation(canCancel: canCancel);
    _pendingOperations[id] = operation;
    state = state.copyWith(
      busyGameIds: Set.unmodifiable(_pendingOperations.keys),
    );
    return operation;
  }

  bool _isCurrentOperation(
    String id,
    _LocalGameOperation operation,
    engine.GameState expectedGame,
  ) =>
      mounted &&
      !operation.cancelled &&
      identical(_pendingOperations[id], operation) &&
      identical(state.gameById(id)?.game, expectedGame);

  void _finishOperation(String id, _LocalGameOperation operation) {
    if (!identical(_pendingOperations[id], operation)) return;
    _pendingOperations.remove(id);
    if (mounted) {
      state = state.copyWith(
        busyGameIds: Set.unmodifiable(_pendingOperations.keys),
      );
    }
  }

  @override
  void dispose() {
    for (final operation in _pendingOperations.values) {
      operation.cancelled = true;
    }
    _pendingOperations.clear();
    super.dispose();
  }

  Future<T> _enqueueMutation<T>(Future<T> Function() mutation) {
    final result = _mutationTail.then((_) => mutation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static List<LocalGameSession> _sorted(Iterable<LocalGameSession> games) {
    final sorted = List<LocalGameSession>.of(games)
      ..sort((a, b) {
        final updated = b.updatedAt.compareTo(a.updatedAt);
        return updated != 0 ? updated : a.id.compareTo(b.id);
      });
    return List.unmodifiable(sorted);
  }

  static String _label(String? value, String fallback) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? fallback : normalized;
  }
}

class _LocalGameOperation {
  _LocalGameOperation({required this.canCancel});

  bool canCancel;
  bool cancelled = false;
}

class _LocalGameOperationCancelled implements Exception {
  const _LocalGameOperationCancelled();
}
