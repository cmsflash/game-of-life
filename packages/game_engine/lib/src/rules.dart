import 'json_utils.dart';

sealed class VictoryRule {
  const VictoryRule();

  String get mode;

  Map<String, Object?> toJson();

  static VictoryRule fromJson(Object? value) {
    final json = expectJsonObject(value, 'rules.victory');
    final mode = expectJsonString(json['mode'], 'rules.victory.mode');
    return switch (mode) {
      'elimination' => _parseElimination(json),
      'turnLimitPopulation' => _parseTurnLimit(json),
      'populationTarget' => _parsePopulationTarget(json),
      _ => throw FormatException('unsupported victory mode: $mode'),
    };
  }

  static VictoryRule _parseElimination(Map<String, Object?> json) {
    expectExactKeys(json, {'mode'}, name: 'rules.victory');
    return const EliminationVictory();
  }

  static VictoryRule _parseTurnLimit(Map<String, Object?> json) {
    expectExactKeys(json, {'mode', 'maxPlies'}, name: 'rules.victory');
    return TurnLimitPopulationVictory(
      expectJsonInt(json['maxPlies'], 'rules.victory.maxPlies'),
    );
  }

  static VictoryRule _parsePopulationTarget(Map<String, Object?> json) {
    expectExactKeys(json, {'mode', 'target'}, name: 'rules.victory');
    return PopulationTargetVictory(
      expectJsonInt(json['target'], 'rules.victory.target'),
    );
  }
}

final class EliminationVictory extends VictoryRule {
  const EliminationVictory();

  @override
  String get mode => 'elimination';

  @override
  Map<String, Object?> toJson() => {'mode': mode};

  @override
  bool operator ==(Object other) => other is EliminationVictory;

  @override
  int get hashCode => mode.hashCode;
}

final class TurnLimitPopulationVictory extends VictoryRule {
  TurnLimitPopulationVictory(this.maxPlies) {
    if (maxPlies <= 0 || maxPlies.isOdd) {
      throw ArgumentError.value(
        maxPlies,
        'maxPlies',
        'must be a positive even integer',
      );
    }
  }

  final int maxPlies;

  @override
  String get mode => 'turnLimitPopulation';

  @override
  Map<String, Object?> toJson() => {'mode': mode, 'maxPlies': maxPlies};

  @override
  bool operator ==(Object other) =>
      other is TurnLimitPopulationVictory && maxPlies == other.maxPlies;

  @override
  int get hashCode => Object.hash(mode, maxPlies);
}

final class PopulationTargetVictory extends VictoryRule {
  PopulationTargetVictory(this.target) {
    if (target < 3 || target > GameRules.cellCount) {
      throw ArgumentError.value(
        target,
        'target',
        'must be between 3 and ${GameRules.cellCount}',
      );
    }
  }

  final int target;

  @override
  String get mode => 'populationTarget';

  @override
  Map<String, Object?> toJson() => {'mode': mode, 'target': target};

  @override
  bool operator ==(Object other) =>
      other is PopulationTargetVictory && target == other.target;

  @override
  int get hashCode => Object.hash(mode, target);
}

final class GameRules {
  GameRules.standard({VictoryRule? victory})
    : victory = victory ?? const EliminationVictory();

  static const int schemaVersion = 1;
  static const String rulesetId = 'life-duel';
  static const int rulesVersion = 1;
  static const int rows = 20;
  static const int columns = 20;
  static const int cellCount = rows * columns;

  final VictoryRule victory;

  String get rulesHash => sha256Json(toJson());

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'rulesetId': rulesetId,
    'rulesVersion': rulesVersion,
    'board': {'rows': rows, 'columns': columns, 'boundary': 'finiteDead'},
    'neighborhood': 'moore8',
    'evolution': {
      'birth': [3],
      'survival': [2, 3],
      'birthOwner': 'strictNeighborMajority',
    },
    'turn': {
      'placement': 'emptyOnly',
      'passAllowed': false,
      'firstPlayer': 'black',
      'evolveAfterPlacement': true,
    },
    'initialPosition': 'centered2x2Diagonal',
    'victory': victory.toJson(),
    'noLegalMove': 'draw',
  };

  factory GameRules.fromJson(Object? value) {
    final json = expectJsonObject(value, 'rules');
    expectExactKeys(json, {
      'schemaVersion',
      'rulesetId',
      'rulesVersion',
      'board',
      'neighborhood',
      'evolution',
      'turn',
      'initialPosition',
      'victory',
      'noLegalMove',
    }, name: 'rules');

    _expectValue(json, 'schemaVersion', schemaVersion);
    _expectValue(json, 'rulesetId', rulesetId);
    _expectValue(json, 'rulesVersion', rulesVersion);
    _expectValue(json, 'neighborhood', 'moore8');
    _expectValue(json, 'initialPosition', 'centered2x2Diagonal');
    _expectValue(json, 'noLegalMove', 'draw');

    final board = expectJsonObject(json['board'], 'rules.board');
    expectExactKeys(board, {
      'rows',
      'columns',
      'boundary',
    }, name: 'rules.board');
    _expectValue(board, 'rows', rows);
    _expectValue(board, 'columns', columns);
    _expectValue(board, 'boundary', 'finiteDead');

    final evolution = expectJsonObject(json['evolution'], 'rules.evolution');
    expectExactKeys(evolution, {
      'birth',
      'survival',
      'birthOwner',
    }, name: 'rules.evolution');
    _expectIntList(evolution, 'birth', const [3]);
    _expectIntList(evolution, 'survival', const [2, 3]);
    _expectValue(evolution, 'birthOwner', 'strictNeighborMajority');

    final turn = expectJsonObject(json['turn'], 'rules.turn');
    expectExactKeys(turn, {
      'placement',
      'passAllowed',
      'firstPlayer',
      'evolveAfterPlacement',
    }, name: 'rules.turn');
    _expectValue(turn, 'placement', 'emptyOnly');
    _expectValue(turn, 'passAllowed', false);
    _expectValue(turn, 'firstPlayer', 'black');
    _expectValue(turn, 'evolveAfterPlacement', true);

    return GameRules.standard(victory: VictoryRule.fromJson(json['victory']));
  }

  static void _expectValue(
    Map<String, Object?> json,
    String key,
    Object expected,
  ) {
    if (json[key] != expected) {
      throw FormatException(
        'unsupported $key: ${json[key]} (expected $expected)',
      );
    }
  }

  static void _expectIntList(
    Map<String, Object?> json,
    String key,
    List<int> expected,
  ) {
    final actual = expectJsonList(json[key], 'rules.evolution.$key');
    if (!listEquals(actual, expected)) {
      throw FormatException('unsupported $key: $actual (expected $expected)');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GameRules && victory == other.victory;

  @override
  int get hashCode => Object.hash(rulesVersion, victory);
}
