import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_agent/services/web_service.dart';

void main() {
  test('sends a GET request with headers and returns the response', () async {
    final service = WebService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://api.example.test/status');
        expect(request.headers['Authorization'], 'Bearer test-token');
        expect(request.headers['Accept'], contains('application/json'));

        return http.Response(
          '{"online":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await service.request(
      method: 'get',
      url: 'https://api.example.test/status',
      headers: {'Authorization': 'Bearer test-token'},
    );

    expect(result, 'HTTP 200\n{"online":true}');
    expect(WebService.isSuccessfulResponse(result), isTrue);
  });

  test('encodes map bodies as JSON for write requests', () async {
    final service = WebService(
      client: MockClient((request) async {
        final typedRequest = request as http.Request;

        expect(typedRequest.method, 'POST');
        expect(typedRequest.headers['Content-Type'], 'application/json');
        expect(
          typedRequest.body,
          '{"name":"PrivateAgent","enabled":true}',
        );

        return http.Response('{"created":true}', 201);
      }),
    );

    final result = await service.request(
      method: 'POST',
      url: 'https://api.example.test/agents',
      body: {'name': 'PrivateAgent', 'enabled': true},
    );

    expect(result, 'HTTP 201\n{"created":true}');
  });

  test('supports PATCH and DELETE methods', () async {
    final requests = <String>[];
    final service = WebService(
      client: MockClient((request) async {
        requests.add(request.method);
        return http.Response('', request.method == 'PATCH' ? 200 : 204);
      }),
    );

    await service.request(
      method: 'PATCH',
      url: 'https://api.example.test/agents/1',
      body: {'enabled': false},
    );
    await service.request(
      method: 'DELETE',
      url: 'https://api.example.test/agents/1',
    );

    expect(requests, ['PATCH', 'DELETE']);
  });

  test('rejects unsupported methods and non-http URLs before sending', () async {
    var sendCount = 0;
    final service = WebService(
      client: MockClient((request) async {
        sendCount++;
        return http.Response.ok('');
      }),
    );

    final methodResult = await service.request(
      method: 'OPTIONS',
      url: 'https://api.example.test/status',
    );
    final urlResult = await service.request(
      method: 'GET',
      url: 'file:///data/local.txt',
    );

    expect(methodResult, contains('unsupported HTTP method'));
    expect(urlResult, contains('valid http or https URL'));
    expect(sendCount, 0);
  });

  test('marks HTTP errors as unsuccessful', () async {
    final service = WebService(
      client: MockClient((request) async => http.Response('not found', 404)),
    );

    final result = await service.request(
      method: 'GET',
      url: 'https://api.example.test/missing',
    );

    expect(result, 'HTTP 404\nnot found');
    expect(WebService.isSuccessfulResponse(result), isFalse);
  });

  test('truncates oversized response bodies', () async {
    final largeBody =
        List.filled(WebService.maxResponseLength + 10, 'x').join();

    final service = WebService(
      client: MockClient(
        (request) async => http.Response(
          largeBody,
          200,
        ),
      ),
    );

    final result = await service.request(
      method: 'GET',
      url: 'https://api.example.test/large',
    );

    final truncatedBody =
        List.filled(WebService.maxResponseLength, 'x').join();

    expect(result, startsWith('HTTP 200\n$truncatedBody'));
    expect(result, endsWith('[Response truncated]'));
  });
}