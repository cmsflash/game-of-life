import 'dart:convert';

import 'package:game_engine/game_engine.dart';

final class GameCli {
  GameCli({GameEngine? engine}) : engine = engine ?? const GameEngine();

  final GameEngine engine;

  Map<String, Object?> handleRequest(Map<String, Object?> request) {
    try {
      final operation = _resolveOperation(request);
      final payload = switch (operation) {
        'initial' => _initial(request),
        'applyMove' => _apply(request),
        'evolve' => _evolve(request),
        'legalMoves' => _legal(request),
        'replay' => _replay(request),
        _ => throw CliRequestException(
          'unsupportedCommand',
          'unsupported operation: $operation',
        ),
      };
      return {'ok': true, 'result': payload};
    } on GameRuleViolation catch (error) {
      return _errorResponse(code: error.code.name, message: error.message);
    } on CliRequestException catch (error) {
      return _errorResponse(code: error.code, message: error.message);
    } on FormatException catch (error) {
      return _errorResponse(code: 'invalidRequest', message: error.message);
    } on ArgumentError catch (error) {
      return _errorResponse(
        code: 'invalidRequest',
        message: error.message?.toString() ?? error.toString(),
      );
    }
  }

  String handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('request must be a JSON object');
      }
      final request = <String, Object?>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String) {
          throw const FormatException('request keys must be strings');
        }
        request[entry.key as String] = entry.value;
      }
      return jsonEncode(handleRequest(request));
    } on FormatException catch (error) {
      return jsonEncode(
        _errorResponse(code: 'invalidJson', message: error.message),
      );
    }
  }

  String _resolveOperation(Map<String, Object?> request) {
    final raw = request['op'];
    if (raw is! String) {
      throw const CliRequestException(
        'invalidRequest',
        'request requires a string op',
      );
    }
    return raw;
  }

  Map<String, Object?> _initial(Map<String, Object?> request) {
    final rules = request['rules'] == null
        ? GameRules.standard()
        : GameRules.fromJson(request['rules']);
    return {'state': engine.initialState(rules).toJson()};
  }

  Map<String, Object?> _apply(Map<String, Object?> request) {
    final state = GameState.fromJson(_required(request, 'state'));
    final moveJson = _required(request, 'move');
    _rejectPass(moveJson);
    final result = engine.applyMove(state, GameMove.fromJson(moveJson));
    return result.toJson();
  }

  Map<String, Object?> _evolve(Map<String, Object?> request) {
    final board = Board.fromJson(_required(request, 'board'));
    final player = Player.fromJson(_required(request, 'player'));
    return engine.evolve(board, movingPlayer: player).toJson();
  }

  Map<String, Object?> _legal(Map<String, Object?> request) {
    final state = GameState.fromJson(_required(request, 'state'));
    final moves = engine.legalMoves(state);
    return {
      'count': moves.length,
      'moves': moves.map((move) => move.toJson()).toList(growable: false),
    };
  }

  Map<String, Object?> _replay(Map<String, Object?> request) {
    final suppliedInitial = request['initialState'];
    final suppliedRules = request['rules'];
    if (suppliedInitial != null && suppliedRules != null) {
      throw const CliRequestException(
        'invalidRequest',
        'provide initialState or rules, not both',
      );
    }
    var state = suppliedInitial == null
        ? engine.initialState(
            suppliedRules == null
                ? GameRules.standard()
                : GameRules.fromJson(suppliedRules),
          )
        : GameState.fromJson(suppliedInitial);
    final rawMoves = _required(request, 'moves');
    if (rawMoves is! List) {
      throw const FormatException('moves must be a JSON array');
    }
    final turns = <Map<String, Object?>>[];
    for (var index = 0; index < rawMoves.length; index++) {
      if (!state.isActive) {
        throw CliRequestException(
          MoveErrorCode.gameOver.name,
          'move $index: the game is already complete',
        );
      }
      final moveJson = _replayMove(rawMoves[index], state);
      try {
        final turn = engine.applyMove(state, GameMove.fromJson(moveJson));
        turns.add(turn.toJson());
        state = turn.state;
      } on GameRuleViolation catch (error) {
        throw CliRequestException(
          error.code.name,
          'move $index: ${error.message}',
        );
      }
    }
    return {'state': state.toJson(), 'turns': turns};
  }

  Map<String, Object?> _replayMove(Object? value, GameState state) {
    if (value is! Map) {
      throw const FormatException('move must be a JSON object');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('move keys must be strings');
      }
      result[entry.key as String] = entry.value;
    }
    _rejectPass(result);
    result['player'] ??= state.toMove?.name;
    result['expectedRevision'] ??= state.revision;
    return result;
  }

  void _rejectPass(Object? value) {
    if (value is Map && value['pass'] == true) {
      throw const GameRuleViolation(
        MoveErrorCode.passNotAllowed,
        'passing is not allowed',
      );
    }
  }

  Object? _required(Map<String, Object?> request, String key) {
    if (!request.containsKey(key) || request[key] == null) {
      throw CliRequestException('invalidRequest', 'request requires $key');
    }
    return request[key];
  }

  Map<String, Object?> _errorResponse({
    required String code,
    required String message,
  }) => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };
}

final class CliRequestException implements Exception {
  const CliRequestException(this.code, this.message);

  final String code;
  final String message;
}
