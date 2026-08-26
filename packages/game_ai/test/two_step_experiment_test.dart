import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const runner = TwoStepRepresentativeExperimentRunner();

  test('runs the two-step agent in either color', () {
    for (final player in Player.values) {
      final result = runner.runMatchup(
        twoStepPlayer: player,
        oneStepProfile: OneStepExperimentProfile.maxDifference,
        games: 1,
        maxPlies: 2,
        baseSeed: 20,
      );

      expect(result.twoStepPlayer, player);
      expect(result.oneStepProfile, OneStepExperimentProfile.maxDifference);
      expect(result.games, 1);
      expect(result.completedGames, 1);
      expect(result.twoStepWins + result.oneStepWins + result.draws, 1);
      expect(result.trials.single.blackTieBreakSeed, 20);
      expect(result.trials.single.whiteTieBreakSeed, 21);
      final decisions = result.trials.single.match.turns.map(
        (turn) => turn.decision,
      );
      expect(decisions.whereType<TwoStepMaxDifferenceDecision>(), hasLength(1));
      expect(decisions.whereType<OneStepGreedyDecision>(), hasLength(1));
    }
  });

  test('representative matrix contains four profiles in both colors', () {
    final result = runner.runMatrix(
      gamesPerMatchup: 1,
      maxPlies: 2,
      baseSeed: 0,
    );

    expect(result.matchups, hasLength(8));
    expect(result.totalGames, 8);
    expect(
      result.matchups
          .map((matchup) => (matchup.twoStepPlayer, matchup.oneStepProfile.id))
          .toSet(),
      hasLength(8),
    );
  });

  test('invalid experiment configuration is rejected', () {
    expect(
      () => runner.runMatchup(
        twoStepPlayer: Player.black,
        oneStepProfile: OneStepExperimentProfile.maxSelf,
        games: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(gamesPerMatchup: 1, maxPlies: 3),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(gamesPerMatchup: 1, baseSeed: -1),
      throwsArgumentError,
    );
    expect(
      () => runner.runMatrix(oneStepProfiles: const []),
      throwsArgumentError,
    );
  });
}
