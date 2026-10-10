/// Every failed API call throws an [SethuApiError]. Check [code] to decide what to do.
class SethuApiError implements Exception {
  SethuApiError(
    this.code,
    this.message, {
    required this.status,
    this.details,
    this.requestId,
    this.retryAfter,
  });

  /// One of: CONNECTION_FAILED, AUTH_FAILED, FORBIDDEN, READ_ONLY, NOT_FOUND, CONFLICT,
  /// VALIDATION_FAILED, CAPABILITY_UNSUPPORTED, RATE_LIMITED, TIMEOUT, INTERNAL.
  final String code;
  final String message;

  /// HTTP status, or 0 when the request never reached the server.
  final int status;
  final Object? details;

  /// Quote this when asking for support.
  final String? requestId;

  /// What the server asked for in `Retry-After`, if anything.
  final Duration? retryAfter;

  @override
  String toString() => 'SethuApiError($code, status $status): $message';
}

const _knownCodes = {
  'CONNECTION_FAILED',
  'AUTH_FAILED',
  'FORBIDDEN',
  'READ_ONLY',
  'NOT_FOUND',
  'CONFLICT',
  'VALIDATION_FAILED',
  'CAPABILITY_UNSUPPORTED',
  'RATE_LIMITED',
  'TIMEOUT',
  'INTERNAL',
};

String codeFromStatus(int status) {
  switch (status) {
    case 400:
    case 422:
      return 'VALIDATION_FAILED';
    case 401:
      return 'AUTH_FAILED';
    case 403:
      return 'FORBIDDEN';
    case 404:
      return 'NOT_FOUND';
    case 409:
      return 'CONFLICT';
    case 429:
      return 'RATE_LIMITED';
    case 502:
      return 'CONNECTION_FAILED';
    case 504:
      return 'TIMEOUT';
    default:
      return 'INTERNAL';
  }
}

/// Builds an error from a failed response body. Never repeats the raw body,
/// which could be an HTML error page.
SethuApiError errorFromResponse(
  int status,
  Object? body, {
  Duration? retryAfter,
}) {
  final error = body is Map<String, Object?> ? body['error'] : null;
  if (error is Map<String, Object?>) {
    final code = error['code'];
    final message = error['message'];
    final requestId = error['requestId'];
    return SethuApiError(
      code is String && _knownCodes.contains(code)
          ? code
          : codeFromStatus(status),
      message is String ? message : 'Request failed',
      status: status,
      details: error['details'],
      requestId: requestId is String ? requestId : null,
      retryAfter: retryAfter,
    );
  }
  return SethuApiError(
    codeFromStatus(status),
    'The server answered with status $status',
    status: status,
    retryAfter: retryAfter,
  );
}
