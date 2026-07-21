import '../../../core/api_client.dart';
import '../../../core/ids.dart';
import 'online_models.dart';

abstract interface class OnlineRepository {
  Future<MatchPage> listMatches();
  Future<MatchmakingTicket> startQuickMatch();
  Future<MatchmakingTicket> getTicket(String id);
  Future<void> cancelTicket(String id);
  Future<PrivateLobby> createPrivateLobby();
  Future<PrivateLobby> getLobby(String id);
  Future<PrivateLobby> joinLobby(String code);
  Future<void> closeLobby(String id);
  Future<OnlineMatch?> getMatch(String id, {String? etag});
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  });
  Future<OnlineMatch> resign(String id, int revision);
}

class ApiOnlineRepository implements OnlineRepository {
  ApiOnlineRepository(this._api);

  final ApiClient _api;

  static const _classicRules = {'mode': 'elimination'};

  @override
  Future<MatchPage> listMatches() async {
    final response = await _api.get('/v1/matches');
    final json = response.data as Map<String, dynamic>? ?? const {};
    final items = json['items'] as List? ?? const [];
    return MatchPage([
      for (final item in items)
        if (item is Map<String, dynamic>) OnlineMatchSummary.fromJson(item),
    ], json['nextToken'] as String?);
  }

  @override
  Future<MatchmakingTicket> startQuickMatch() async {
    final ticketId = newRequestId();
    final response = await _api.post(
      '/v1/matchmaking',
      idempotent: true,
      body: {'ticketId': ticketId, 'rules': _classicRules},
    );
    return _ticket(response.data as Map<String, dynamic>);
  }

  @override
  Future<MatchmakingTicket> getTicket(String id) async {
    final response = await _api.get('/v1/matchmaking', query: {'ticketId': id});
    return _ticket(response.data as Map<String, dynamic>);
  }

  MatchmakingTicket _ticket(Map<String, dynamic> json) =>
      MatchmakingTicket.fromJson(json);

  @override
  Future<void> cancelTicket(String id) async {
    await _api.delete('/v1/matchmaking', query: {'ticketId': id});
  }

  @override
  Future<PrivateLobby> createPrivateLobby() async {
    final response = await _api.post(
      '/v1/matches',
      idempotent: true,
      body: {'rules': _classicRules},
    );
    final match = OnlineMatch.fromJson(
      response.data as Map<String, dynamic>,
      etag: response.etag,
    );
    final json = response.data as Map<String, dynamic>;
    return PrivateLobby(
      id: match.id,
      status: match.status,
      joinCode: json['joinCode'] as String?,
      matchId: match.isActive ? match.id : null,
      pollAfter: const Duration(seconds: 2),
    );
  }

  @override
  Future<PrivateLobby> getLobby(String id) async {
    final response = await _api.get('/v1/matches/$id');
    final json = response.data as Map<String, dynamic>;
    final match = OnlineMatch.fromJson(json, etag: response.etag);
    return PrivateLobby(
      id: match.id,
      status: match.isActive ? 'matched' : match.status,
      joinCode: json['joinCode'] as String?,
      matchId: match.isActive ? match.id : null,
      pollAfter: const Duration(seconds: 2),
    );
  }

  @override
  Future<PrivateLobby> joinLobby(String code) async {
    final response = await _api.post(
      '/v1/matches/join',
      idempotent: true,
      body: {'joinCode': code.trim().toUpperCase()},
    );
    final json = response.data as Map<String, dynamic>;
    final match = OnlineMatch.fromJson(json, etag: response.etag);
    return PrivateLobby(
      id: match.id,
      status: 'matched',
      joinCode: json['joinCode'] as String?,
      matchId: match.id,
      pollAfter: const Duration(seconds: 2),
    );
  }

  @override
  Future<void> closeLobby(String id) async {
    await _api.delete('/v1/matches/$id');
  }

  @override
  Future<OnlineMatch?> getMatch(String id, {String? etag}) async {
    final response = await _api.get(
      '/v1/matches/$id',
      headers: etag == null ? const {} : {'If-None-Match': etag},
    );
    if (response.statusCode == 304) return null;
    return OnlineMatch.fromJson(
      response.data as Map<String, dynamic>,
      etag: response.etag,
    );
  }

  @override
  Future<OnlineMatch> submitMove(
    String id, {
    required int revision,
    required int row,
    required int column,
  }) async {
    final key = newRequestId();
    final response = await _api.post(
      '/v1/matches/$id/moves',
      idempotent: true,
      body: {
        'row': row,
        'column': column,
        'expectedRevision': revision,
        'idempotencyKey': key,
      },
    );
    final json = response.data as Map<String, dynamic>;
    return OnlineMatch.fromJson(
      json['match'] as Map<String, dynamic>? ?? json,
      etag: response.etag,
    );
  }

  @override
  Future<OnlineMatch> resign(String id, int revision) async {
    final key = newRequestId();
    final response = await _api.post(
      '/v1/matches/$id/resign',
      idempotent: true,
      body: {'expectedRevision': revision, 'idempotencyKey': key},
    );
    final json = response.data as Map<String, dynamic>;
    return OnlineMatch.fromJson(
      json['match'] as Map<String, dynamic>? ?? json,
      etag: response.etag,
    );
  }
}
