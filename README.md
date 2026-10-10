# sethucms (Dart and Flutter SDK)

Client for the SethuCMS API. Works in Dart, Flutter (mobile, web and desktop). One dependency: `package:http`.

```dart
import 'package:sethucms/sethucms.dart';

final cms = SethuClient('https://cms.example.com', token: () => getAccessToken());
final orders = cms.collection('conn_123', 'orders');

// One page
final page = await orders
    .where(eq('status', 'paid'))
    .where(gt('total', 100))
    .orderBy('created_at', descending: true)
    .limit(20)
    .list();
print(page.data);
print(page.nextCursor);

// Every matching record, page after page
await for (final order in orders.where(eq('status', 'paid')).iterate()) {
  print(order);
}

// Writes (a random idempotency key is added, so a retried write cannot happen twice)
final created = await orders.create({'status': 'new'});
await orders.update(created['id']!, {'status': 'paid'});
await orders.delete(created['id']!);
```

## Errors

Every failure throws `SethuApiError` with a stable `code`:

```dart
try {
  await orders.create({'status': 'new'});
} on SethuApiError catch (error) {
  if (error.code == 'READ_ONLY') {
    // This connection does not allow writes.
  }
  print(error.requestId); // quote this when asking for support
}
```

Codes: `CONNECTION_FAILED`, `AUTH_FAILED`, `FORBIDDEN`, `READ_ONLY`, `NOT_FOUND`, `CONFLICT`,
`VALIDATION_FAILED`, `CAPABILITY_UNSUPPORTED`, `RATE_LIMITED`, `TIMEOUT`, `INTERNAL`.

## Safety defaults

- `https` only (plain `http` only for localhost). A URL with a password in it is refused.
- The token travels in a header, never in the URL.
- Redirects are never followed, so the token cannot be sent to another address.
- Reads are retried (rate limits, 502/503/504, network errors) and honour `Retry-After`; writes are never retried.
- Error messages never repeat the server's raw response or the network library's message.
- The default timeout is 30 seconds.

## Filters

`eq, ne, lt, lte, gt, gte, isIn, notIn, contains, startsWith, exists` and the combinators
`and([...]), or([...]), not(filter)`. They return plain maps, so a filter can be stored as JSON.

## Flutter tip

Do not put a long-lived token in the app. Pass a function that fetches a short-lived one:
`token: () => auth.currentAccessToken()`.

## Develop

```bash
dart pub get
dart analyze
dart test
```
