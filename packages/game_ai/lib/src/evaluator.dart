import 'package:game_engine/game_engine.dart';

/// Weights for the deliberately small, explainable baseline evaluator.
///
/// These values are starting points, not tuned claims. Terminal results always
/// override the positional features.
final class EvaluationWeights {
  const EvaluationWeights({
    this.population = 100,
    this.resilientCells = 20,
    this.birthPotential = 15,
    this.frontierControl = 2,
    this.friendlyAdjacency = 1,
  });

  final int population;
  final int resilientCells;
  final int birthPotential;
  final int frontierControl;
  final int friendlyAdjacency;
}

/// Explainable position features, all oriented to one player's perspective.
///
/// A positive value favors the perspective player and a negative value favors
/// their opponent.
final class PositionFeatures {
  const PositionFeatures({
    required this.populationAdvantage,
    required this.resilientCellAdvantage,
    required this.birthPotentialAdvantage,
    required this.frontierControlAdvantage,
    required this.friendlyAdjacencyAdvantage,
  });

  final int populationAdvantage;
  final int resilientCellAdvantage;
  final int birthPotentialAdvantage;
  final int frontierControlAdvantage;
  final int friendlyAdjacencyAdvantage;

  int weightedScore(EvaluationWeights weights) =>
      populationAdvantage * weights.population +
      resilientCellAdvantage * weights.resilientCells +
      birthPotentialAdvantage * weights.birthPotential +
      frontierControlAdvantage * weights.frontierControl +
      friendlyAdjacencyAdvantage * weights.friendlyAdjacency;

  Map<String, Object?> toJson() => {
    'populationAdvantage': populationAdvantage,
    'resilientCellAdvantage': resilientCellAdvantage,
    'birthPotentialAdvantage': birthPotentialAdvantage,
    'frontierControlAdvantage': frontierControlAdvantage,
    'friendlyAdjacencyAdvantage': friendlyAdjacencyAdvantage,
  };
}

/// A scored state together with the features that explain the score.
final class PositionEvaluation {
  const PositionEvaluation({required this.score, required this.features});

  final int score;
  final PositionFeatures features;

  Map<String, Object?> toJson() => {
    'score': score,
    'features': features.toJson(),
  };
}

/// A deterministic evaluator intended as a transparent classical baseline.
final class HeuristicEvaluator {
  const HeuristicEvaluator({
    this.weights = const EvaluationWeights(),
    this.terminalScore = 1000000,
  }) : assert(terminalScore > 0);

  final EvaluationWeights weights;
  final int terminalScore;

  PositionEvaluation evaluate(GameState state, Player perspective) {
    final features = extractFeatures(state.board, perspective);
    final outcome = state.outcome;
    if (outcome != null) {
      final score = switch (outcome.type) {
        OutcomeType.draw => 0,
        OutcomeType.win =>
          outcome.winner == perspective ? terminalScore : -terminalScore,
      };
      return PositionEvaluation(score: score, features: features);
    }
    return PositionEvaluation(
      score: features.weightedScore(weights),
      features: features,
    );
  }

  PositionFeatures extractFeatures(Board board, Player perspective) {
    var blackResilient = 0;
    var whiteResilient = 0;
    var blackBirthPotential = 0;
    var whiteBirthPotential = 0;
    var blackFrontierControl = 0;
    var whiteFrontierControl = 0;
    var blackFriendlyAdjacency = 0;
    var whiteFriendlyAdjacency = 0;

    for (var row = 0; row < board.rows; row++) {
      for (var column = 0; column < board.columns; column++) {
        final cell = board.at(row, column);
        final neighbors = _neighborCounts(board, row, column);
        final liveNeighbors = neighbors.black + neighbors.white;

        switch (cell) {
          case CellState.black:
            if (liveNeighbors == 2 || liveNeighbors == 3) {
              blackResilient++;
            }
          case CellState.white:
            if (liveNeighbors == 2 || liveNeighbors == 3) {
              whiteResilient++;
            }
          case CellState.empty:
            if (neighbors.black > neighbors.white) {
              blackFrontierControl++;
            } else if (neighbors.white > neighbors.black) {
              whiteFrontierControl++;
            }
            if (liveNeighbors == 3) {
              if (neighbors.black > neighbors.white) {
                blackBirthPotential++;
              } else {
                whiteBirthPotential++;
              }
            }
        }

        if (cell != CellState.empty) {
          for (final direction in _forwardNeighborDirections) {
            final neighborRow = row + direction.$1;
            final neighborColumn = column + direction.$2;
            if (neighborRow < 0 ||
                neighborRow >= board.rows ||
                neighborColumn < 0 ||
                neighborColumn >= board.columns) {
              continue;
            }
            if (board.at(neighborRow, neighborColumn) == cell) {
              if (cell == CellState.black) {
                blackFriendlyAdjacency++;
              } else {
                whiteFriendlyAdjacency++;
              }
            }
          }
        }
      }
    }

    int orient(int blackMinusWhite) =>
        perspective == Player.black ? blackMinusWhite : -blackMinusWhite;

    return PositionFeatures(
      populationAdvantage: orient(
        board.population(CellState.black) - board.population(CellState.white),
      ),
      resilientCellAdvantage: orient(blackResilient - whiteResilient),
      birthPotentialAdvantage: orient(
        blackBirthPotential - whiteBirthPotential,
      ),
      frontierControlAdvantage: orient(
        blackFrontierControl - whiteFrontierControl,
      ),
      friendlyAdjacencyAdvantage: orient(
        blackFriendlyAdjacency - whiteFriendlyAdjacency,
      ),
    );
  }
}

const _forwardNeighborDirections = <(int, int)>[
  (0, 1),
  (1, -1),
  (1, 0),
  (1, 1),
];

({int black, int white}) _neighborCounts(Board board, int row, int column) {
  var black = 0;
  var white = 0;
  for (var rowDelta = -1; rowDelta <= 1; rowDelta++) {
    for (var columnDelta = -1; columnDelta <= 1; columnDelta++) {
      if (rowDelta == 0 && columnDelta == 0) continue;
      final neighborRow = row + rowDelta;
      final neighborColumn = column + columnDelta;
      if (neighborRow < 0 ||
          neighborRow >= board.rows ||
          neighborColumn < 0 ||
          neighborColumn >= board.columns) {
        continue;
      }
      switch (board.at(neighborRow, neighborColumn)) {
        case CellState.black:
          black++;
        case CellState.white:
          white++;
        case CellState.empty:
          break;
      }
    }
  }
  return (black: black, white: white);
}
