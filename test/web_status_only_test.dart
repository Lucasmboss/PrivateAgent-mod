import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_agent/services/web_service.dart';

void main() {
  test('status-only probe never exposes the response body', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      return http.Response('198.51.100.27 private response content', 200);
    });
    final service = WebService(client: client);

    final status = await service.getStatusOnly(
      url: 'https://api.ipify.org?format=json',
    );

    expect(status, 200);
    client.close();
  });
}