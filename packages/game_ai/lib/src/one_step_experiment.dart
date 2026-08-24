import 'package:game_engine/game_engine.dart';

import 'match_runner.dart';
import 'one_step_greedy_agent.dart';

/// One reproducible trial from a pure-strategy matchup.
final class OneStepTrialResult {
  const OneStepTrialResult({
    required this.trial,
    required this.blackTieBreakSeed,
    required this.whiteTieBreakSeed,
    required this.match,
  });

  final int trial;
  final int blackTieBreakSeed;
  final int whiteTieBreakSeed;
  final AiMatchResult match;

  Map<String, Object?> toJson() => {
    'trial': trial,
    'blackTieBreakSeed': blackTieBreakSeed,
    'whiteTieBreakSeed': whiteTieBreakSeed,
    'winner': match.finalState.outcome?.winner?.name,
    'outcomeReason': match.finalState.outcome?.reason.name,
    'plies': match.finalState.ply - match.initialState.ply,
    'truncated': match.truncated,
    'blackPopulation': match.finalState.blackPopulation,
    'whitePopulation': match.finalState.whitePopulation,
    'finalStateHash': match.finalState.stateHash,
  };
}

/// Aggregate win-rate measurements for one ordered Black/White pairing.
final class OneStepMatchupResult {
  OneStepMatchupResult({
    required this.blackStrategy,
    required this.whiteStrategy,
    required Iterable<OneStepTrialResult> trials,
  }) : trials = List<OneStepTrialResult>.unmodifiable(trials);

  final OneStepGreedyStrategy blackStrategy;
  final OneStepGreedyStrategy whiteStrategy;
  final List<OneStepTrialResult> trials;

  int get games => trials.length;
  int get blackWins => _wins(Player.black);
  int get whiteWins => _wins(Player.white);
  int get draws => trials
      .where(
        (trial) => trial.match.finalState.outcome?.type == OutcomeType.draw,
      )
      .length;
  int get truncatedGames =>
      trials.where((trial) => trial.match.truncated).length;
  int get completedGames => games - truncatedGames;

  double get blackWinPercentage => _percentage(blackWins);
  double get whiteWinPercentage => _percentage(whiteWins);
  double get drawPercentage => _percentage(draws);
  double get averagePlies => games == 0
      ? 0
      : trials.fold<int>(
              0,
              (total, trial) =>
                  total +
                  trial.match.finalState.ply -
                  trial.match.initialState.ply,
            ) /
            games;

  Map<String, Object?> toJson({bool includeTrials = false}) => {
    'blackStrategy': blackStrategy.name,
    'whiteStrategy': whiteStrategy.name,
    'games': games,
    'completedGames': completedGames,
    'blackWins': blackWins,
    'whiteWins': whiteWins,
    'draws': draws,
    'truncatedGames': truncatedGames,
    'blackWinPercentage': blackWinPercentage,
    'whiteWinPercentage': whiteWinPercentage,
    'drawPercentage': drawPercentage,
    'averagePlies': averagePlies,
    if (includeTrials)
      'trials': trials.map((trial) => trial.toJson()).toList(growable: false),
  };

  int _wins(Player player) => trials
      .where((trial) => trial.match.finalState.outcome?.winner == player)
      .length;

  double _percentage(int count) =>
      completedGames == 0 ? 0 : count * 100 / completedGames;
}

/// Aggregate output for every requested ordered strategy pairing.
final class OneStepExperimentResult {
  OneStepExperimentResult({
    required this.gamesPerMatchup,
    required this.maxPlies,
    required this.baseSeed,
    required Iterable<OneStepMatchupResult> matchups,
  }) : matchups = List<OneStepMatchupResult>.unmodifiable(matchups);

  final int gamesPerMatchup;
  final int maxPlies;
  final int baseSeed;
  final List<OneStepMatchupResult> matchups;

  int get totalGames =>
      matchups.fold<int>(0, (total, matchup) => total + matchup.games);

  Map<String, Object?> toJson({bool includeTrials = false}) => {
    'experiment': 'oneStepPureStrategyMatchups',
    'gamesPerMatchup': gamesPerMatchup,
    'maxPlies': maxPlies,
    'baseSeed': baseSeed,
    'totalGames': totalGames,
    'tieBreakMethod': 'seededSha256AmongEqualBestSuccessors',
    'matchups': matchups
        .map((matchup) => matchup.toJson(includeTrials: includeTrials))
        .toList(growable: false),
  };
}

/// Runs reproducible pure-strategy trials without Flutter or product services.
///
/// Each agent always optimizes exactly one population objective. Trial seeds
/// vary only the choice among equal-scoring best successor states, providing a
/// distribution of games without weakening either side's pure strategy.
final class OneStepExperimentRunner {
  const OneStepExperimentRunner({this.engine = const GameEngine()});

  final GameEngine engine;

  OneStepExperimentResult runMatrix({
    int gamesPerMatchup = 20,
    int maxPlies = 100,
    int baseSeed = 0,
  }) {
    _validateConfiguration(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
    );
    final matchups = <OneStepMatchupResult>[];
    for (final blackStrategy in OneStepGreedyStrategy.values) {
      for (final whiteStrategy in OneStepGreedyStrategy.values) {
        matchups.add(
          runMatchup(
            blackStrategy: blackStrategy,
            whiteStrategy: whiteStrategy,
            games: gamesPerMatchup,
            maxPlies: maxPlies,
            baseSeed: baseSeed,
          ),
        );
      }
    }
    return OneStepExperimentResult(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      matchups: matchups,
    );
  }

  OneStepMatchupResult runMatchup({
    required OneStepGreedyStrategy blackStrategy,
    required OneStepGreedyStrategy whiteStrategy,
    required int games,
    int maxPlies = 100,
    int baseSeed = 0,
  }) {
    _validateConfiguration(
      gamesPerMatchup: games,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
    );
    final rules = GameRules.standard(
      victory: TurnLimitPopulationVictory(maxPlies),
    );
    final trials = <OneStepTrialResult>[];
    for (var trial = 0; trial < games; trial++) {
      final blackSeed = baseSeed + trial * 2;
      final whiteSeed = blackSeed + 1;
      final black = OneStepGreedyAgent(
        name: 'one-step-${blackStrategy.name}',
        percentages: OneStepStrategyPercentages.pure(blackStrategy),
        tieBreakSeed: blackSeed,
        engine: engine,
      );
      final white = OneStepGreedyAgent(
        name: 'one-step-${whiteStrategy.name}',
        percentages: OneStepStrategyPercentages.pure(whiteStrategy),
        tieBreakSeed: whiteSeed,
        engine: engine,
      );
      final match = AiMatchRunner(
        black: black,
        white: white,
        engine: engine,
      ).play(rules: rules, safetyMaxPlies: maxPlies);
      trials.add(
        OneStepTrialResult(
          trial: trial,
          blackTieBreakSeed: blackSeed,
          whiteTieBreakSeed: whiteSeed,
          match: match,
        ),
      );
    }
    return OneStepMatchupResult(
      blackStrategy: blackStrategy,
      whiteStrategy: whiteStrategy,
      trials: trials,
    );
  }

  void _validateConfiguration({
    required int gamesPerMatchup,
    required int maxPlies,
    required int baseSeed,
  }) {
    if (gamesPerMatchup <= 0) {
      throw ArgumentError.value(
        gamesPerMatchup,
        'gamesPerMatchup',
        'must be positive',
      );
    }
    if (maxPlies <= 0 || maxPlies.isOdd) {
      throw ArgumentError.value(
        maxPlies,
        'maxPlies',
        'must be a positive even integer',
      );
    }
    if (baseSeed < 0) {
      throw ArgumentError.value(baseSeed, 'baseSeed', 'must be non-negative');
    }
  }
}
