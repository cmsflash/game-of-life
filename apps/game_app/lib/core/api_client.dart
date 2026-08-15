import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

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
    String? baseUrl,
    Duration requestTimeout = const Duration(seconds: 20),
  }) => ApiClient._(
    sessionStore,
    httpClient,
    baseUrl ?? AppConfig.apiBaseUrl,
    requestTimeout,
  );

  ApiClient._(
    this._sessionStore,
    http.Client? httpClient,
    String baseUrl,
    this._requestTimeout,
  ) : _http = httpClient ?? http.Client(),
      baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final SessionStore _sessionStore;
  final http.Client _http;
  final Duration _requestTimeout;
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

  Future<ApiResponse> postMultipart(
    String path, {
    required String field,
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) => _postMultipart(
    path,
    field: field,
    bytes: bytes,
    filename: filename,
    contentType: contentType,
    retryAuthentication: true,
  );

  Future<ApiResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, String?> query = const {},
    bool authenticated = true,
    bool idempotent = false,
    String? idempotencyKey,
    Map<String, String> headers = const {},
    bool retryAuthentication = true,
  }) async {
    final operationIdempotencyKey =
        idempotencyKey ?? (idempotent ? newRequestId() : null);
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
    if (operationIdempotencyKey != null) {
      requestHeaders['Idempotency-Key'] = operationIdempotencyKey;
    }

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
          idempotencyKey: operationIdempotencyKey,
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
  ) async {
    final encoded = body == null ? null : jsonEncode(body);
    try {
      return await switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(uri, headers: headers, body: encoded),
        'PATCH' => _http.patch(uri, headers: headers, body: encoded),
        'DELETE' => _http.delete(uri, headers: headers, body: encoded),
        _ => throw ArgumentError.value(method, 'method'),
      }.timeout(_requestTimeout);
    } on TimeoutException {
      throw const ApiException(
        statusCode: 0,
        code: 'requestTimeout',
        message: 'The server took too long to respond. Please try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        statusCode: 0,
        code: 'networkUnavailable',
        message: 'The server could not be reached. Check your connection.',
      );
    }
  }

  Future<ApiResponse> _postMultipart(
    String path, {
    required String field,
    required List<int> bytes,
    required String filename,
    required String contentType,
    required bool retryAuthentication,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path, const {}))
      ..headers['Accept'] = 'application/json';
    final session = await _sessionStore.readSession();
    if (session?.accessToken != null) {
      request.headers['Authorization'] = 'Bearer ${session!.accessToken}';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        field,
        bytes,
        filename: filename,
        contentType: MediaType.parse(contentType),
      ),
    );
    late http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(_requestTimeout),
      ).timeout(_requestTimeout);
    } on TimeoutException {
      throw const ApiException(
        statusCode: 0,
        code: 'requestTimeout',
        message: 'The server took too long to respond. Please try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        statusCode: 0,
        code: 'networkUnavailable',
        message: 'The server could not be reached. Check your connection.',
      );
    }
    if (response.statusCode == 401) {
      if (retryAuthentication && await _refreshSession()) {
        return _postMultipart(
          path,
          field: field,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
          retryAuthentication: false,
        );
      }
      await _sessionStore.clearSession();
      _sessionExpired.add(null);
    }
    return _decode(response);
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
      final response = await _http
          .post(
            _uri('/v1/auth/refresh', const {}),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Idempotency-Key': newRequestId(),
            },
            body: jsonEncode({'refreshToken': current!.refreshToken}),
          )
          .timeout(_requestTimeout);
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
              ? DateTime.now().toUtc().add(
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
