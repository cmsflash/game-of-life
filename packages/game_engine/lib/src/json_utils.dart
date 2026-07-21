import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Canonical JSON for the JSON value types used by the engine.
///
/// Object keys are sorted lexicographically and numbers are restricted to
/// integers. That makes hashes stable across the Dart and Python SDKs without
/// relying on insertion order.
String canonicalJson(Object? value) {
  if (value == null || value is bool || value is String) {
    return jsonEncode(value);
  }
  if (value is int) {
    return value.toString();
  }
  if (value is List<Object?>) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    final fields = keys.map(
      (key) => '${jsonEncode(key)}:${canonicalJson(value[key])}',
    );
    return '{${fields.join(',')}}';
  }
  throw FormatException(
    'Unsupported canonical JSON value: ${value.runtimeType}',
  );
}

String sha256Json(Map<String, Object?> json) =>
    sha256.convert(utf8.encode(canonicalJson(json))).toString();

Map<String, Object?> expectJsonObject(Object? value, String name) {
  if (value is! Map) {
    throw FormatException('$name must be a JSON object');
  }
  return value.map((key, value) {
    if (key is! String) {
      throw FormatException('$name contains a non-string key');
    }
    return MapEntry(key, value);
  });
}

List<Object?> expectJsonList(Object? value, String name) {
  if (value is! List) {
    throw FormatException('$name must be a JSON array');
  }
  return List<Object?>.from(value);
}

int expectJsonInt(Object? value, String name) {
  if (value is! int) {
    throw FormatException('$name must be an integer');
  }
  return value;
}

String expectJsonString(Object? value, String name) {
  if (value is! String) {
    throw FormatException('$name must be a string');
  }
  return value;
}

bool expectJsonBool(Object? value, String name) {
  if (value is! bool) {
    throw FormatException('$name must be a boolean');
  }
  return value;
}

void expectExactKeys(
  Map<String, Object?> json,
  Set<String> required, {
  Set<String> optional = const {},
  required String name,
}) {
  final missing = required.difference(json.keys.toSet());
  if (missing.isNotEmpty) {
    throw FormatException('$name is missing: ${missing.join(', ')}');
  }
  final allowed = {...required, ...optional};
  final unknown = json.keys.toSet().difference(allowed);
  if (unknown.isNotEmpty) {
    throw FormatException('$name has unknown fields: ${unknown.join(', ')}');
  }
}

bool listEquals<T>(List<T> first, List<T> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

int hashList(Iterable<Object?> values) => Object.hashAll(values);
