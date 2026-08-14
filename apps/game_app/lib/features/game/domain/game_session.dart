import 'package:game_engine/game_engine.dart' as engine;

import 'move_preview.dart';

enum LocalGameMode {
  elimination,
  turnLimit,
  populationTarget;

  static LocalGameMode fromJson(Object? value) => switch (value) {
    'elimination' => LocalGameMode.elimination,
    'turnLimit' => LocalGameMode.turnLimit,
    'populationTarget' => LocalGameMode.populationTarget,
    _ => throw FormatException('Unsupported local game mode: $value'),
  };
}

class LocalGameConfig {
  const LocalGameConfig({
    this.mode = LocalGameMode.elimination,
    this.turnLimit = 100,
    this.populationTarget = 50,
    this.blackName = 'Black',
    this.whiteName = 'White',
  });

  final LocalGameMode mode;
  final int turnLimit;
  final int populationTarget;
  final String blackName;
  final String whiteName;

  engine.GameRules get rules => engine.GameRules.standard(
    victory: switch (mode) {
      LocalGameMode.elimination => const engine.EliminationVictory(),
      LocalGameMode.turnLimit => engine.TurnLimitPopulationVictory(turnLimit),
      LocalGameMode.populationTarget => engine.PopulationTargetVictory(
        populationTarget,
      ),
    },
  );

  String get modeLabel => switch (mode) {
    LocalGameMode.elimination => 'Elimination',
    LocalGameMode.turnLimit => '$turnLimit-turn score',
    LocalGameMode.populationTarget => 'First to $populationTarget',
  };

  String nameFor(engine.Player player) => player == engine.Player.black
      ? _nonEmpty(blackName, 'Black')
      : _nonEmpty(whiteName, 'White');

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'turnLimit': turnLimit,
    'populationTarget': populationTarget,
    'blackName': nameFor(engine.Player.black),
    'whiteName': nameFor(engine.Player.white),
  };

  factory LocalGameConfig.fromJson(Object? value) {
    final json = _jsonObject(value, 'config');
    return LocalGameConfig(
      mode: LocalGameMode.fromJson(json['mode']),
      turnLimit: _jsonInt(json['turnLimit'], 'config.turnLimit'),
      populationTarget: _jsonInt(
        json['populationTarget'],
        'config.populationTarget',
      ),
      blackName: _jsonString(json['blackName'], 'config.blackName'),
      whiteName: _jsonString(json['whiteName'], 'config.whiteName'),
    );
  }

  static String _nonEmpty(String value, String fallback) {
    final normalized = value.trim();
    return normalized.isEmpty ? fallback : normalized;
  }
}

/// A persisted, resumable hot-seat match.
///
/// [preview] and [error] are deliberately transient: reopening a match always
/// shows its last committed position, never an unconfirmed move.
class LocalGameSession {
  LocalGameSession({
    required this.id,
    required this.title,
    required this.opponentLabel,
    required this.createdAt,
    required this.updatedAt,
    required this.config,
    required this.game,
    this.lastMove,
    this.lastBirths = const [],
    this.lastDeaths = const [],
    this.preview,
    this.error,
  }) : assert(id != ''),
       assert(!updatedAt.isBefore(createdAt));

  final String id;
  final String title;
  final String opponentLabel;
  final DateTime createdAt;
  final DateTime updatedAt;
  final LocalGameConfig config;
  final engine.GameState game;
  final engine.Coordinate? lastMove;
  final List<engine.Coordinate> lastBirths;
  final List<engine.Coordinate> lastDeaths;
  final MovePreview? preview;
  final String? error;

  LocalGameSummary get summary => LocalGameSummary.fromSession(this);

  LocalGameSession copyWith({
    DateTime? updatedAt,
    engine.GameState? game,
    engine.Coordinate? lastMove,
    List<engine.Coordinate>? lastBirths,
    List<engine.Coordinate>? lastDeaths,
    MovePreview? preview,
    String? error,
    bool clearLastMove = false,
    bool clearPreview = false,
    bool clearError = false,
  }) => LocalGameSession(
    id: id,
    title: title,
    opponentLabel: opponentLabel,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    config: config,
    game: game ?? this.game,
    lastMove: clearLastMove ? null : lastMove ?? this.lastMove,
    lastBirths: lastBirths ?? this.lastBirths,
    lastDeaths: lastDeaths ?? this.lastDeaths,
    preview: clearPreview ? null : preview ?? this.preview,
    error: clearError ? null : error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'opponentLabel': opponentLabel,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'config': config.toJson(),
    'game': game.toJson(),
    'lastMove': lastMove?.toJson(),
    'lastBirths': lastBirths
        .map((coordinate) => coordinate.toJson())
        .toList(growable: false),
    'lastDeaths': lastDeaths
        .map((coordinate) => coordinate.toJson())
        .toList(growable: false),
  };

  factory LocalGameSession.fromJson(Object? value) {
    final json = _jsonObject(value, 'localGame');
    final config = LocalGameConfig.fromJson(json['config']);
    final game = engine.GameState.fromJson(json['game']);
    if (game.rules != config.rules) {
      throw const FormatException(
        'The local game config does not match its persisted rules',
      );
    }
    final createdAt = _jsonDate(json['createdAt'], 'localGame.createdAt');
    final updatedAt = _jsonDate(json['updatedAt'], 'localGame.updatedAt');
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException(
        'localGame.updatedAt must not be before createdAt',
      );
    }
    return LocalGameSession(
      id: _jsonString(json['id'], 'localGame.id'),
      title: _jsonString(json['title'], 'localGame.title'),
      opponentLabel: _jsonString(
        json['opponentLabel'],
        'localGame.opponentLabel',
      ),
      createdAt: createdAt,
      updatedAt: updatedAt,
      config: config,
      game: game,
      lastMove: json['lastMove'] == null
          ? null
          : engine.Coordinate.fromJson(json['lastMove']),
      lastBirths: _coordinates(json['lastBirths'], 'localGame.lastBirths'),
      lastDeaths: _coordinates(json['lastDeaths'], 'localGame.lastDeaths'),
    );
  }
}

/// Read-only card data for a mixed local/online "current games" list.
class LocalGameSummary {
  const LocalGameSummary({
    required this.id,
    required this.title,
    required this.blackName,
    required this.whiteName,
    required this.opponentLabel,
    required this.modeLabel,
    required this.createdAt,
    required this.updatedAt,
    required this.isActive,
    required this.toMove,
    required this.toMoveLabel,
    required this.ply,
    required this.winner,
    required this.winnerLabel,
    required this.isDraw,
    required this.blackPopulation,
    required this.whitePopulation,
  });

  factory LocalGameSummary.fromSession(LocalGameSession session) {
    final game = session.game;
    final winner = game.outcome?.winner;
    return LocalGameSummary(
      id: session.id,
      title: session.title,
      blackName: session.config.nameFor(engine.Player.black),
      whiteName: session.config.nameFor(engine.Player.white),
      opponentLabel: session.opponentLabel,
      modeLabel: session.config.modeLabel,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      isActive: game.isActive,
      toMove: game.toMove,
      toMoveLabel: game.toMove == null
          ? null
          : session.config.nameFor(game.toMove!),
      ply: game.ply,
      winner: winner,
      winnerLabel: winner == null ? null : session.config.nameFor(winner),
      isDraw: game.outcome != null && winner == null,
      blackPopulation: game.blackPopulation,
      whitePopulation: game.whitePopulation,
    );
  }

  final String id;
  final String title;
  final String blackName;
  final String whiteName;
  final String opponentLabel;
  final String modeLabel;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isActive;
  final engine.Player? toMove;
  final String? toMoveLabel;
  final int ply;
  final engine.Player? winner;
  final String? winnerLabel;
  final bool isDraw;
  final int blackPopulation;
  final int whitePopulation;
}

Map<String, Object?> _jsonObject(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object');
  return value.map((key, value) {
    if (key is! String) throw FormatException('$name keys must be strings');
    return MapEntry(key, value);
  });
}

String _jsonString(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string');
  }
  return value;
}

int _jsonInt(Object? value, String name) {
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

DateTime _jsonDate(Object? value, String name) {
  final parsed = DateTime.tryParse(_jsonString(value, name));
  if (parsed == null) throw FormatException('$name must be an ISO 8601 date');
  return parsed.toUtc();
}

List<engine.Coordinate> _coordinates(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be a list');
  return List.unmodifiable(value.map(engine.Coordinate.fromJson));
}
