import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../features/auth/data/session_store.dart';
import 'config.dart';
import 'ids.dart';

class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
    this.details,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;
  final Map<String, dynamic>? details;

  @override
  String toString() => message;
}

class ApiResponse {
  const ApiResponse(this.statusCode, this.data, this.headers);

  final int statusCode;
  final dynamic data;
  final Map<String, String> headers;

  String? get etag => headers['etag'];
}

class ApiClient {
  factory ApiClient({
    required SessionStore sessionStore,
    http.Client? httpClient,
    String baseUrl = AppConfig.apiBaseUrl,
  }) => ApiClient._(sessionStore, httpClient, baseUrl);

  ApiClient._(this._sessionStore, http.Client? httpClient, String baseUrl)
    : _http = httpClient ?? http.Client(),
      baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final SessionStore _sessionStore;
  final http.Client _http;
  final _sessionExpired = StreamController<void>.broadcast();
  final String baseUrl;

  Stream<void> get sessionExpired => _sessionExpired.stream;

  Future<ApiResponse> get(
    String path, {
    Map<String, String?> query = const {},
    bool authenticated = true,
    Map<String, String> headers = const {},
  }) => request(
    'GET',
    path,
    query: query,
    authenticated: authenticated,
    headers: headers,
  );

  Future<ApiResponse> post(
    String path, {
    Object? body,
    Map<String, String?> query = const {},
    bool authenticated = true,
    bool idempotent = false,
  }) => request(
    'POST',
    path,
    body: body,
    query: query,
    authenticated: authenticated,
    idempotent: idempotent,
  );

  Future<ApiResponse> patch(String path, {Object? body}) =>
      request('PATCH', path, body: body);

  Future<ApiResponse> delete(
    String path, {
    Object? body,
    Map<String, String?> query = const {},
  }) => request('DELETE', path, body: body, query: query, idempotent: true);

  Future<ApiResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, String?> query = const {},
    bool authenticated = true,
    bool idempotent = false,
    Map<String, String> headers = const {},
    bool retryAuthentication = true,
  }) async {
    final uri = _uri(path, query);
    final requestHeaders = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      ...headers,
    };
    if (authenticated) {
      final session = await _sessionStore.readSession();
      if (session?.accessToken != null) {
        requestHeaders['Authorization'] = 'Bearer ${session!.accessToken}';
      }
    }
    if (idempotent) requestHeaders['Idempotency-Key'] = newRequestId();

    final response = await _send(method, uri, requestHeaders, body);
    if (response.statusCode == 401 && authenticated) {
      if (retryAuthentication && await _refreshSession()) {
        return request(
          method,
          path,
          body: body,
          query: query,
          authenticated: authenticated,
          idempotent: idempotent,
          headers: headers,
          retryAuthentication: false,
        );
      }
      await _sessionStore.clearSession();
      _sessionExpired.add(null);
    }
    return _decode(response);
  }

  Uri _uri(String path, Map<String, String?> query) {
    final normalized = path.startsWith('/') ? path : '/$path';
    final values = {
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    return Uri.parse(
      '$baseUrl$normalized',
    ).replace(queryParameters: values.isEmpty ? null : values);
  }

  Future<http.Response> _send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Object? body,
  ) {
    final encoded = body == null ? null : jsonEncode(body);
    return switch (method) {
      'GET' => _http.get(uri, headers: headers),
      'POST' => _http.post(uri, headers: headers, body: encoded),
      'PATCH' => _http.patch(uri, headers: headers, body: encoded),
      'DELETE' => _http.delete(uri, headers: headers, body: encoded),
      _ => throw ArgumentError.value(method, 'method'),
    };
  }

  ApiResponse _decode(http.Response response) {
    dynamic data;
    if (response.body.isNotEmpty) {
      try {
        data = jsonDecode(response.body);
      } on FormatException {
        data = response.body;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 400) {
      return ApiResponse(response.statusCode, data, response.headers);
    }
    final envelope = data is Map<String, dynamic> ? data['error'] : null;
    final error = envelope is Map<String, dynamic> ? envelope : null;
    throw ApiException(
      statusCode: response.statusCode,
      code: error?['code'] as String? ?? 'HTTP_${response.statusCode}',
      message:
          error?['message'] as String? ??
          'The server could not complete this request.',
      requestId: error?['requestId'] as String?,
      details: error?['details'] as Map<String, dynamic>?,
    );
  }

  Future<bool> _refreshSession() async {
    final current = await _sessionStore.readSession();
    if (current?.refreshToken == null) return false;
    try {
      final response = await _http.post(
        _uri('/v1/auth/refresh', const {}),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Idempotency-Key': newRequestId(),
        },
        body: jsonEncode({'refreshToken': current!.refreshToken}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _sessionStore.clearSession();
        return false;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionJson = (json['session'] ?? json) as Map<String, dynamic>;
      await _sessionStore.writeSession(
        StoredSession(
          accessToken: sessionJson['accessToken'] as String,
          refreshToken:
              sessionJson['refreshToken'] as String? ?? current.refreshToken,
          expiresAt: sessionJson['expiresIn'] is num
              ? DateTime.now().add(
                  Duration(seconds: (sessionJson['expiresIn'] as num).round()),
                )
              : DateTime.tryParse(sessionJson['expiresAt'] as String? ?? ''),
          userJson:
              sessionJson['user'] as Map<String, dynamic>? ?? current.userJson,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _sessionExpired.close();
    _http.close();
  }
}
