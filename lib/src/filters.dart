/// Building filters. Each helper returns plain data (a map) that the API understands,
/// so filters can also be stored or sent as JSON.
typedef Filter = Map<String, Object?>;

Filter _compare(String field, String op, Object? value) => {
      'field': field,
      'op': op,
      'value': value,
    };

Filter eq(String field, Object? value) => _compare(field, 'eq', value);
Filter ne(String field, Object? value) => _compare(field, 'ne', value);
Filter lt(String field, Object? value) => _compare(field, 'lt', value);
Filter lte(String field, Object? value) => _compare(field, 'lte', value);
Filter gt(String field, Object? value) => _compare(field, 'gt', value);
Filter gte(String field, Object? value) => _compare(field, 'gte', value);
Filter isIn(String field, List<Object?> values) =>
    _compare(field, 'in', List<Object?>.of(values));
Filter notIn(String field, List<Object?> values) =>
    _compare(field, 'nin', List<Object?>.of(values));
Filter contains(String field, Object value) =>
    _compare(field, 'contains', value);
Filter startsWith(String field, String value) =>
    _compare(field, 'startsWith', value);
Filter exists(String field, {bool present = true}) =>
    _compare(field, 'exists', present);

Filter and(List<Filter> filters) => {'and': List<Filter>.of(filters)};
Filter or(List<Filter> filters) => {'or': List<Filter>.of(filters)};
Filter not(Filter filter) => {'not': filter};
