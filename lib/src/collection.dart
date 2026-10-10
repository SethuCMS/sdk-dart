import 'dart:convert';
import 'dart:math';

import 'filters.dart';
import 'http_client.dart';

typedef RecordData = Map<String, Object?>;

/// One page of results.
class ListResult {
  const ListResult({
    required this.data,
    required this.nextCursor,
    required this.limit,
    required this.notes,
  });

  final List<RecordData> data;

  /// Pass to [QueryBuilder.after] to get the next page. Null on the last page.
  final String? nextCursor;
  final int limit;

  /// Notes from the server, for example "sorting needs an index".
  final List<String> notes;
}

String _enc(Object value) => Uri.encodeComponent(value.toString());

/// One collection of one connection. Create it with `client.collection(connectionId, name)`.
class Collection {
  Collection(this._http, String connectionId, String name)
      : _base =
            '/v1/connections/${_enc(connectionId)}/collections/${_enc(name)}/records';

  final ApiHttp _http;
  final String _base;

  QueryBuilder query() => QueryBuilder._(this, const _State());

  /// Shortcut for `query().where(filter)`.
  QueryBuilder where(Filter filter) => query().where(filter);

  Future<RecordData> get(Object id) async =>
      _record(await _http.request('GET', '$_base/${_enc(id)}'));

  /// Creates a record. A random idempotency key is added so a retried write cannot happen twice.
  Future<RecordData> create(
    RecordData values, {
    String? idempotencyKey,
  }) async =>
      _record(
        await _http.request(
          'POST',
          _base,
          body: values,
          idempotencyKey: idempotencyKey ?? _newKey(),
        ),
      );

  Future<RecordData> update(
    Object id,
    RecordData values, {
    String? idempotencyKey,
  }) async =>
      _record(
        await _http.request(
          'PATCH',
          '$_base/${_enc(id)}',
          body: values,
          idempotencyKey: idempotencyKey ?? _newKey(),
        ),
      );

  Future<void> delete(Object id, {String? idempotencyKey}) async {
    await _http.request(
      'DELETE',
      '$_base/${_enc(id)}',
      idempotencyKey: idempotencyKey ?? _newKey(),
    );
  }

  Future<ListResult> _runList(_State state) async {
    final filters = state.filters;
    final body = await _http.request(
      'GET',
      _base,
      query: {
        'filter': filters.isEmpty
            ? null
            : jsonEncode(filters.length == 1 ? filters.first : and(filters)),
        'sort': state.sorts.isEmpty
            ? null
            : state.sorts
                .map((s) => s.descending ? '-${s.field}' : s.field)
                .join(','),
        'fields': state.fields.isEmpty ? null : state.fields.join(','),
        'limit': state.limit?.toString(),
        'cursor': state.cursor,
      },
    );
    final map = body is Map<String, Object?> ? body : const <String, Object?>{};
    final page = map['page'] is Map<String, Object?>
        ? map['page']! as Map<String, Object?>
        : const <String, Object?>{};
    final meta = map['meta'] is Map<String, Object?>
        ? map['meta']! as Map<String, Object?>
        : const <String, Object?>{};
    final data = map['data'];
    return ListResult(
      data: data is List
          ? data.whereType<Map<String, Object?>>().toList()
          : <RecordData>[],
      nextCursor: page['nextCursor'] as String?,
      limit: (page['limit'] as num?)?.toInt() ?? 0,
      notes: (meta['capabilityNotes'] is List)
          ? (meta['capabilityNotes']! as List).whereType<String>().toList()
          : <String>[],
    );
  }

  RecordData _record(Object? body) {
    final data = body is Map<String, Object?> ? body['data'] : null;
    return data is Map<String, Object?> ? data : <String, Object?>{};
  }
}

class _Sort {
  const _Sort(this.field, this.descending);
  final String field;
  final bool descending;
}

class _State {
  const _State({
    this.filters = const [],
    this.sorts = const [],
    this.fields = const [],
    this.limit,
    this.cursor,
  });

  final List<Filter> filters;
  final List<_Sort> sorts;
  final List<String> fields;
  final int? limit;
  final String? cursor;

  _State copy({
    List<Filter>? filters,
    List<_Sort>? sorts,
    List<String>? fields,
    int? limit,
    String? cursor,
    bool clearCursor = false,
  }) =>
      _State(
        filters: filters ?? this.filters,
        sorts: sorts ?? this.sorts,
        fields: fields ?? this.fields,
        limit: limit ?? this.limit,
        cursor: clearCursor ? null : (cursor ?? this.cursor),
      );
}

/// A query under construction. Every method returns a new builder, so builders can be reused safely.
class QueryBuilder {
  QueryBuilder._(this._collection, this._state);

  final Collection _collection;
  final _State _state;

  /// Adds a filter. Calling this more than once means "all of these must match".
  QueryBuilder where(Filter filter) => QueryBuilder._(
        _collection,
        _state.copy(filters: [..._state.filters, filter]),
      );

  QueryBuilder orderBy(String field, {bool descending = false}) =>
      QueryBuilder._(
        _collection,
        _state.copy(sorts: [..._state.sorts, _Sort(field, descending)]),
      );

  /// Return only these fields.
  QueryBuilder select(List<String> fields) => QueryBuilder._(
        _collection,
        _state.copy(fields: [..._state.fields, ...fields]),
      );

  QueryBuilder limit(int count) {
    if (count < 1) {
      throw RangeError('limit must be a whole number of at least 1');
    }
    return QueryBuilder._(_collection, _state.copy(limit: count));
  }

  /// Continue after a previous page.
  QueryBuilder after(String? cursor) => QueryBuilder._(
        _collection,
        _state.copy(cursor: cursor, clearCursor: cursor == null),
      );

  /// Fetches one page.
  Future<ListResult> list() => _collection._runList(_state);

  /// The first matching record, or null.
  Future<RecordData?> first() async {
    final page = await limit(1).list();
    return page.data.isEmpty ? null : page.data.first;
  }

  /// Walks every matching record, page after page:
  ///
  ///     await for (final order in orders.where(eq('status', 'paid')).iterate()) { ... }
  Stream<RecordData> iterate({int maxPages = 10000}) async* {
    var builder = this;
    for (var page = 0; page < maxPages; page++) {
      final result = await builder.list();
      yield* Stream.fromIterable(result.data);
      final next = result.nextCursor;
      if (next == null || next.isEmpty) return;
      builder = builder.after(next);
    }
    throw RangeError(
      'Stopped after $maxPages pages. Raise maxPages if this is expected.',
    );
  }
}

final _rng = Random.secure();

/// A random UUID v4, built without extra packages.
String _newKey() {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
