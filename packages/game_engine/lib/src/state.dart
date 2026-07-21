import 'board.dart';
import 'json_utils.dart';
import 'rules.dart';

enum OutcomeType { win, draw }

enum OutcomeReason {
  elimination,
  mutualExtinction,
  populationTarget,
  simultaneousTarget,
  turnLimitPopulation,
  turnLimitTie,
  noLegalMoves;

  static OutcomeReason fromJson(Object? value) {
    return OutcomeReason.values.firstWhere(
      (reason) => reason.name == value,
      orElse: () => throw FormatException('unsupported outcome reason: $value'),
    );
  }
}

final class GameOutcome {
  GameOutcome.win({
    required Player this.winner,
    required this.reason,
    required this.blackPopulation,
    required this.whitePopulation,
  }) : type = OutcomeType.win;

  GameOutcome.draw({
    required this.reason,
    required this.blackPopulation,
    required this.whitePopulation,
  }) : type = OutcomeType.draw,
       winner = null;

  final OutcomeType type;
  final Player? winner;
  final OutcomeReason reason;
  final int blackPopulation;
  final int whitePopulation;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'winner': winner?.name,
    'reason': reason.name,
    'blackPopulation': blackPopulation,
    'whitePopulation': whitePopulation,
  };

  factory GameOutcome.fromJson(Object? value) {
    final json = expectJsonObject(value, 'outcome');
    expectExactKeys(json, {
      'type',
      'winner',
      'reason',
      'blackPopulation',
      'whitePopulation',
    }, name: 'outcome');
    final typeName = expectJsonString(json['type'], 'outcome.type');
    final reason = OutcomeReason.fromJson(json['reason']);
    final blackPopulation = expectJsonInt(
      json['blackPopulation'],
      'outcome.blackPopulation',
    );
    final whitePopulation = expectJsonInt(
      json['whitePopulation'],
      'outcome.whitePopulation',
    );
    return switch (typeName) {
      'win' => GameOutcome.win(
        winner: Player.fromJson(json['winner']),
        reason: reason,
        blackPopulation: blackPopulation,
        whitePopulation: whitePopulation,
      ),
      'draw' => _parseDraw(
        json['winner'],
        reason,
        blackPopulation,
        whitePopulation,
      ),
      _ => throw FormatException('unsupported outcome type: $typeName'),
    };
  }

  static GameOutcome _parseDraw(
    Object? winner,
    OutcomeReason reason,
    int blackPopulation,
    int whitePopulation,
  ) {
    if (winner != null) {
      throw const FormatException('a draw cannot have a winner');
    }
    return GameOutcome.draw(
      reason: reason,
      blackPopulation: blackPopulation,
      whitePopulation: whitePopulation,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GameOutcome &&
      type == other.type &&
      winner == other.winner &&
      reason == other.reason &&
      blackPopulation == other.blackPopulation &&
      whitePopulation == other.whitePopulation;

  @override
  int get hashCode =>
      Object.hash(type, winner, reason, blackPopulation, whitePopulation);
}

enum GameStatus { active, completed }

final class GameState {
  GameState({
    required this.rules,
    required this.board,
    required this.ply,
    required this.revision,
    required this.toMove,
    required this.outcome,
  }) {
    if (board.rows != GameRules.rows || board.columns != GameRules.columns) {
      throw ArgumentError(
        'rules version 1 requires a ${GameRules.rows}x${GameRules.columns} board',
      );
    }
    if (ply < 0 || revision < 0 || ply != revision) {
      throw ArgumentError('ply and revision must be equal and non-negative');
    }
    if ((outcome == null) != (toMove != null)) {
      throw ArgumentError(
        'active states need toMove; completed states must not have toMove',
      );
    }
    if (outcome != null &&
        (outcome!.blackPopulation != blackPopulation ||
            outcome!.whitePopulation != whitePopulation)) {
      throw ArgumentError('outcome populations do not match the board');
    }
  }

  final GameRules rules;
  final Board board;
  final int ply;
  final int revision;
  final Player? toMove;
  final GameOutcome? outcome;

  GameStatus get status =>
      outcome == null ? GameStatus.active : GameStatus.completed;

  bool get isActive => outcome == null;

  int get blackPopulation => board.population(CellState.black);

  int get whitePopulation => board.population(CellState.white);

  String get positionHash => sha256Json({
    'rulesHash': rules.rulesHash,
    'cells': board.toJson()['cells'],
    'toMove': toMove?.name,
  });

  String get stateHash => sha256Json(_coreJson());

  Map<String, Object?> _coreJson() => {
    'schemaVersion': GameRules.schemaVersion,
    'rules': rules.toJson(),
    'rulesHash': rules.rulesHash,
    'cells': board.toJson()['cells'],
    'ply': ply,
    'revision': revision,
    'toMove': toMove?.name,
    'status': status.name,
    'outcome': outcome?.toJson(),
  };

  Map<String, Object?> toJson() => {
    ..._coreJson(),
    'positionHash': positionHash,
    'stateHash': stateHash,
  };

  factory GameState.fromJson(Object? value) {
    final json = expectJsonObject(value, 'state');
    expectExactKeys(
      json,
      {
        'schemaVersion',
        'rules',
        'rulesHash',
        'cells',
        'ply',
        'revision',
        'toMove',
        'status',
        'outcome',
      },
      optional: {'positionHash', 'stateHash'},
      name: 'state',
    );
    final schemaVersion = expectJsonInt(
      json['schemaVersion'],
      'state.schemaVersion',
    );
    if (schemaVersion != GameRules.schemaVersion) {
      throw FormatException('unsupported state schema version: $schemaVersion');
    }
    final rules = GameRules.fromJson(json['rules']);
    final suppliedRulesHash = expectJsonString(
      json['rulesHash'],
      'state.rulesHash',
    );
    if (suppliedRulesHash != rules.rulesHash) {
      throw const FormatException('state.rulesHash does not match its rules');
    }
    final cells = expectJsonList(
      json['cells'],
      'state.cells',
    ).map(CellState.fromWireValue);
    final outcome = json['outcome'] == null
        ? null
        : GameOutcome.fromJson(json['outcome']);
    final toMove = json['toMove'] == null
        ? null
        : Player.fromJson(json['toMove']);
    final state = GameState(
      rules: rules,
      board: Board(
        rows: GameRules.rows,
        columns: GameRules.columns,
        cells: cells,
      ),
      ply: expectJsonInt(json['ply'], 'state.ply'),
      revision: expectJsonInt(json['revision'], 'state.revision'),
      toMove: toMove,
      outcome: outcome,
    );
    final suppliedStatus = expectJsonString(json['status'], 'state.status');
    if (suppliedStatus != state.status.name) {
      throw const FormatException('state.status is inconsistent');
    }
    final suppliedPositionHash = json['positionHash'];
    if (suppliedPositionHash != null &&
        expectJsonString(suppliedPositionHash, 'state.positionHash') !=
            state.positionHash) {
      throw const FormatException('state.positionHash does not match state');
    }
    final suppliedStateHash = json['stateHash'];
    if (suppliedStateHash != null &&
        expectJsonString(suppliedStateHash, 'state.stateHash') !=
            state.stateHash) {
      throw const FormatException('state.stateHash does not match state');
    }
    return state;
  }

  @override
  bool operator ==(Object other) =>
      other is GameState &&
      rules == other.rules &&
      board == other.board &&
      ply == other.ply &&
      revision == other.revision &&
      toMove == other.toMove &&
      outcome == other.outcome;

  @override
  int get hashCode => Object.hash(rules, board, ply, revision, toMove, outcome);
}

enum MoveErrorCode {
  gameOver,
  wrongPlayer,
  staleRevision,
  outOfBounds,
  occupied,
  passNotAllowed,
  invalidState,
  unsupportedRulesVersion,
}

final class MoveValidation {
  const MoveValidation.valid() : code = null, message = null;

  const MoveValidation.invalid(this.code, this.message);

  final MoveErrorCode? code;
  final String? message;

  bool get isValid => code == null;

  Map<String, Object?> toJson() => {
    'valid': isValid,
    if (!isValid) 'code': code!.name,
    if (!isValid) 'message': message,
  };
}

final class GameRuleViolation implements Exception {
  const GameRuleViolation(this.code, this.message);

  final MoveErrorCode code;
  final String message;

  @override
  String toString() => 'GameRuleViolation(${code.name}): $message';
}
