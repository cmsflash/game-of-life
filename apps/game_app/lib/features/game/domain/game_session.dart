import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;

enum LocalGameMode { elimination, turnLimit, populationTarget }

class LocalGameConfig {
  const LocalGameConfig({
    this.mode = LocalGameMode.elimination,
    this.turnLimit = 100,
    this.populationTarget = 50,
    this.blackName = 'Black',
    this.whiteName = 'White',
  });

  final LocalGameMode mode;
  final int turnLimit;
  final int populationTarget;
  final String blackName;
  final String whiteName;

  engine.GameRules get rules => engine.GameRules.standard(
    victory: switch (mode) {
      LocalGameMode.elimination => const engine.EliminationVictory(),
      LocalGameMode.turnLimit => engine.TurnLimitPopulationVictory(turnLimit),
      LocalGameMode.populationTarget => engine.PopulationTargetVictory(
        populationTarget,
      ),
    },
  );

  String get modeLabel => switch (mode) {
    LocalGameMode.elimination => 'Elimination',
    LocalGameMode.turnLimit => '$turnLimit-turn score',
    LocalGameMode.populationTarget => 'First to $populationTarget',
  };

  String nameFor(engine.Player player) => player == engine.Player.black
      ? blackName.trim().isEmpty
            ? 'Black'
            : blackName.trim()
      : whiteName.trim().isEmpty
      ? 'White'
      : whiteName.trim();
}

class LocalGameSession {
  const LocalGameSession({
    required this.config,
    required this.game,
    this.lastMove,
    this.lastBirths = const [],
    this.lastDeaths = const [],
    this.error,
  });

  final LocalGameConfig config;
  final engine.GameState game;
  final engine.Coordinate? lastMove;
  final List<engine.Coordinate> lastBirths;
  final List<engine.Coordinate> lastDeaths;
  final String? error;

  LocalGameSession copyWith({
    engine.GameState? game,
    engine.Coordinate? lastMove,
    List<engine.Coordinate>? lastBirths,
    List<engine.Coordinate>? lastDeaths,
    String? error,
    bool clearError = false,
  }) => LocalGameSession(
    config: config,
    game: game ?? this.game,
    lastMove: lastMove ?? this.lastMove,
    lastBirths: lastBirths ?? this.lastBirths,
    lastDeaths: lastDeaths ?? this.lastDeaths,
    error: clearError ? null : error ?? this.error,
  );
}

class LocalGameController extends StateNotifier<LocalGameSession?> {
  LocalGameController() : super(null);

  static const _engine = engine.GameEngine();

  void start(LocalGameConfig config) {
    state = LocalGameSession(
      config: config,
      game: _engine.initialState(config.rules),
    );
  }

  bool place(int row, int column) {
    final current = state;
    if (current == null || !current.game.isActive) return false;
    try {
      final result = _engine.applyMove(
        current.game,
        engine.GameMove(
          player: current.game.toMove!,
          row: row,
          column: column,
          expectedRevision: current.game.revision,
        ),
      );
      state = current.copyWith(
        game: result.state,
        lastMove: engine.Coordinate(row, column),
        lastBirths: result.delta.evolution.births
            .map((birth) => birth.coordinate)
            .toList(growable: false),
        lastDeaths: result.delta.evolution.deaths
            .map((death) => death.coordinate)
            .toList(growable: false),
        clearError: true,
      );
      return true;
    } on engine.GameRuleViolation catch (error) {
      state = current.copyWith(error: error.message);
      return false;
    }
  }

  void restart() {
    final current = state;
    if (current != null) start(current.config);
  }

  void clear() => state = null;
}
