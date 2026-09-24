import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_agent/services/remote_provider_adapter.dart';
import 'package:private_agent/services/remote_cancellation.dart';

class TestClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  TestClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() { closed = true; }
}

http.StreamedResponse response(int status, {String? body, Map<String, String>? headers}) =>
    http.StreamedResponse(Stream.value(utf8.encode(body ?? jsonEncode({
      'choices': [{'message': {'content': 'Answer'}}],
      'usage': {'total_tokens': 12},
    }))), status, headers: headers ?? {});

Future<RemoteCompletion> complete(RemoteProviderAdapter adapter, {
  RemoteCancellationToken? token, bool stream = false,
}) => adapter.complete(
  baseUrl: 'https://api.deepseek.com', apiKey: 'secret', model: 'deepseek-chat',
  messages: [{'role': 'user', 'content': 'private prompt'}],
  temperature: 1, maxOutputTokens: 100, cancellationToken: token, stream: stream,
);

Matcher errorKind(RemoteErrorKind kind) =>
    isA<RemoteProviderException>().having((e) => e.kind, 'kind', kind);

void main() {
  test('normalizes DeepSeek, NVIDIA and full completion URLs', () {
    expect(RemoteProviderAdapter.endpoint(' https://api.deepseek.com/ ').toString(),
        'https://api.deepseek.com/chat/completions');
    expect(RemoteProviderAdapter.endpoint('https://integrate.api.nvidia.com/v1/').toString(),
        'https://integrate.api.nvidia.com/v1/chat/completions');
    expect(RemoteProviderAdapter.endpoint('https://host/v1/chat/completions/').toString(),
        'https://host/v1/chat/completions');
    expect(RemoteProviderAdapter.endpoint('https://host/v1/chat/completions/', models: true).toString(),
        'https://host/v1/models');
  });

  test('rejects insecure or credential-bearing endpoints', () {
    for (final url in ['http://host', 'https://user:pass@host',
      'https://host?key=secret', 'https://host#secret', 'not a URL']) {
      expect(() => RemoteProviderAdapter.endpoint(url),
          throwsA(errorKind(RemoteErrorKind.invalidEndpoint)));
    }
  });

  for (final status in [401, 403, 400, 302, 404]) {
    test('HTTP $status is not retried or echoed', () async {
      var attempts = 0;
      final adapter = RemoteProviderAdapter(clientFactory: () =>
          TestClient((r) async {
            attempts++;
            expect(r.followRedirects, false);
            return response(status, body: 'private provider error');
          }));
      await expectLater(complete(adapter), throwsA(
          isA<RemoteProviderException>().having((e) => e.toString(),
              'safe message', isNot(contains('private')))));
      expect(attempts, 1);
    });
  }

  for (final status in [429, 503]) {
    test('HTTP $status retries then succeeds', () async {
      var attempts = 0;
      final clients = <TestClient>[];
      final adapter = RemoteProviderAdapter(retryBaseDelay: Duration.zero,
        clientFactory: () {
          final client = TestClient((r) async =>
              response(++attempts < 3 ? status : 200));
          clients.add(client);
          return client;
        });
      final result = await complete(adapter);
      expect(result.content, 'Answer');
      expect(result.totalTokens, 12);
      expect(attempts, 3);
      expect(clients.every((c) => c.closed), true);
    });
  }

  test('network failures retry only within attempt limit', () async {
    var attempts = 0;
    final adapter = RemoteProviderAdapter(retryBaseDelay: Duration.zero,
        clientFactory: () => TestClient((r) async {
          attempts++;
          throw http.ClientException('secret endpoint');
        }));
    await expectLater(complete(adapter), throwsA(errorKind(RemoteErrorKind.network)));
    expect(attempts, 3);
  });

  test('timeout closes client even if transport never resolves', () async {
    final client = TestClient((r) => Completer<http.StreamedResponse>().future);
    final adapter = RemoteProviderAdapter(clientFactory: () => client,
        maxRetries: 0, attemptTimeout: const Duration(milliseconds: 10));
    await expectLater(complete(adapter), throwsA(errorKind(RemoteErrorKind.timeout)));
    expect(client.closed, true);
  });

  test('cancel immediately closes active transport', () async {
    final started = Completer<void>();
    final client = TestClient((r) {
      started.complete();
      return Completer<http.StreamedResponse>().future;
    });
    final token = RemoteCancellationToken();
    final pending = complete(RemoteProviderAdapter(clientFactory: () => client), token: token);
    final expectation = expectLater(pending, throwsA(errorKind(RemoteErrorKind.cancelled)));
    await started.future;
    token.cancel();
    await expectation;
    expect(client.closed, true);
  });

  test('pre-cancelled calls create no transport', () async {
    final token = RemoteCancellationToken()..cancel();
    var created = false;
    final adapter = RemoteProviderAdapter(clientFactory: () {
      created = true;
      return TestClient((r) async => response(200));
    });
    await expectLater(complete(adapter, token: token),
        throwsA(errorKind(RemoteErrorKind.cancelled)));
    expect(created, false);
  });

  test('invalid discovery response is an error, not an empty fallback', () async {
    final adapter = RemoteProviderAdapter(clientFactory: () =>
        TestClient((r) async => response(200, body: '{}')));
    await expectLater(adapter.discover('https://host', 'secret'),
        throwsA(errorKind(RemoteErrorKind.invalidResponse)));
  });

  test('cancel interrupts Retry-After delay without another attempt', () async {
    var attempts = 0;
    final token = RemoteCancellationToken();
    final adapter = RemoteProviderAdapter(clientFactory: () => TestClient((r) async {
      attempts++;
      return response(429, headers: {'retry-after': '999999'});
    }));
    final expectation = expectLater(complete(adapter, token: token),
        throwsA(errorKind(RemoteErrorKind.cancelled)));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    token.cancel();
    await expectation.timeout(const Duration(seconds: 1));
    expect(attempts, 1);
  });

  test('global deadline bounds retry delays', () async {
    final adapter = RemoteProviderAdapter(totalTimeout: const Duration(milliseconds: 20),
      clientFactory: () => TestClient((r) async =>
          response(503, headers: {'retry-after': '999999'})));
    await expectLater(complete(adapter), throwsA(errorKind(RemoteErrorKind.timeout)));
  });

  test('body read is bounded by timeout, including discovery', () async {
    final clients = <TestClient>[];
    final adapter = RemoteProviderAdapter(maxRetries: 0,
      attemptTimeout: const Duration(milliseconds: 10), clientFactory: () {
        final hanging = TestClient((r) async =>
            http.StreamedResponse(StreamController<List<int>>().stream, 200));
        clients.add(hanging);
        return hanging;
      });
    await expectLater(adapter.discover('https://host/v1', 'secret'),
        throwsA(errorKind(RemoteErrorKind.timeout)));
    expect(clients.single.closed, true);
  });

  for (final body in ['not json', '{}', '{"choices":[]}',
    '{"choices":[{"message":{"content":null}}]}',
    '{"choices":[{"message":{"content":"<think>hidden"}}]}',
    '{"choices":[{"message":{"content":"ok"}}],"usage":{"total_tokens":"12"}}']) {
    test('invalid completion is typed and never retried: $body', () async {
      var attempts = 0;
      final adapter = RemoteProviderAdapter(clientFactory: () => TestClient((r) async {
        attempts++;
        return response(200, body: body);
      }));
      await expectLater(complete(adapter), throwsA(errorKind(RemoteErrorKind.invalidResponse)));
      expect(attempts, 1);
    });
  }

  test('SSE split reasoning tags are withheld', () async {
    final body = ['<thi', 'nk>hidden', '</thi', 'nk>Visible'].map((part) =>
        'data: ${jsonEncode({'choices': [{'delta': {'content': part}}]})}\n\n').join();
    final adapter = RemoteProviderAdapter(clientFactory: () => TestClient((r) async =>
        response(200, body: '${body}data: [DONE]\n\n')));
    expect((await complete(adapter, stream: true)).content, 'Visible');
  });

  test('truncated SSE is not silently accepted', () async {
    final adapter = RemoteProviderAdapter(clientFactory: () => TestClient((r) async =>
        response(200, body: 'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')));
    await expectLater(complete(adapter, stream: true),
        throwsA(errorKind(RemoteErrorKind.invalidResponse)));
  });

  test('oversized response fails explicitly', () async {
    final adapter = RemoteProviderAdapter(clientFactory: () => TestClient((r) async =>
        response(200, body: 'x' * (RemoteProviderAdapter.maxResponseBytes + 1))));
    await expectLater(complete(adapter), throwsA(errorKind(RemoteErrorKind.invalidResponse)));
  });
}