import 'dart:math' as math;

import 'one_step_experiment.dart';
import 'one_step_greedy_agent.dart';

/// The color whose one-step strategy mixture is being optimized.
enum OneStepOptimizationRole { black, white }

/// Configuration for a reproducible adaptive best-response search.
final class OneStepOptimizationConfig {
  const OneStepOptimizationConfig({
    this.searchSteps = const [10, 5, 2, 1],
    this.discoveryGames = 12,
    this.survivorGames = 40,
    this.finalistGames = 200,
    this.survivorCount = 20,
    this.finalistCount = 5,
    this.refineParentCount = 5,
    this.globalExplorationCount = 8,
    this.oracleIterations = 2,
    this.metaGames = 100,
    this.metaSolverIterations = 50000,
    this.validationGames = 500,
    this.validationBootstrapSamples = 10000,
    this.maxPlies = 100,
    this.baseSeed = 10000,
    this.validationBaseSeed = 1000000,
    this.searchSeed = 20260825,
    this.maxParallelEvaluations = 8,
  });

  final List<int> searchSteps;
  final int discoveryGames;
  final int survivorGames;
  final int finalistGames;
  final int survivorCount;
  final int finalistCount;
  final int refineParentCount;
  final int globalExplorationCount;
  final int oracleIterations;
  final int metaGames;
  final int metaSolverIterations;
  final int validationGames;
  final int validationBootstrapSamples;
  final int maxPlies;
  final int baseSeed;
  final int validationBaseSeed;
  final int searchSeed;
  final int maxParallelEvaluations;

  void validate() {
    if (searchSteps.isEmpty ||
        searchSteps.any((step) => step <= 0 || 100 % step != 0)) {
      throw ArgumentError.value(
        searchSteps,
        'searchSteps',
        'must contain positive divisors of 100',
      );
    }
    for (var index = 1; index < searchSteps.length; index++) {
      if (searchSteps[index] >= searchSteps[index - 1]) {
        throw ArgumentError.value(
          searchSteps,
          'searchSteps',
          'must be strictly decreasing',
        );
      }
    }
    final positiveValues = {
      'discoveryGames': discoveryGames,
      'survivorGames': survivorGames,
      'finalistGames': finalistGames,
      'survivorCount': survivorCount,
      'finalistCount': finalistCount,
      'refineParentCount': refineParentCount,
      'oracleIterations': oracleIterations,
      'metaGames': metaGames,
      'metaSolverIterations': metaSolverIterations,
      'validationGames': validationGames,
      'validationBootstrapSamples': validationBootstrapSamples,
      'maxParallelEvaluations': maxParallelEvaluations,
    };
    for (final entry in positiveValues.entries) {
      if (entry.value <= 0) {
        throw ArgumentError.value(entry.value, entry.key, 'must be positive');
      }
    }
    if (survivorGames < discoveryGames || finalistGames < survivorGames) {
      throw ArgumentError(
        'game budgets must increase from discovery through finalists',
      );
    }
    if (finalistCount > survivorCount || refineParentCount > finalistCount) {
      throw ArgumentError(
        'refineParentCount <= finalistCount <= survivorCount is required',
      );
    }
    if (globalExplorationCount < 0) {
      throw ArgumentError.value(
        globalExplorationCount,
        'globalExplorationCount',
        'must be non-negative',
      );
    }
    if (maxPlies <= 0 || maxPlies.isOdd) {
      throw ArgumentError.value(
        maxPlies,
        'maxPlies',
        'must be a positive even integer',
      );
    }
    if (baseSeed < 0 || validationBaseSeed < 0 || searchSeed < 0) {
      throw ArgumentError('all seeds must be non-negative');
    }
  }

  Map<String, Object?> toJson() => {
    'searchSteps': searchSteps,
    'discoveryGames': discoveryGames,
    'survivorGames': survivorGames,
    'finalistGames': finalistGames,
    'survivorCount': survivorCount,
    'finalistCount': finalistCount,
    'refineParentCount': refineParentCount,
    'globalExplorationCount': globalExplorationCount,
    'oracleIterations': oracleIterations,
    'metaGames': metaGames,
    'metaSolverIterations': metaSolverIterations,
    'validationGames': validationGames,
    'validationBootstrapSamples': validationBootstrapSamples,
    'maxPlies': maxPlies,
    'baseSeed': baseSeed,
    'validationBaseSeed': validationBaseSeed,
    'searchSeed': searchSeed,
    'maxParallelEvaluations': maxParallelEvaluations,
  };
}

/// One opponent and its probability in a restricted-game equilibrium.
final class OneStepWeightedProfile {
  const OneStepWeightedProfile({required this.profile, required this.weight});

  final OneStepExperimentProfile profile;
  final double weight;

  Map<String, Object?> toJson() => {
    'profile': profile.toJson(),
    'weight': weight,
  };
}

/// A request to score one candidate against an opponent distribution.
final class OneStepEvaluationRequest {
  const OneStepEvaluationRequest({
    required this.role,
    required this.candidate,
    required this.opponents,
    required this.games,
    required this.maxPlies,
    required this.baseSeed,
    required this.scheduleSeed,
  });

  final OneStepOptimizationRole role;
  final OneStepExperimentProfile candidate;
  final List<OneStepWeightedProfile> opponents;
  final int games;
  final int maxPlies;
  final int baseSeed;
  final int scheduleSeed;
}

/// The Black-perspective outcomes from one evaluation request.
final class OneStepPayoffEstimate {
  OneStepPayoffEstimate(Iterable<int> blackUtilities)
    : blackUtilities = List<int>.unmodifiable(blackUtilities) {
    if (this.blackUtilities.isEmpty ||
        this.blackUtilities.any((value) => value < -1 || value > 1)) {
      throw ArgumentError.value(
        this.blackUtilities,
        'blackUtilities',
        'must be a non-empty list containing only -1, 0, or 1',
      );
    }
  }

  final List<int> blackUtilities;

  int get games => blackUtilities.length;
  int get blackWins => blackUtilities.where((value) => value == 1).length;
  int get whiteWins => blackUtilities.where((value) => value == -1).length;
  int get draws => blackUtilities.where((value) => value == 0).length;
  double get blackMeanUtility =>
      blackUtilities.fold<int>(0, (total, value) => total + value) / games;

  double meanFor(OneStepOptimizationRole role) =>
      role == OneStepOptimizationRole.black
      ? blackMeanUtility
      : -blackMeanUtility;

  double standardErrorFor(OneStepOptimizationRole role) {
    if (games < 2) return 1;
    final mean = meanFor(role);
    final squaredDifference = blackUtilities.fold<double>(0, (total, value) {
      final roleValue = role == OneStepOptimizationRole.black ? value : -value;
      final difference = roleValue - mean;
      return total + difference * difference;
    });
    final sampleVariance = squaredDifference / (games - 1);
    return math.sqrt(sampleVariance / games);
  }

  Map<String, Object?> toJson({bool includeUtilities = false}) => {
    'games': games,
    'blackWins': blackWins,
    'whiteWins': whiteWins,
    'draws': draws,
    'blackMeanUtility': blackMeanUtility,
    if (includeUtilities) 'blackUtilities': blackUtilities,
  };
}

typedef OneStepEvaluationFunction =
    Future<OneStepPayoffEstimate> Function(OneStepEvaluationRequest request);

/// One candidate's score at a specific racing budget.
final class OneStepCandidateScore {
  const OneStepCandidateScore({
    required this.profile,
    required this.payoff,
    required this.role,
  });

  final OneStepExperimentProfile profile;
  final OneStepPayoffEstimate payoff;
  final OneStepOptimizationRole role;

  double get meanUtility => payoff.meanFor(role);
  double get standardError => payoff.standardErrorFor(role);
  double get selectionScore => meanUtility + standardError;

  Map<String, Object?> toJson() => {
    'profile': profile.toJson(),
    'meanUtility': meanUtility,
    'standardError': standardError,
    'selectionScore': selectionScore,
    'payoff': payoff.toJson(),
  };
}

/// All three racing rounds at one grid resolution.
final class OneStepSearchStageResult {
  const OneStepSearchStageResult({
    required this.step,
    required this.discovery,
    required this.survivors,
    required this.finalists,
  });

  final int step;
  final List<OneStepCandidateScore> discovery;
  final List<OneStepCandidateScore> survivors;
  final List<OneStepCandidateScore> finalists;

  Map<String, Object?> toJson() => {
    'step': step,
    'generatedCandidates': discovery.length,
    'discovery': discovery.map((score) => score.toJson()).toList(),
    'survivors': survivors.map((score) => score.toJson()).toList(),
    'finalists': finalists.map((score) => score.toJson()).toList(),
  };
}

/// The adaptive best response found for one color.
final class OneStepBestResponseResult {
  const OneStepBestResponseResult({
    required this.role,
    required this.opponents,
    required this.stages,
    required this.best,
  });

  final OneStepOptimizationRole role;
  final List<OneStepWeightedProfile> opponents;
  final List<OneStepSearchStageResult> stages;
  final OneStepCandidateScore best;

  Map<String, Object?> toJson() => {
    'role': role.name,
    'opponents': opponents.map((opponent) => opponent.toJson()).toList(),
    'stages': stages.map((stage) => stage.toJson()).toList(),
    'best': best.toJson(),
  };
}

/// A restricted zero-sum game and its approximate equilibrium.
final class OneStepMetaGameResult {
  const OneStepMetaGameResult({
    required this.blackProfiles,
    required this.whiteProfiles,
    required this.blackPayoffMatrix,
    required this.blackWeights,
    required this.whiteWeights,
    required this.value,
    required this.lowerBound,
    required this.upperBound,
  });

  final List<OneStepExperimentProfile> blackProfiles;
  final List<OneStepExperimentProfile> whiteProfiles;
  final List<List<double>> blackPayoffMatrix;
  final List<double> blackWeights;
  final List<double> whiteWeights;
  final double value;
  final double lowerBound;
  final double upperBound;

  double get restrictedExploitability => upperBound - lowerBound;

  List<OneStepWeightedProfile> get supportedBlackProfiles => [
    for (var index = 0; index < blackProfiles.length; index++)
      if (blackWeights[index] > 0.0001)
        OneStepWeightedProfile(
          profile: blackProfiles[index],
          weight: blackWeights[index],
        ),
  ];

  List<OneStepWeightedProfile> get supportedWhiteProfiles => [
    for (var index = 0; index < whiteProfiles.length; index++)
      if (whiteWeights[index] > 0.0001)
        OneStepWeightedProfile(
          profile: whiteProfiles[index],
          weight: whiteWeights[index],
        ),
  ];

  Map<String, Object?> toJson() => {
    'blackProfiles': blackProfiles.map((profile) => profile.toJson()).toList(),
    'whiteProfiles': whiteProfiles.map((profile) => profile.toJson()).toList(),
    'blackPayoffMatrix': blackPayoffMatrix,
    'blackWeights': blackWeights,
    'whiteWeights': whiteWeights,
    'supportedBlackProfiles': supportedBlackProfiles
        .map((profile) => profile.toJson())
        .toList(),
    'supportedWhiteProfiles': supportedWhiteProfiles
        .map((profile) => profile.toJson())
        .toList(),
    'value': value,
    'lowerBound': lowerBound,
    'upperBound': upperBound,
    'restrictedExploitability': restrictedExploitability,
  };
}

/// One double-oracle expansion of the restricted strategy game.
final class OneStepOracleIterationResult {
  const OneStepOracleIterationResult({
    required this.iteration,
    required this.metaGame,
    required this.blackBestResponse,
    required this.whiteBestResponse,
    required this.addedBlackProfile,
    required this.addedWhiteProfile,
    required this.estimatedExploitability,
  });

  final int iteration;
  final OneStepMetaGameResult metaGame;
  final OneStepBestResponseResult blackBestResponse;
  final OneStepBestResponseResult whiteBestResponse;
  final bool addedBlackProfile;
  final bool addedWhiteProfile;
  final double estimatedExploitability;

  Map<String, Object?> toJson() => {
    'iteration': iteration,
    'metaGame': metaGame.toJson(),
    'blackBestResponse': blackBestResponse.toJson(),
    'whiteBestResponse': whiteBestResponse.toJson(),
    'addedBlackProfile': addedBlackProfile,
    'addedWhiteProfile': addedWhiteProfile,
    'estimatedExploitability': estimatedExploitability,
  };
}

/// A holdout matchup with a deterministic bootstrap interval.
final class OneStepValidationResult {
  const OneStepValidationResult({
    required this.blackProfile,
    required this.whiteProfile,
    required this.payoff,
    required this.blackUtilityConfidenceLow,
    required this.blackUtilityConfidenceHigh,
  });

  final OneStepExperimentProfile blackProfile;
  final OneStepExperimentProfile whiteProfile;
  final OneStepPayoffEstimate payoff;
  final double blackUtilityConfidenceLow;
  final double blackUtilityConfidenceHigh;

  Map<String, Object?> toJson() => {
    'blackProfile': blackProfile.toJson(),
    'whiteProfile': whiteProfile.toJson(),
    'payoff': payoff.toJson(includeUtilities: true),
    'blackUtility95ConfidenceInterval': [
      blackUtilityConfidenceLow,
      blackUtilityConfidenceHigh,
    ],
  };
}

/// Complete output from optimization, audit, and holdout validation.
final class OneStepOptimizationResult {
  const OneStepOptimizationResult({
    required this.config,
    required this.iterations,
    required this.finalMetaGame,
    required this.finalBlackAudit,
    required this.finalWhiteAudit,
    required this.recommendedBlack,
    required this.recommendedWhite,
    required this.estimatedExploitability,
    required this.validations,
  });

  final OneStepOptimizationConfig config;
  final List<OneStepOracleIterationResult> iterations;
  final OneStepMetaGameResult finalMetaGame;
  final OneStepBestResponseResult finalBlackAudit;
  final OneStepBestResponseResult finalWhiteAudit;
  final OneStepExperimentProfile recommendedBlack;
  final OneStepExperimentProfile recommendedWhite;
  final double estimatedExploitability;
  final List<OneStepValidationResult> validations;

  Map<String, Object?> toJson() => {
    'experiment': 'oneStepAdaptiveMixtureOptimization',
    'method': 'adaptiveGridDoubleOracle',
    'config': config.toJson(),
    'iterations': iterations.map((iteration) => iteration.toJson()).toList(),
    'finalMetaGame': finalMetaGame.toJson(),
    'finalBlackAudit': finalBlackAudit.toJson(),
    'finalWhiteAudit': finalWhiteAudit.toJson(),
    'recommendedBlack': recommendedBlack.toJson(),
    'recommendedWhite': recommendedWhite.toJson(),
    'estimatedExploitability': estimatedExploitability,
    'validations': validations
        .map((validation) => validation.toJson())
        .toList(),
  };
}

/// Adaptive grid search wrapped in a restricted-game double-oracle loop.
final class OneStepAdaptiveOptimizer {
  OneStepAdaptiveOptimizer({
    required this.evaluate,
    this.config = const OneStepOptimizationConfig(),
    this.onProgress,
  }) {
    config.validate();
  }

  final OneStepEvaluationFunction evaluate;
  final OneStepOptimizationConfig config;
  final void Function(String message)? onProgress;
  final Map<String, OneStepPayoffEstimate> _pairCache = {};

  Future<OneStepOptimizationResult> run() async {
    final blackLeague = <OneStepExperimentProfile>[
      ...OneStepExperimentProfile.allProfiles,
    ];
    final whiteLeague = <OneStepExperimentProfile>[
      ...OneStepExperimentProfile.allProfiles,
    ];
    final iterations = <OneStepOracleIterationResult>[];

    for (var iteration = 0; iteration < config.oracleIterations; iteration++) {
      _progress(
        'Building restricted game for oracle iteration ${iteration + 1}',
      );
      final metaGame = await _buildMetaGame(blackLeague, whiteLeague);
      final blackBestResponse = await _searchBestResponse(
        role: OneStepOptimizationRole.black,
        opponents: metaGame.supportedWhiteProfiles,
        seedProfiles: blackLeague,
        searchOffset: iteration * 2,
      );
      final whiteBestResponse = await _searchBestResponse(
        role: OneStepOptimizationRole.white,
        opponents: metaGame.supportedBlackProfiles,
        seedProfiles: whiteLeague,
        searchOffset: iteration * 2 + 1,
      );
      final addedBlack = _addUnique(
        blackLeague,
        blackBestResponse.best.profile,
      );
      final addedWhite = _addUnique(
        whiteLeague,
        whiteBestResponse.best.profile,
      );
      final estimatedExploitability = math.max(
        0.0,
        blackBestResponse.best.payoff.blackMeanUtility -
            whiteBestResponse.best.payoff.blackMeanUtility,
      );
      iterations.add(
        OneStepOracleIterationResult(
          iteration: iteration,
          metaGame: metaGame,
          blackBestResponse: blackBestResponse,
          whiteBestResponse: whiteBestResponse,
          addedBlackProfile: addedBlack,
          addedWhiteProfile: addedWhite,
          estimatedExploitability: estimatedExploitability,
        ),
      );
      if (!addedBlack && !addedWhite) break;
    }

    _progress('Building final restricted game');
    final finalMetaGame = await _buildMetaGame(blackLeague, whiteLeague);
    _progress('Auditing final Black equilibrium response');
    final finalBlackAudit = await _searchBestResponse(
      role: OneStepOptimizationRole.black,
      opponents: finalMetaGame.supportedWhiteProfiles,
      seedProfiles: blackLeague,
      searchOffset: config.oracleIterations * 2,
    );
    _progress('Auditing final White equilibrium response');
    final finalWhiteAudit = await _searchBestResponse(
      role: OneStepOptimizationRole.white,
      opponents: finalMetaGame.supportedBlackProfiles,
      seedProfiles: whiteLeague,
      searchOffset: config.oracleIterations * 2 + 1,
    );
    final estimatedExploitability = math.max(
      0.0,
      finalBlackAudit.best.payoff.blackMeanUtility -
          finalWhiteAudit.best.payoff.blackMeanUtility,
    );

    final recommendedBlack = _robustBlackProfile(finalMetaGame);
    final recommendedWhite = _robustWhiteProfile(finalMetaGame);
    _progress(
      'Validating ${recommendedBlack.id} against ${recommendedWhite.id} and baselines',
    );
    final validations = await _validateRecommendations(
      recommendedBlack,
      recommendedWhite,
    );
    return OneStepOptimizationResult(
      config: config,
      iterations: List.unmodifiable(iterations),
      finalMetaGame: finalMetaGame,
      finalBlackAudit: finalBlackAudit,
      finalWhiteAudit: finalWhiteAudit,
      recommendedBlack: recommendedBlack,
      recommendedWhite: recommendedWhite,
      estimatedExploitability: estimatedExploitability,
      validations: List.unmodifiable(validations),
    );
  }

  Future<OneStepMetaGameResult> _buildMetaGame(
    List<OneStepExperimentProfile> blackProfiles,
    List<OneStepExperimentProfile> whiteProfiles,
  ) async {
    final missing = <_PairRequest>[];
    for (final black in blackProfiles) {
      for (final white in whiteProfiles) {
        final key = _pairKey(black, white);
        if (!_pairCache.containsKey(key)) {
          missing.add(_PairRequest(black: black, white: white));
        }
      }
    }
    final estimates = await _parallelMap(missing, (pair) {
      return evaluate(
        OneStepEvaluationRequest(
          role: OneStepOptimizationRole.black,
          candidate: pair.black,
          opponents: [OneStepWeightedProfile(profile: pair.white, weight: 1)],
          games: config.metaGames,
          maxPlies: config.maxPlies,
          baseSeed: config.baseSeed,
          scheduleSeed: config.searchSeed,
        ),
      );
    });
    for (var index = 0; index < missing.length; index++) {
      _pairCache[_pairKey(missing[index].black, missing[index].white)] =
          estimates[index];
    }
    final matrix = [
      for (final black in blackProfiles)
        [
          for (final white in whiteProfiles)
            _pairCache[_pairKey(black, white)]!.blackMeanUtility,
        ],
    ];
    return solveOneStepMetaGame(
      blackProfiles: List.unmodifiable(blackProfiles),
      whiteProfiles: List.unmodifiable(whiteProfiles),
      blackPayoffMatrix: matrix,
      iterations: config.metaSolverIterations,
    );
  }

  Future<OneStepBestResponseResult> _searchBestResponse({
    required OneStepOptimizationRole role,
    required List<OneStepWeightedProfile> opponents,
    required List<OneStepExperimentProfile> seedProfiles,
    required int searchOffset,
  }) async {
    if (opponents.isEmpty) {
      throw StateError('the equilibrium must support at least one opponent');
    }
    var parents = <OneStepExperimentProfile>[];
    final stages = <OneStepSearchStageResult>[];
    for (var level = 0; level < config.searchSteps.length; level++) {
      final step = config.searchSteps[level];
      final candidates = level == 0
          ? _deduplicate([..._simplexGrid(step), ...seedProfiles])
          : _refinedCandidates(
              step: step,
              previousStep: config.searchSteps[level - 1],
              parents: parents,
              seedProfiles: seedProfiles,
              explorationOffset: searchOffset * 31 + level,
            );
      _progress(
        '${role.name} search $step% grid: ${candidates.length} candidates',
      );
      final discovery = await _scoreCandidates(
        role: role,
        candidates: candidates,
        opponents: opponents,
        games: config.discoveryGames,
        searchOffset: searchOffset,
      );
      final survivorProfiles = discovery
          .take(math.min(config.survivorCount, discovery.length))
          .map((score) => score.profile)
          .toList();
      final survivors = await _scoreCandidates(
        role: role,
        candidates: survivorProfiles,
        opponents: opponents,
        games: config.survivorGames,
        searchOffset: searchOffset,
      );
      final finalistProfiles = survivors
          .take(math.min(config.finalistCount, survivors.length))
          .map((score) => score.profile)
          .toList();
      final finalists = await _scoreCandidates(
        role: role,
        candidates: finalistProfiles,
        opponents: opponents,
        games: config.finalistGames,
        searchOffset: searchOffset,
        rankBySelectionScore: false,
      );
      stages.add(
        OneStepSearchStageResult(
          step: step,
          discovery: List.unmodifiable(discovery),
          survivors: List.unmodifiable(survivors),
          finalists: List.unmodifiable(finalists),
        ),
      );
      parents = finalists
          .take(math.min(config.refineParentCount, finalists.length))
          .map((score) => score.profile)
          .toList();
    }
    final best = stages.last.finalists.first;
    return OneStepBestResponseResult(
      role: role,
      opponents: List.unmodifiable(opponents),
      stages: List.unmodifiable(stages),
      best: best,
    );
  }

  Future<List<OneStepCandidateScore>> _scoreCandidates({
    required OneStepOptimizationRole role,
    required List<OneStepExperimentProfile> candidates,
    required List<OneStepWeightedProfile> opponents,
    required int games,
    required int searchOffset,
    bool rankBySelectionScore = true,
  }) async {
    final estimates = await _parallelMap(candidates, (candidate) {
      return evaluate(
        OneStepEvaluationRequest(
          role: role,
          candidate: candidate,
          opponents: opponents,
          games: games,
          maxPlies: config.maxPlies,
          baseSeed: config.baseSeed + (searchOffset + 1) * 100000,
          scheduleSeed: config.searchSeed + searchOffset,
        ),
      );
    });
    final scores = [
      for (var index = 0; index < candidates.length; index++)
        OneStepCandidateScore(
          profile: candidates[index],
          payoff: estimates[index],
          role: role,
        ),
    ];
    scores.sort((left, right) {
      final leftValue = rankBySelectionScore
          ? left.selectionScore
          : left.meanUtility;
      final rightValue = rankBySelectionScore
          ? right.selectionScore
          : right.meanUtility;
      final comparison = rightValue.compareTo(leftValue);
      return comparison != 0
          ? comparison
          : _profileKey(left.profile).compareTo(_profileKey(right.profile));
    });
    return scores;
  }

  List<OneStepExperimentProfile> _refinedCandidates({
    required int step,
    required int previousStep,
    required List<OneStepExperimentProfile> parents,
    required List<OneStepExperimentProfile> seedProfiles,
    required int explorationOffset,
  }) {
    final fullGrid = _simplexGrid(step);
    final local = fullGrid.where((candidate) {
      return parents.any(
        (parent) => _manhattanDistance(candidate, parent) <= previousStep * 2,
      );
    }).toList();
    final result = _deduplicate([...local, ...parents, ...seedProfiles]);
    if (config.globalExplorationCount == 0) return result;
    final seen = result.map(_profileKey).toSet();
    final targetCount = result.length + config.globalExplorationCount;
    var cursor =
        (config.searchSeed + explorationOffset * 7919) % fullGrid.length;
    var attempts = 0;
    while (attempts < fullGrid.length && result.length < targetCount) {
      final candidate = fullGrid[cursor];
      if (seen.add(_profileKey(candidate))) result.add(candidate);
      cursor = (cursor + 104729) % fullGrid.length;
      attempts++;
    }
    return result;
  }

  Future<List<OneStepValidationResult>> _validateRecommendations(
    OneStepExperimentProfile recommendedBlack,
    OneStepExperimentProfile recommendedWhite,
  ) async {
    final pairs = <_PairRequest>[
      _PairRequest(black: recommendedBlack, white: recommendedWhite),
      for (final baseline in OneStepExperimentProfile.allProfiles)
        _PairRequest(black: recommendedBlack, white: baseline),
      for (final baseline in OneStepExperimentProfile.allProfiles)
        _PairRequest(black: baseline, white: recommendedWhite),
    ];
    final uniquePairs = <String, _PairRequest>{
      for (final pair in pairs) _pairKey(pair.black, pair.white): pair,
    }.values.toList();
    final estimates = await _parallelMap(uniquePairs, (pair) {
      return evaluate(
        OneStepEvaluationRequest(
          role: OneStepOptimizationRole.black,
          candidate: pair.black,
          opponents: [OneStepWeightedProfile(profile: pair.white, weight: 1)],
          games: config.validationGames,
          maxPlies: config.maxPlies,
          baseSeed: config.validationBaseSeed,
          scheduleSeed: config.searchSeed + 999999,
        ),
      );
    });
    return [
      for (var index = 0; index < uniquePairs.length; index++)
        _validationResult(uniquePairs[index], estimates[index], index),
    ];
  }

  OneStepValidationResult _validationResult(
    _PairRequest pair,
    OneStepPayoffEstimate estimate,
    int index,
  ) {
    final confidence = bootstrapMeanConfidenceInterval(
      estimate.blackUtilities,
      samples: config.validationBootstrapSamples,
      seed: config.searchSeed + index,
    );
    return OneStepValidationResult(
      blackProfile: pair.black,
      whiteProfile: pair.white,
      payoff: estimate,
      blackUtilityConfidenceLow: confidence.$1,
      blackUtilityConfidenceHigh: confidence.$2,
    );
  }

  OneStepExperimentProfile _robustBlackProfile(OneStepMetaGameResult metaGame) {
    var bestIndex = 0;
    var bestWorstCase = double.negativeInfinity;
    for (var row = 0; row < metaGame.blackProfiles.length; row++) {
      final worstCase = metaGame.blackPayoffMatrix[row].reduce(math.min);
      if (worstCase > bestWorstCase) {
        bestWorstCase = worstCase;
        bestIndex = row;
      }
    }
    return metaGame.blackProfiles[bestIndex];
  }

  OneStepExperimentProfile _robustWhiteProfile(OneStepMetaGameResult metaGame) {
    var bestIndex = 0;
    var bestWorstCase = double.infinity;
    for (var column = 0; column < metaGame.whiteProfiles.length; column++) {
      var worstCase = double.negativeInfinity;
      for (var row = 0; row < metaGame.blackProfiles.length; row++) {
        worstCase = math.max(
          worstCase,
          metaGame.blackPayoffMatrix[row][column],
        );
      }
      if (worstCase < bestWorstCase) {
        bestWorstCase = worstCase;
        bestIndex = column;
      }
    }
    return metaGame.whiteProfiles[bestIndex];
  }

  Future<List<R>> _parallelMap<T, R>(
    List<T> values,
    Future<R> Function(T value) operation,
  ) async {
    final results = <R>[];
    for (
      var offset = 0;
      offset < values.length;
      offset += config.maxParallelEvaluations
    ) {
      final end = math.min(
        offset + config.maxParallelEvaluations,
        values.length,
      );
      results.addAll(
        await Future.wait(values.sublist(offset, end).map(operation)),
      );
    }
    return results;
  }

  void _progress(String message) => onProgress?.call(message);
}

/// Solves a finite zero-sum restricted game with deterministic fictitious play.
OneStepMetaGameResult solveOneStepMetaGame({
  required List<OneStepExperimentProfile> blackProfiles,
  required List<OneStepExperimentProfile> whiteProfiles,
  required List<List<double>> blackPayoffMatrix,
  int iterations = 50000,
}) {
  if (blackProfiles.isEmpty || whiteProfiles.isEmpty || iterations <= 0) {
    throw ArgumentError('profiles and iterations must be positive');
  }
  if (blackPayoffMatrix.length != blackProfiles.length ||
      blackPayoffMatrix.any((row) => row.length != whiteProfiles.length)) {
    throw ArgumentError('payoff matrix dimensions must match the profiles');
  }
  final rowCounts = List<int>.filled(blackProfiles.length, 0);
  final columnCounts = List<int>.filled(whiteProfiles.length, 0);
  for (var turn = 0; turn < iterations; turn++) {
    final columnWeights = turn == 0
        ? List<double>.filled(whiteProfiles.length, 1 / whiteProfiles.length)
        : columnCounts.map((count) => count / turn).toList();
    final row = _argMax([
      for (final payoffs in blackPayoffMatrix) _dot(payoffs, columnWeights),
    ]);
    rowCounts[row]++;
    final rowWeights = rowCounts.map((count) => count / (turn + 1)).toList();
    final column = _argMin([
      for (var column = 0; column < whiteProfiles.length; column++)
        _columnDot(blackPayoffMatrix, column, rowWeights),
    ]);
    columnCounts[column]++;
  }
  final blackWeights = rowCounts
      .map((count) => count / iterations)
      .toList(growable: false);
  final whiteWeights = columnCounts
      .map((count) => count / iterations)
      .toList(growable: false);
  final rowValues = [
    for (final row in blackPayoffMatrix) _dot(row, whiteWeights),
  ];
  final columnValues = [
    for (var column = 0; column < whiteProfiles.length; column++)
      _columnDot(blackPayoffMatrix, column, blackWeights),
  ];
  final value = _dot([
    for (var row = 0; row < blackProfiles.length; row++)
      _dot(blackPayoffMatrix[row], whiteWeights),
  ], blackWeights);
  return OneStepMetaGameResult(
    blackProfiles: List.unmodifiable(blackProfiles),
    whiteProfiles: List.unmodifiable(whiteProfiles),
    blackPayoffMatrix: List.unmodifiable(
      blackPayoffMatrix.map((row) => List<double>.unmodifiable(row)),
    ),
    blackWeights: blackWeights,
    whiteWeights: whiteWeights,
    value: value,
    lowerBound: columnValues.reduce(math.min),
    upperBound: rowValues.reduce(math.max),
  );
}

/// Deterministic percentile-bootstrap interval for a mean utility.
(double, double) bootstrapMeanConfidenceInterval(
  List<int> values, {
  int samples = 10000,
  int seed = 0,
}) {
  if (values.isEmpty || samples <= 0 || seed < 0) {
    throw ArgumentError(
      'values and samples must be positive; seed is non-negative',
    );
  }
  final random = math.Random(seed);
  final means = List<double>.filled(samples, 0);
  for (var sample = 0; sample < samples; sample++) {
    var total = 0;
    for (var draw = 0; draw < values.length; draw++) {
      total += values[random.nextInt(values.length)];
    }
    means[sample] = total / values.length;
  }
  means.sort();
  final lowIndex = ((samples - 1) * 0.025).floor();
  final highIndex = ((samples - 1) * 0.975).ceil();
  return (means[lowIndex], means[highIndex]);
}

List<OneStepExperimentProfile> _simplexGrid(int step) {
  final profiles = <OneStepExperimentProfile>[];
  for (var maxSelf = 0; maxSelf <= 100; maxSelf += step) {
    for (
      var minOpponent = 0;
      minOpponent <= 100 - maxSelf;
      minOpponent += step
    ) {
      final maxAdvantage = 100 - maxSelf - minOpponent;
      if (maxAdvantage % step != 0) continue;
      profiles.add(
        _profile(
          OneStepStrategyPercentages(
            maxSelfCells: maxSelf,
            minOpponentCells: minOpponent,
            maxCellAdvantage: maxAdvantage,
          ),
        ),
      );
    }
  }
  return profiles;
}

OneStepExperimentProfile _profile(OneStepStrategyPercentages percentages) {
  final id =
      'mix_${percentages.maxSelfCells}_${percentages.minOpponentCells}_${percentages.maxCellAdvantage}';
  return OneStepExperimentProfile(
    id: id,
    label:
        '${percentages.maxSelfCells}/${percentages.minOpponentCells}/${percentages.maxCellAdvantage}',
    percentages: percentages,
  );
}

List<OneStepExperimentProfile> _deduplicate(
  Iterable<OneStepExperimentProfile> profiles,
) {
  final byKey = <String, OneStepExperimentProfile>{};
  for (final profile in profiles) {
    byKey.putIfAbsent(_profileKey(profile), () => profile);
  }
  return byKey.values.toList();
}

bool _addUnique(
  List<OneStepExperimentProfile> profiles,
  OneStepExperimentProfile candidate,
) {
  if (profiles.any(
    (profile) => _profileKey(profile) == _profileKey(candidate),
  )) {
    return false;
  }
  profiles.add(candidate);
  return true;
}

int _manhattanDistance(
  OneStepExperimentProfile left,
  OneStepExperimentProfile right,
) {
  final leftValues = left.percentages;
  final rightValues = right.percentages;
  return (leftValues.maxSelfCells - rightValues.maxSelfCells).abs() +
      (leftValues.minOpponentCells - rightValues.minOpponentCells).abs() +
      (leftValues.maxCellAdvantage - rightValues.maxCellAdvantage).abs();
}

String _profileKey(OneStepExperimentProfile profile) {
  final percentages = profile.percentages;
  return '${percentages.maxSelfCells}:${percentages.minOpponentCells}:${percentages.maxCellAdvantage}';
}

String _pairKey(
  OneStepExperimentProfile black,
  OneStepExperimentProfile white,
) => '${_profileKey(black)}|${_profileKey(white)}';

double _dot(List<double> left, List<double> right) {
  var total = 0.0;
  for (var index = 0; index < left.length; index++) {
    total += left[index] * right[index];
  }
  return total;
}

double _columnDot(List<List<double>> matrix, int column, List<double> weights) {
  var total = 0.0;
  for (var row = 0; row < matrix.length; row++) {
    total += matrix[row][column] * weights[row];
  }
  return total;
}

int _argMax(List<double> values) {
  var best = 0;
  for (var index = 1; index < values.length; index++) {
    if (values[index] > values[best]) best = index;
  }
  return best;
}

int _argMin(List<double> values) {
  var best = 0;
  for (var index = 1; index < values.length; index++) {
    if (values[index] < values[best]) best = index;
  }
  return best;
}

final class _PairRequest {
  const _PairRequest({required this.black, required this.white});

  final OneStepExperimentProfile black;
  final OneStepExperimentProfile white;
}
