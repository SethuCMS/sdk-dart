import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// A bearer token, or a function that returns one. The function is called for every
/// request, so it can refresh an expired token.
typedef TokenSource = FutureOr<String> Function();

const _localHosts = {'localhost', '127.0.0.1', '[::1]', '::1'};
const _retryableStatus = {429, 502, 503, 504};

/// Checks the gateway address and returns it without a trailing slash.
String normalizeBaseUrl(String raw, {bool allowInsecureHttp = false}) {
  final Uri url;
  try {
    url = Uri.parse(raw);
  } on FormatException {
    throw ArgumentError('baseUrl must be a valid URL');
  }
  if ((url.scheme != 'https' && url.scheme != 'http') || url.host.isEmpty) {
    throw ArgumentError('baseUrl must use https');
  }
  if (url.scheme == 'http' && !_localHosts.contains(url.host) && !allowInsecureHttp) {
    throw ArgumentError('baseUrl must use https. Plain http is only allowed for localhost.');
  }
  if (url.userInfo.isNotEmpty) {
    throw ArgumentError('baseUrl must not contain credentials. Pass a token instead.');
  }
  return raw.replaceAll(RegExp(r'/+$'), '');
}

/// The request pipeline: authentication, timeouts, retries and error handling.
class ApiHttp {
  ApiHttp(
    String baseUrl, {
    this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    bool allowInsecureHttp = false,
    Future<void> Function(Duration)? sleep,
  })  : baseUrl = normalizeBaseUrl(baseUrl, allowInsecureHttp: allowInsecureHttp),
        _client = client ?? http.Client(),
        _sleep = sleep ?? ((Duration d) => Future<void>.delayed(d));

  final String baseUrl;
  final TokenSource? token;
  final Duration timeout;
  final int maxRetries;
  final http.Client _client;
  final Future<void> Function(Duration) _sleep;
  final _random = Random();

  /// Sends a request and returns the decoded JSON body (null when there is none).
  Future<Object?> request(
    String method,
    String path, {
    Map<String, String?> query = const {},
    Object? body,
    String? idempotencyKey,
  }) async {
    // Only reads are retried. A retried write could happen twice.
    final attempts = method == 'GET' ? maxRetries + 1 : 1;
    for (var attempt = 1;; attempt++) {
      try {
        return await _send(method, path, query, body, idempotencyKey);
      } on SethuApiError catch (error) {
        if (attempt >= attempts || !_isRetryable(error)) rethrow;
        await _sleep(_backoff(attempt, error));
      }
    }
  }

  Future<Object?> _send(String method, String path, Map<String, String?> query, Object? body, String? idempotencyKey) async {
    final params = {
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    final base = Uri.parse(baseUrl + path);
    final url = params.isEmpty ? base : base.replace(queryParameters: params);

    final request = http.Request(method, url)
      ..followRedirects = false // the token must never be sent to another address
      ..headers['Accept'] = 'application/json';
    final tokenSource = token;
    final bearer = tokenSource == null ? null : await tokenSource();
    if (bearer != null && bearer.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $bearer'; // a header, never the URL
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (idempotencyKey != null) request.headers['Idempotency-Key'] = idempotencyKey;

    final http.Response response;
    try {
      // One timeout covers sending, waiting and reading the body.
      response = await _exchange(request).timeout(timeout);
    } on TimeoutException {
      throw SethuApiError('TIMEOUT', 'The request took too long', status: 0);
    } catch (_) {
      // Never repeat the network library's message; it can contain addresses.
      throw SethuApiError('CONNECTION_FAILED', 'Could not reach the server', status: 0);
    }

    final decoded = _decode(response);
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
    final seconds = double.tryParse(response.headers['retry-after'] ?? '');
    throw errorFromResponse(
      response.statusCode,
      decoded,
      retryAfter: seconds != null && seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null,
    );
  }

  Future<http.Response> _exchange(http.Request request) async =>
      http.Response.fromStream(await _client.send(request));

  Object? _decode(http.Response response) {
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null; // not JSON (for example an HTML error page); callers handle the missing body
    }
  }

  bool _isRetryable(SethuApiError error) =>
      error.status == 0 ? error.code == 'CONNECTION_FAILED' : _retryableStatus.contains(error.status);

  Duration _backoff(int attempt, SethuApiError error) {
    final hinted = error.retryAfter;
    if (hinted != null) return hinted > const Duration(seconds: 10) ? const Duration(seconds: 10) : hinted;
    final base = min(200 * pow(2, attempt - 1).toInt(), 5000);
    return Duration(milliseconds: (base * (0.5 + _random.nextDouble() / 2)).round());
  }

  void close() => _client.close();
}
