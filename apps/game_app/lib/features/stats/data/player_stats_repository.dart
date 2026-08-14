import '../../../core/api_client.dart';
import 'player_stats.dart';

abstract interface class PlayerStatsRepository {
  Future<PlayerStats> getMyStats();
}

class ApiPlayerStatsRepository implements PlayerStatsRepository {
  const ApiPlayerStatsRepository(this._api);

  final ApiClient _api;

  @override
  Future<PlayerStats> getMyStats() async {
    final response = await _api.get('/v1/stats/me');
    return PlayerStats.fromJson(response.data as Map<String, dynamic>);
  }
}
