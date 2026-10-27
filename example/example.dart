import 'package:sethucms/sethucms.dart';

/// Lists the first page of paid orders. Replace the address, the token and the
/// connection id with your own.
Future<void> main() async {
  final cms = SethuClient(
    'https://cms.example.com',
    token: () => 'YOUR_API_TOKEN',
  );

  try {
    if (!await cms.isHealthy()) {
      print('The gateway is not ready.');
      return;
    }

    final page = await cms
        .collection('conn_123', 'orders')
        .where(eq('status', 'paid'))
        .orderBy('created_at', descending: true)
        .limit(20)
        .list();

    for (final order in page.data) {
      print(order);
    }
    print('More pages: ${page.nextCursor != null}');
  } on SethuApiError catch (error) {
    print('The gateway answered with an error: $error');
  } finally {
    cms.close();
  }
}
