class PlayerStats {
  const PlayerStats({
    required this.elo,
    required this.victories,
    required this.totalGames,
    required this.kills,
    required this.spawns,
    required this.losses,
    required this.draws,
  });

  final int elo;
  final int victories;
  final int totalGames;
  final int kills;
  final int spawns;
  final int losses;
  final int draws;

  double get winRate => totalGames == 0 ? 0 : victories / totalGames;
  bool get isEmpty => totalGames == 0;

  factory PlayerStats.fromJson(Map<String, dynamic> json) {
    final wins = _requiredCount(json, 'wins');
    final losses = _requiredCount(json, 'losses');
    final draws = _requiredCount(json, 'draws');
    final games = _requiredCount(json, 'games');
    if (games != wins + losses + draws) {
      throw const FormatException(
        'Completed games must equal wins, losses, and draws.',
      );
    }
    return PlayerStats(
      elo: _requiredInteger(json, 'rating'),
      victories: wins,
      totalGames: games,
      kills: _requiredCount(json, 'kills'),
      spawns: _optionalCount(json, 'spawns'),
      losses: losses,
      draws: draws,
    );
  }
}

int _requiredCount(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value < 0) {
    throw FormatException('Player stats must include a valid $key value.');
  }
  return value.round();
}

int _optionalCount(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) return 0;
  return _requiredCount(json, key);
}

int _requiredInteger(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('Player stats must include a valid $key value.');
  }
  return value.round();
}
