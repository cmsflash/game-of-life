import 'package:game_ai/game_ai.dart';
import 'package:test/test.dart';

void main() {
  test('fictitious play finds the rock-paper-scissors equilibrium', () {
    final profiles = OneStepExperimentProfile.pureProfiles;
    final result = solveOneStepMetaGame(
      blackProfiles: profiles,
      whiteProfiles: profiles,
      blackPayoffMatrix: const [
        [0, -1, 1],
        [1, 0, -1],
        [-1, 1, 0],
      ],
      iterations: 100000,
    );

    for (final weight in [...result.blackWeights, ...result.whiteWeights]) {
      expect(weight, closeTo(1 / 3, 0.01));
    }
    expect(result.value, closeTo(0, 0.01));
    expect(result.restrictedExploitability, lessThan(0.02));
  });

  test('bootstrap confidence interval is deterministic', () {
    final first = bootstrapMeanConfidenceInterval(
      const [-1, -1, 1, 1],
      samples: 1000,
      seed: 42,
    );
    final second = bootstrapMeanConfidenceInterval(
      const [-1, -1, 1, 1],
      samples: 1000,
      seed: 42,
    );

    expect(first, second);
    expect(first.$1, lessThanOrEqualTo(0));
    expect(first.$2, greaterThanOrEqualTo(0));
    expect(bootstrapMeanConfidenceInterval(const [1, 1, 1], samples: 20), (
      1.0,
      1.0,
    ));
  });

  test(
    'adaptive optimizer produces role-specific audited recommendations',
    () async {
      final optimizer = OneStepAdaptiveOptimizer(
        evaluate: _fakeEvaluation,
        config: const OneStepOptimizationConfig(
          searchSteps: [50],
          discoveryGames: 1,
          survivorGames: 2,
          finalistGames: 3,
          survivorCount: 2,
          finalistCount: 1,
          refineParentCount: 1,
          globalExplorationCount: 0,
          oracleIterations: 1,
          metaGames: 1,
          metaSolverIterations: 1000,
          validationGames: 2,
          validationBootstrapSamples: 20,
          maxPlies: 2,
          maxParallelEvaluations: 2,
        ),
      );

      final result = await optimizer.run();

      expect(result.iterations, hasLength(1));
      expect(result.finalBlackAudit.stages.single.step, 50);
      expect(result.finalWhiteAudit.stages.single.step, 50);
      expect(result.validations, isNotEmpty);
      expect(
        result.toJson()['experiment'],
        'oneStepAdaptiveMixtureOptimization',
      );
    },
  );

  test('invalid search configuration is rejected', () {
    expect(
      () => OneStepAdaptiveOptimizer(
        evaluate: _fakeEvaluation,
        config: const OneStepOptimizationConfig(searchSteps: [10, 20]),
      ),
      throwsArgumentError,
    );
  });
}

Future<OneStepPayoffEstimate> _fakeEvaluation(
  OneStepEvaluationRequest request,
) async {
  final opponentAdvantage = request.opponents.fold<double>(
    0,
    (total, opponent) =>
        total + opponent.weight * opponent.profile.percentages.maxCellAdvantage,
  );
  final candidateAdvantage = request.candidate.percentages.maxCellAdvantage;
  final blackAdvantage = request.role == OneStepOptimizationRole.black
      ? candidateAdvantage - opponentAdvantage
      : opponentAdvantage - candidateAdvantage;
  final utility = blackAdvantage == 0
      ? 0
      : blackAdvantage > 0
      ? 1
      : -1;
  return OneStepPayoffEstimate(List<int>.filled(request.games, utility));
}
