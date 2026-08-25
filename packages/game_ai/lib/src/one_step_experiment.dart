import 'package:game_engine/game_engine.dart';

import 'match_runner.dart';
import 'one_step_greedy_agent.dart';

/// One reusable strategy mix for headless matchup experiments.
final class OneStepExperimentProfile {
  const OneStepExperimentProfile({
    required this.id,
    required this.label,
    required this.percentages,
  });

  static const maxSelf = OneStepExperimentProfile(
    id: 'maxSelf',
    label: 'Max own cells',
    percentages: OneStepStrategyPercentages(
      maxSelfCells: 100,
      minOpponentCells: 0,
      maxCellAdvantage: 0,
    ),
  );
  static const minTheirs = OneStepExperimentProfile(
    id: 'minTheirs',
    label: 'Min their cells',
    percentages: OneStepStrategyPercentages(
      maxSelfCells: 0,
      minOpponentCells: 100,
      maxCellAdvantage: 0,
    ),
  );
  static const maxDifference = OneStepExperimentProfile(
    id: 'maxDifference',
    label: 'Max own − theirs',
    percentages: OneStepStrategyPercentages(
      maxSelfCells: 0,
      minOpponentCells: 0,
      maxCellAdvantage: 100,
    ),
  );
  static const equalMix = OneStepExperimentProfile(
    id: 'equalMix',
    label: 'Equal three-way mix',
    percentages: OneStepStrategyPercentages.balanced(),
  );

  static const pureProfiles = [maxSelf, minTheirs, maxDifference];
  static const allProfiles = [maxSelf, minTheirs, maxDifference, equalMix];

  final String id;
  final String label;
  final OneStepStrategyPercentages percentages;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'percentages': percentages.toJson(),
  };
}

/// One reproducible trial from a strategy-profile matchup.
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
    required this.blackProfile,
    required this.whiteProfile,
    required Iterable<OneStepTrialResult> trials,
  }) : trials = List<OneStepTrialResult>.unmodifiable(trials);

  final OneStepExperimentProfile blackProfile;
  final OneStepExperimentProfile whiteProfile;
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
    'blackProfile': blackProfile.toJson(),
    'whiteProfile': whiteProfile.toJson(),
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
    'experiment': 'oneStepStrategyProfileMatchups',
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

/// Runs reproducible strategy-profile trials without Flutter or services.
///
/// Trial seeds vary only the choice among equal-scoring best successor states.
/// The profile percentages still select the objective for each turn, so seeded
/// trials never permit a lower-scoring move for that selected objective.
final class OneStepExperimentRunner {
  const OneStepExperimentRunner({this.engine = const GameEngine()});

  final GameEngine engine;

  OneStepExperimentResult runMatrix({
    List<OneStepExperimentProfile> profiles =
        OneStepExperimentProfile.allProfiles,
    int gamesPerMatchup = 20,
    int maxPlies = 100,
    int baseSeed = 0,
  }) {
    _validateConfiguration(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
    );
    if (profiles.isEmpty) {
      throw ArgumentError.value(profiles, 'profiles', 'must not be empty');
    }
    final profileIds = profiles.map((profile) => profile.id).toSet();
    if (profileIds.length != profiles.length) {
      throw ArgumentError.value(
        profiles,
        'profiles',
        'profile IDs must be unique',
      );
    }
    final matchups = <OneStepMatchupResult>[];
    for (final blackProfile in profiles) {
      for (final whiteProfile in profiles) {
        matchups.add(
          runMatchup(
            blackProfile: blackProfile,
            whiteProfile: whiteProfile,
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
    required OneStepExperimentProfile blackProfile,
    required OneStepExperimentProfile whiteProfile,
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
        name: 'one-step-${blackProfile.id}',
        percentages: blackProfile.percentages,
        tieBreakSeed: blackSeed,
        engine: engine,
      );
      final white = OneStepGreedyAgent(
        name: 'one-step-${whiteProfile.id}',
        percentages: whiteProfile.percentages,
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
      blackProfile: blackProfile,
      whiteProfile: whiteProfile,
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
