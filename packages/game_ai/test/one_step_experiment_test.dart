import 'package:game_ai/game_ai.dart';
import 'package:test/test.dart';

void main() {
  const runner = OneStepExperimentRunner();

  test('Black and White use independent pure strategies', () {
    final result = runner.runMatchup(
      blackProfile: OneStepExperimentProfile.maxSelf,
      whiteProfile: OneStepExperimentProfile.minTheirs,
      games: 3,
      maxPlies: 2,
      baseSeed: 10,
    );

    expect(result.blackProfile, OneStepExperimentProfile.maxSelf);
    expect(result.whiteProfile, OneStepExperimentProfile.minTheirs);
    expect(result.games, 3);
    expect(result.completedGames, 3);
    expect(result.truncatedGames, 0);
    expect(
      result.blackWins + result.whiteWins + result.draws,
      result.completedGames,
    );
    expect(result.trials[0].blackTieBreakSeed, 10);
    expect(result.trials[0].whiteTieBreakSeed, 11);
    expect(result.trials[1].blackTieBreakSeed, 12);
    expect(result.trials[1].whiteTieBreakSeed, 13);

    for (final trial in result.trials) {
      expect(trial.match.turns, hasLength(2));
      final blackDecision =
          trial.match.turns[0].decision as OneStepGreedyDecision;
      final whiteDecision =
          trial.match.turns[1].decision as OneStepGreedyDecision;
      expect(blackDecision.strategy, OneStepGreedyStrategy.maxSelfCells);
      expect(whiteDecision.strategy, OneStepGreedyStrategy.minOpponentCells);
    }
  });

  test('default matrix covers all 16 ordered strategy profiles', () {
    final result = runner.runMatrix(
      gamesPerMatchup: 1,
      maxPlies: 2,
      baseSeed: 0,
    );

    expect(result.matchups, hasLength(16));
    expect(result.totalGames, 16);
    expect(
      result.matchups
          .map((matchup) => (matchup.blackProfile.id, matchup.whiteProfile.id))
          .toSet(),
      hasLength(16),
    );
  });

  test('equal mix uses the balanced 34/33/33 percentages', () {
    expect(OneStepExperimentProfile.equalMix.percentages.toJson(), {
      'maxSelfCells': 34,
      'minOpponentCells': 33,
      'maxCellAdvantage': 33,
    });
  });

  test('pure-only matrix retains the original nine pairings', () {
    final result = runner.runMatrix(
      profiles: OneStepExperimentProfile.pureProfiles,
      gamesPerMatchup: 1,
      maxPlies: 2,
    );

    expect(result.matchups, hasLength(9));
    expect(result.totalGames, 9);
  });

  test('invalid trial configuration is rejected', () {
    expect(
      () => runner.runMatchup(
        blackProfile: OneStepExperimentProfile.maxSelf,
        whiteProfile: OneStepExperimentProfile.maxDifference,
        games: 0,
        maxPlies: 100,
      ),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(gamesPerMatchup: 1, maxPlies: 3),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(gamesPerMatchup: 1, maxPlies: 2, baseSeed: -1),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(
        profiles: const [
          OneStepExperimentProfile.maxSelf,
          OneStepExperimentProfile.maxSelf,
        ],
        gamesPerMatchup: 1,
        maxPlies: 2,
      ),
      throwsArgumentError,
    );
  });
}
