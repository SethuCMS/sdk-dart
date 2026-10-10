import 'package:http/http.dart' as http;

import 'collection.dart';
import 'errors.dart';
import 'http_client.dart';

/// The entry point of the SDK.
///
///     final cms = SethuClient('https://cms.example.com', token: () => getAccessToken());
///     final orders = cms.collection('conn_123', 'orders');
///     final page = await orders.where(eq('status', 'paid')).orderBy('created_at', descending: true).limit(20).list();
class SethuClient {
  SethuClient(
    String baseUrl, {
    TokenSource? token,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 2,
    bool allowInsecureHttp = false,
    Future<void> Function(Duration)? sleep,
  }) : _http = ApiHttp(
         baseUrl,
         token: token,
         client: httpClient,
         timeout: timeout,
         maxRetries: maxRetries,
         allowInsecureHttp: allowInsecureHttp,
         sleep: sleep,
       );

  final ApiHttp _http;

  Collection collection(String connectionId, String name) =>
      Collection(_http, connectionId, name);

  Future<List<Map<String, Object?>>> connections() async =>
      _list(await _http.request('GET', '/v1/connections'));

  Future<List<Map<String, Object?>>> collections(String connectionId) async =>
      _list(
        await _http.request(
          'GET',
          '/v1/connections/${Uri.encodeComponent(connectionId)}/collections',
        ),
      );

  /// True when the gateway reports that it is ready. Never throws.
  Future<bool> isHealthy() async {
    try {
      await _http.request('GET', '/v1/health');
      return true;
    } on SethuApiError {
      return false;
    }
  }

  /// Releases the underlying HTTP client.
  void close() => _http.close();

  List<Map<String, Object?>> _list(Object? body) {
    final data = body is Map<String, Object?> ? body['data'] : null;
    return data is List
        ? data.whereType<Map<String, Object?>>().toList()
        : <Map<String, Object?>>[];
  }
}
