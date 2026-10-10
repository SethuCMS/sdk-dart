import 'dart:async';
import 'dart:convert';

import 'package:sethucms/sethucms.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// What the fake server saw.
class Seen {
  Seen(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Object? body;
}

/// A scripted server: records every request and answers from a queue.
/// An answer can be an `http.Response`, a function, or an exception to throw.
class Script {
  Script(this.answers);
  final List<Object> answers;
  final List<Seen> seen = [];

  http.Client client() => MockClient((request) async {
        seen.add(Seen(request.method, request.url, request.headers,
            request.body.isEmpty ? null : jsonDecode(request.body)));
        if (answers.isEmpty) throw StateError('no scripted answer left');
        final next = answers.removeAt(0);
        if (next is http.Response) return next;
        throw next;
      });
}

http.Response json(Object? body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

http.Response page(List<Object?> data, {String? cursor, int limit = 50, List<String>? notes}) => json({
      'data': data,
      'page': {'nextCursor': cursor, 'limit': limit},
      if (notes != null) 'meta': {'capabilityNotes': notes},
    });

SethuClient clientFor(Script script, {TokenSource? token, int maxRetries = 2, List<Duration>? sleeps}) => SethuClient(
      'https://cms.example.com',
      token: token ?? () => 'tok_123',
      httpClient: script.client(),
      maxRetries: maxRetries,
      sleep: (d) async => sleeps?.add(d),
    );

void main() {
  test('list builds the request from the query and reads the page', () async {
    final script = Script([page([{'id': 1}], cursor: 'abc', limit: 20, notes: ['note'])]);
    final result = await clientFor(script)
        .collection('c 1', 'orders')
        .where(eq('status', 'paid'))
        .where(gt('total', 5))
        .orderBy('created_at', descending: true)
        .orderBy('id')
        .select(['id', 'status'])
        .limit(20)
        .list();

    final request = script.seen.first;
    expect(request.url.path, '/v1/connections/c%201/collections/orders/records');
    expect(request.url.queryParameters['sort'], '-created_at,id');
    expect(request.url.queryParameters['fields'], 'id,status');
    expect(request.url.queryParameters['limit'], '20');
    expect(jsonDecode(request.url.queryParameters['filter']!), jsonDecode(jsonEncode(and([eq('status', 'paid'), gt('total', 5)]))));
    expect(result.data, [{'id': 1}]);
    expect(result.nextCursor, 'abc');
    expect(result.limit, 20);
    expect(result.notes, ['note']);
  });

  test('a single filter is sent as is, and no filter sends none', () async {
    final script = Script([page([]), page([])]);
    final c = clientFor(script).collection('c', 'x');
    await c.where(eq('a', 1)).list();
    await c.query().list();
    expect(jsonDecode(script.seen[0].url.queryParameters['filter']!), eq('a', 1));
    expect(script.seen[1].url.queryParameters.containsKey('filter'), isFalse);
  });

  test('the token is sent in a header, never in the URL, and a token function is asked every time', () async {
    final script = Script([page([]), page([])]);
    var calls = 0;
    final c = clientFor(script, token: () => 't${++calls}').collection('c', 'x');
    await c.query().list();
    await c.query().list();
    expect(script.seen[0].headers['Authorization'], 'Bearer t1');
    expect(script.seen[1].headers['Authorization'], 'Bearer t2');
    expect(script.seen[0].url.toString(), isNot(contains('t1')));
  });

  test('writes use the right verbs, bodies and an idempotency key', () async {
    final script = Script([
      json({'data': {'id': 1}}, status: 201),
      json({'data': {'id': 1}}),
      http.Response('', 204),
    ]);
    final c = clientFor(script).collection('c', 'x');
    await c.create({'a': 1});
    await c.update(1, {'a': 2}, idempotencyKey: 'mine');
    await c.delete(1);
    expect(script.seen.map((s) => s.method), ['POST', 'PATCH', 'DELETE']);
    expect(script.seen[0].body, {'a': 1});
    expect(script.seen[0].headers['Idempotency-Key'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(script.seen[1].headers['Idempotency-Key'], 'mine');
    expect(script.seen[2].headers['Idempotency-Key'], isNotEmpty);
  });

  test('record ids are encoded so they cannot change the path', () async {
    final script = Script([json({'data': <String, Object?>{}})]);
    await clientFor(script).collection('c', 'x').get('../admin?x=1');
    expect(script.seen.first.url.path, '/v1/connections/c/collections/x/records/..%2Fadmin%3Fx%3D1');
  });

  test('API errors become typed errors with the request id', () async {
    final script = Script([json({'error': {'code': 'READ_ONLY', 'message': 'no writes', 'requestId': 'r1'}}, status: 403)]);
    await expectLater(
      clientFor(script).collection('c', 'x').create({}),
      throwsA(isA<SethuApiError>()
          .having((e) => e.code, 'code', 'READ_ONLY')
          .having((e) => e.status, 'status', 403)
          .having((e) => e.requestId, 'requestId', 'r1')),
    );
  });

  test('non-JSON failures use the status and never repeat the body', () async {
    final script = Script([http.Response('<html>secret stack trace</html>', 500)]);
    await expectLater(
      clientFor(script).collection('c', 'x').get(1),
      throwsA(isA<SethuApiError>()
          .having((e) => e.code, 'code', 'INTERNAL')
          .having((e) => e.toString(), 'text', isNot(contains('secret')))),
    );
  });

  test('reads are retried on temporary failures, honouring Retry-After', () async {
    final script = Script([json({}, status: 503, headers: {'retry-after': '2'}), json({}, status: 429), page([{'id': 1}])]);
    final sleeps = <Duration>[];
    final result = await clientFor(script, sleeps: sleeps).collection('c', 'x').query().list();
    expect(result.data, [{'id': 1}]);
    expect(script.seen.length, 3);
    expect(sleeps.first, const Duration(seconds: 2));
    expect(sleeps[1], greaterThan(Duration.zero));
  });

  test('reads give up after maxRetries; writes are never retried', () async {
    var script = Script([json({}, status: 503), json({}, status: 503), json({}, status: 503)]);
    await expectLater(clientFor(script).collection('c', 'x').get(1), throwsA(isA<SethuApiError>()));
    expect(script.seen.length, 3);

    script = Script([json({}, status: 503)]);
    await expectLater(clientFor(script).collection('c', 'x').create({}), throwsA(isA<SethuApiError>()));
    expect(script.seen.length, 1);
  });

  test('client errors are not retried', () async {
    final script = Script([json({'error': {'code': 'NOT_FOUND', 'message': 'x'}}, status: 404)]);
    await expectLater(
      clientFor(script).collection('c', 'x').get(1),
      throwsA(isA<SethuApiError>().having((e) => e.code, 'code', 'NOT_FOUND')),
    );
    expect(script.seen.length, 1);
  });

  test('iterate follows cursors until the last page', () async {
    final script = Script([page([{'id': 1}, {'id': 2}], cursor: 'p2'), page([{'id': 3}])]);
    final ids = await clientFor(script).collection('c', 'x').query().iterate().map((r) => r['id']).toList();
    expect(ids, [1, 2, 3]);
    expect(script.seen[1].url.queryParameters['cursor'], 'p2');
  });

  test('iterate stops with an error instead of looping forever', () async {
    final script = Script(List.generate(5, (_) => page([{'id': 1}], cursor: 'again')));
    await expectLater(
      clientFor(script).collection('c', 'x').query().iterate(maxPages: 3).toList(),
      throwsA(isA<RangeError>()),
    );
  });

  test('first returns one record or null', () async {
    final script = Script([page([{'id': 9}]), page([])]);
    final q = clientFor(script).collection('c', 'x').query();
    expect(await q.first(), {'id': 9});
    expect(script.seen.first.url.queryParameters['limit'], '1');
    expect(await q.first(), isNull);
  });

  test('builders are immutable, so a base query can be reused', () async {
    final script = Script([page([]), page([])]);
    final base = clientFor(script).collection('c', 'x').where(eq('a', 1));
    await base.limit(5).list();
    await base.list();
    expect(script.seen[0].url.queryParameters['limit'], '5');
    expect(script.seen[1].url.queryParameters.containsKey('limit'), isFalse);
  });

  test('limit must be at least 1', () {
    final q = clientFor(Script([])).collection('c', 'x').query();
    expect(() => q.limit(0), throwsA(isA<RangeError>()));
  });

  test('base URL safety', () {
    SethuClient('https://cms.example.com/');
    SethuClient('http://localhost:8080');
    for (final bad in ['http://cms.example.com', 'ftp://x.com', 'not a url', 'https://user:pw@cms.example.com', '']) {
      expect(() => SethuClient(bad), throwsA(isA<ArgumentError>()), reason: bad);
    }
    SethuClient('http://cms.internal', allowInsecureHttp: true);
  });

  test('network failure and timeout become typed errors without leaking the cause', () async {
    var script = Script([TimeoutException('slow')]);
    await expectLater(
      clientFor(script, maxRetries: 0).collection('c', 'x').get(1),
      throwsA(isA<SethuApiError>().having((e) => e.code, 'code', 'TIMEOUT')),
    );
    script = Script([http.ClientException('connect to 10.0.0.5 refused')]);
    await expectLater(
      clientFor(script, maxRetries: 0).collection('c', 'x').get(1),
      throwsA(isA<SethuApiError>()
          .having((e) => e.code, 'code', 'CONNECTION_FAILED')
          .having((e) => e.toString(), 'text', isNot(contains('10.0.0.5')))),
    );
  });

  test('the SDK timer turns a hanging server into TIMEOUT', () async {
    final client = SethuClient(
      'https://cms.example.com',
      httpClient: MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 50),
      maxRetries: 0,
    );
    await expectLater(
      client.collection('c', 'x').get(1),
      throwsA(isA<SethuApiError>().having((e) => e.code, 'code', 'TIMEOUT')),
    );
  });

  test('network failures on reads are retried', () async {
    final script = Script([http.ClientException('x'), page([])]);
    await clientFor(script).collection('c', 'x').query().list();
    expect(script.seen.length, 2);
  });

  test('health check never throws', () async {
    expect(await clientFor(Script([http.ClientException('x')]), maxRetries: 0).isHealthy(), isFalse);
    expect(await clientFor(Script([json({'status': 'ok'})])).isHealthy(), isTrue);
  });
}
