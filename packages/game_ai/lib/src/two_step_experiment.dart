import 'package:game_engine/game_engine.dart';

import 'match_runner.dart';
import 'one_step_experiment.dart';
import 'one_step_greedy_agent.dart';
import 'two_step_greedy_agent.dart';

/// One reproducible two-step versus one-step trial.
final class TwoStepRepresentativeTrialResult {
  const TwoStepRepresentativeTrialResult({
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

/// Aggregate results for the two-step agent in one color assignment.
final class TwoStepRepresentativeMatchupResult {
  TwoStepRepresentativeMatchupResult({
    required this.twoStepPlayer,
    required this.oneStepProfile,
    required Iterable<TwoStepRepresentativeTrialResult> trials,
  }) : trials = List.unmodifiable(trials);

  final Player twoStepPlayer;
  final OneStepExperimentProfile oneStepProfile;
  final List<TwoStepRepresentativeTrialResult> trials;

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
  int get twoStepWins => _wins(twoStepPlayer);
  int get oneStepWins => _wins(twoStepPlayer.opponent);
  double get twoStepMeanUtility =>
      completedGames == 0 ? 0 : (twoStepWins - oneStepWins) / completedGames;
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
    'twoStepPlayer': twoStepPlayer.name,
    'twoStepStrategy': 'maxDifferenceDepth2Maximin',
    'oneStepProfile': oneStepProfile.toJson(),
    'games': games,
    'completedGames': completedGames,
    'blackWins': blackWins,
    'whiteWins': whiteWins,
    'draws': draws,
    'truncatedGames': truncatedGames,
    'twoStepWins': twoStepWins,
    'oneStepWins': oneStepWins,
    'twoStepMeanUtility': twoStepMeanUtility,
    'averagePlies': averagePlies,
    if (includeTrials)
      'trials': trials.map((trial) => trial.toJson()).toList(growable: false),
  };

  int _wins(Player player) => trials
      .where((trial) => trial.match.finalState.outcome?.winner == player)
      .length;
}

/// The eight ordered color assignments against four representative profiles.
final class TwoStepRepresentativeExperimentResult {
  TwoStepRepresentativeExperimentResult({
    required this.gamesPerMatchup,
    required this.maxPlies,
    required this.baseSeed,
    required Iterable<TwoStepRepresentativeMatchupResult> matchups,
  }) : matchups = List.unmodifiable(matchups);

  final int gamesPerMatchup;
  final int maxPlies;
  final int baseSeed;
  final List<TwoStepRepresentativeMatchupResult> matchups;

  int get totalGames =>
      matchups.fold<int>(0, (total, matchup) => total + matchup.games);

  Map<String, Object?> toJson({bool includeTrials = false}) => {
    'experiment': 'twoStepMaxDifferenceVsRepresentativeOneStep',
    'definition':
        'maximize own cell advantage after the opponent reply that minimizes it',
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

/// Runs the depth-two agent directly against representative one-step agents.
final class TwoStepRepresentativeExperimentRunner {
  const TwoStepRepresentativeExperimentRunner({
    this.engine = const GameEngine(),
  });

  final GameEngine engine;

  TwoStepRepresentativeExperimentResult runMatrix({
    List<OneStepExperimentProfile> oneStepProfiles =
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
    if (oneStepProfiles.isEmpty) {
      throw ArgumentError.value(
        oneStepProfiles,
        'oneStepProfiles',
        'must not be empty',
      );
    }
    final matchups = <TwoStepRepresentativeMatchupResult>[];
    for (final profile in oneStepProfiles) {
      for (final player in Player.values) {
        matchups.add(
          runMatchup(
            twoStepPlayer: player,
            oneStepProfile: profile,
            games: gamesPerMatchup,
            maxPlies: maxPlies,
            baseSeed: baseSeed,
          ),
        );
      }
    }
    return TwoStepRepresentativeExperimentResult(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      matchups: matchups,
    );
  }

  TwoStepRepresentativeMatchupResult runMatchup({
    required Player twoStepPlayer,
    required OneStepExperimentProfile oneStepProfile,
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
    final trials = <TwoStepRepresentativeTrialResult>[];
    for (var trial = 0; trial < games; trial++) {
      final blackSeed = baseSeed + trial * 2;
      final whiteSeed = blackSeed + 1;
      final twoStep = TwoStepMaxDifferenceAgent(
        tieBreakSeed: twoStepPlayer == Player.black ? blackSeed : whiteSeed,
        engine: engine,
      );
      final oneStep = OneStepGreedyAgent(
        name: 'one-step-${oneStepProfile.id}',
        percentages: oneStepProfile.percentages,
        tieBreakSeed: twoStepPlayer == Player.black ? whiteSeed : blackSeed,
        engine: engine,
      );
      final black = twoStepPlayer == Player.black ? twoStep : oneStep;
      final white = twoStepPlayer == Player.white ? twoStep : oneStep;
      final match = AiMatchRunner(
        black: black,
        white: white,
        engine: engine,
      ).play(rules: rules, safetyMaxPlies: maxPlies);
      trials.add(
        TwoStepRepresentativeTrialResult(
          trial: trial,
          blackTieBreakSeed: blackSeed,
          whiteTieBreakSeed: whiteSeed,
          match: match,
        ),
      );
    }
    return TwoStepRepresentativeMatchupResult(
      twoStepPlayer: twoStepPlayer,
      oneStepProfile: oneStepProfile,
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
