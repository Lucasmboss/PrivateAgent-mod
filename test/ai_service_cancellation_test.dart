import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/remote_provider_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PendingClient extends http.BaseClient {
  final Completer<void> started;
  bool closed = false;

  _PendingClient(this.started);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    started.complete();
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('message stream forwards cancellation to the active provider request',
      () async {
    SharedPreferences.setMockInitialValues({});
    final started = Completer<void>();
    final client = _PendingClient(started);
    final service = AiService(
      remoteProvider: RemoteProviderAdapter(
        clientFactory: () => client,
        maxRetries: 0,
      ),
    );
    await service.saveSettings(apiKey: 'test-key');

    final cancellation = RemoteCancellationToken();
    final pending = service
        .sendMessageStream('Hello', cancellationToken: cancellation)
        .toList();
    final expectation = expectLater(
      pending,
      throwsA(
        isA<RemoteProviderException>().having(
          (error) => error.kind,
          'kind',
          RemoteErrorKind.cancelled,
        ),
      ),
    );

    await started.future.timeout(const Duration(seconds: 1));
    cancellation.cancel();
    await expectation.timeout(const Duration(seconds: 1));

    expect(client.closed, isTrue);
  });
}