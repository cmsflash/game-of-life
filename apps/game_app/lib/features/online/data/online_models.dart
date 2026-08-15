import 'dart:convert';

import 'package:game_engine/game_engine.dart' as engine;

class OnlinePlayer {
  const OnlinePlayer({
    required this.id,
    required this.username,
    required this.displayName,
    required this.color,
    this.avatarUrl,
    this.avatarVersion = 0,
  });

  final String id;
  final String username;
  final String displayName;
  final engine.Player color;
  final String? avatarUrl;
  final int avatarVersion;

  factory OnlinePlayer.fromJson(
    Map<String, dynamic> json,
    engine.Player fallbackColor,
  ) {
    final username = json['username'] as String? ?? 'player';
    return OnlinePlayer(
      id: json['userId'] as String? ?? json['id'] as String? ?? username,
      username: username,
      displayName: json['displayName'] as String? ?? username,
      color: _player(json['color']) ?? fallbackColor,
      avatarUrl: json['avatarUrl'] as String?,
      avatarVersion: (json['avatarVersion'] as num?)?.round() ?? 0,
    );
  }
}

class OnlineMatchSummary {
  const OnlineMatchSummary({
    required this.id,
    required this.status,
    required this.updatedAt,
    required this.opponentName,
    this.yourColor,
    this.yourTurn = false,
    this.blackPopulation,
    this.whitePopulation,
    this.joinCode,
    this.opponentAvatarUrl,
    this.opponentAvatarVersion = 0,
  });

  final String id;
  final String status;
  final DateTime? updatedAt;
  final String opponentName;
  final engine.Player? yourColor;
  final bool yourTurn;
  final int? blackPopulation;
  final int? whitePopulation;
  final String? joinCode;
  final String? opponentAvatarUrl;
  final int opponentAvatarVersion;

  factory OnlineMatchSummary.fromJson(Map<String, dynamic> json) {
    final state = json['state'] as Map<String, dynamic>?;
    final players = _parsePlayers(json);
    final yourColor = _player(json['yourColor']);
    final opponent = players.where((player) => player.color != yourColor);
    final otherPlayer = opponent.isEmpty ? null : opponent.first;
    final counts = json['liveCounts'] as Map<String, dynamic>?;
    return OnlineMatchSummary(
      id: json['matchId'] as String? ?? json['id'] as String? ?? '',
      status: json['status'] as String? ?? 'active',
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      opponentName: otherPlayer != null
          ? otherPlayer.displayName
          : json['opponentName'] as String? ?? 'Opponent',
      opponentAvatarUrl:
          otherPlayer?.avatarUrl ?? json['opponentAvatarUrl'] as String?,
      opponentAvatarVersion:
          otherPlayer?.avatarVersion ??
          (json['opponentAvatarVersion'] as num?)?.round() ??
          0,
      yourColor: yourColor,
      yourTurn:
          json['yourTurn'] as bool? ??
          (_player(json['nextPlayerColor'] ?? state?['toMove']) == yourColor &&
              yourColor != null),
      blackPopulation: (counts?['black'] as num?)?.round(),
      whitePopulation: (counts?['white'] as num?)?.round(),
      joinCode: json['joinCode'] as String?,
    );
  }
}

class OnlineMatch {
  OnlineMatch({
    required this.id,
    required this.status,
    required this.revision,
    required this.board,
    required this.players,
    required this.blackPopulation,
    required this.whitePopulation,
    engine.GameRules? rules,
    this.yourColor,
    this.nextPlayer,
    this.lastMove,
    this.result,
    this.etag,
    this.updatedAt,
  }) : rules = rules ?? engine.GameRules.standard();

  final String id;
  final String status;
  final int revision;
  final engine.Board board;
  final engine.GameRules rules;
  final List<OnlinePlayer> players;
  final engine.Player? yourColor;
  final engine.Player? nextPlayer;
  final engine.Coordinate? lastMove;
  final int blackPopulation;
  final int whitePopulation;
  final Map<String, dynamic>? result;
  final String? etag;
  final DateTime? updatedAt;

  bool get isActive => status == 'active';
  bool get isYourTurn =>
      isActive && yourColor != null && nextPlayer == yourColor;

  OnlinePlayer? playerFor(engine.Player color) {
    for (final player in players) {
      if (player.color == color) return player;
    }
    return null;
  }

  OnlineMatch withEtag(String? value) => OnlineMatch(
    id: id,
    status: status,
    revision: revision,
    board: board,
    players: players,
    blackPopulation: blackPopulation,
    whitePopulation: whitePopulation,
    rules: rules,
    yourColor: yourColor,
    nextPlayer: nextPlayer,
    lastMove: lastMove,
    result: result,
    etag: value ?? etag,
    updatedAt: updatedAt,
  );

  factory OnlineMatch.fromJson(Map<String, dynamic> json, {String? etag}) {
    final state = json['state'] as Map<String, dynamic>?;
    final boardJson =
        json['board'] as Map<String, dynamic>? ??
        state?['board'] as Map<String, dynamic>?;
    final board = _decodeBoard(boardJson, state);
    final counts = json['liveCounts'] as Map<String, dynamic>?;
    final players = _parsePlayers(json);
    final nextPlayer = _player(
      json['nextPlayerColor'] ??
          json['toMove'] ??
          state?['toMove'] ??
          _colorForId(players, json['nextPlayerId'] as String?),
    );
    return OnlineMatch(
      id: json['matchId'] as String? ?? json['id'] as String? ?? '',
      status:
          json['status'] as String? ?? state?['status'] as String? ?? 'active',
      revision:
          (json['revision'] as num?)?.round() ??
          (state?['revision'] as num?)?.round() ??
          0,
      board: board,
      rules: _decodeRules(json, state),
      players: players,
      yourColor: _player(json['yourColor']),
      nextPlayer: nextPlayer,
      lastMove: _decodeLastMove(json['lastMove']),
      blackPopulation:
          (counts?['black'] as num?)?.round() ??
          board.population(engine.CellState.black),
      whitePopulation:
          (counts?['white'] as num?)?.round() ??
          board.population(engine.CellState.white),
      result:
          json['result'] as Map<String, dynamic>? ??
          state?['outcome'] as Map<String, dynamic>?,
      etag: etag,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }
}

engine.GameRules _decodeRules(
  Map<String, dynamic> json,
  Map<String, dynamic>? state,
) {
  final value = json['rules'] ?? state?['rules'];
  if (value != null) {
    try {
      return engine.GameRules.fromJson(value);
    } on FormatException {
      // A subsequent poll can repair a malformed legacy response. The
      // production API currently supports only the standard rules document.
    }
  }
  return engine.GameRules.standard();
}

engine.Coordinate? _decodeLastMove(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final row = (value['row'] as num?)?.round();
  final column = (value['column'] as num?)?.round();
  if (row == null ||
      column == null ||
      row < 0 ||
      row >= 20 ||
      column < 0 ||
      column >= 20) {
    return null;
  }
  return engine.Coordinate(row, column);
}

class MatchPage {
  const MatchPage(this.items, this.nextCursor);

  final List<OnlineMatchSummary> items;
  final String? nextCursor;
}

class MatchmakingTicket {
  const MatchmakingTicket({
    required this.id,
    required this.status,
    required this.pollAfter,
    this.matchId,
  });

  final String id;
  final String status;
  final Duration pollAfter;
  final String? matchId;

  factory MatchmakingTicket.fromJson(Map<String, dynamic> json) =>
      MatchmakingTicket(
        id: json['ticketId'] as String? ?? json['id'] as String? ?? '',
        status: json['status'] as String? ?? 'searching',
        pollAfter: Duration(
          milliseconds: (json['pollAfterMs'] as num?)?.round() ?? 2000,
        ),
        matchId: json['matchId'] as String?,
      );
}

class PrivateLobby {
  const PrivateLobby({
    required this.id,
    required this.status,
    required this.pollAfter,
    this.joinCode,
    this.matchId,
  });

  final String id;
  final String status;
  final String? joinCode;
  final String? matchId;
  final Duration pollAfter;

  factory PrivateLobby.fromJson(Map<String, dynamic> json) => PrivateLobby(
    id: json['lobbyId'] as String? ?? json['id'] as String? ?? '',
    status: json['status'] as String? ?? 'waiting',
    joinCode: json['joinCode'] as String?,
    matchId: json['matchId'] as String?,
    pollAfter: Duration(
      milliseconds: (json['pollAfterMs'] as num?)?.round() ?? 2000,
    ),
  );
}

List<OnlinePlayer> _parsePlayers(Map<String, dynamic> json) {
  final array = json['players'];
  if (array is List) {
    return [
      for (var i = 0; i < array.length; i++)
        if (array[i] is Map<String, dynamic>)
          OnlinePlayer.fromJson(
            array[i] as Map<String, dynamic>,
            i == 0 ? engine.Player.black : engine.Player.white,
          ),
    ];
  }
  final result = <OnlinePlayer>[];
  final black = json['blackPlayer'];
  final white = json['whitePlayer'];
  if (black is Map<String, dynamic>) {
    result.add(OnlinePlayer.fromJson(black, engine.Player.black));
  }
  if (white is Map<String, dynamic>) {
    result.add(OnlinePlayer.fromJson(white, engine.Player.white));
  }
  return result;
}

engine.Board _decodeBoard(
  Map<String, dynamic>? board,
  Map<String, dynamic>? state,
) {
  const rows = 20;
  const columns = 20;
  final cellsValue = board?['cells'] ?? state?['cells'];
  if (cellsValue is List) {
    final cells = cellsValue.map((value) {
      final number = (value as num?)?.round() ?? 0;
      return switch (number) {
        1 => engine.CellState.black,
        2 => engine.CellState.white,
        _ => engine.CellState.empty,
      };
    }).toList();
    if (cells.length == rows * columns) {
      return engine.Board(rows: rows, columns: columns, cells: cells);
    }
  }
  final encoded = board?['cells'];
  if (encoded is String) {
    try {
      final bytes = base64Decode(encoded);
      final cells = <engine.CellState>[];
      for (var index = 0; index < rows * columns; index++) {
        final value = (bytes[index ~/ 4] >> ((index % 4) * 2)) & 0x03;
        cells.add(switch (value) {
          1 => engine.CellState.black,
          2 => engine.CellState.white,
          _ => engine.CellState.empty,
        });
      }
      return engine.Board(rows: rows, columns: columns, cells: cells);
    } catch (_) {
      // Fall back to an empty board while the next poll repairs malformed data.
    }
  }
  return engine.Board.empty(rows: rows, columns: columns);
}

engine.Player? _player(Object? value) => switch (value) {
  'black' => engine.Player.black,
  'white' => engine.Player.white,
  _ => null,
};

String? _colorForId(List<OnlinePlayer> players, String? id) {
  if (id == null) return null;
  for (final player in players) {
    if (player.id == id) return player.color.name;
  }
  return null;
}
