import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'remote_cancellation.dart';

enum RemoteErrorKind {
  authentication, rateLimit, network, timeout, cancelled,
  invalidEndpoint, invalidRequest, invalidResponse, httpError,
}

/// Deliberately contains no provider body, URL, credentials, or prompt.
class RemoteProviderException implements Exception {
  final RemoteErrorKind kind;
  final int? statusCode;
  const RemoteProviderException(this.kind, {this.statusCode});
  @override
  String toString() => 'Remote AI error: ${kind.name}'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

class RemoteCompletion {
  final String content;
  final int totalTokens;
  const RemoteCompletion(this.content, this.totalTokens);
}

/// Each attempt owns a client. Closing it aborts actual I/O, not just awaiting.
/// Limits also apply to discovery and SSE, including bodies that never finish.
class RemoteProviderAdapter {
  static const maxResponseBytes = 1024 * 1024;
  static const maxRequestBytes = 512 * 1024;
  static const maxContentCharacters = 128 * 1024;
  final http.Client Function() _clientFactory;
  final Duration attemptTimeout;
  final Duration totalTimeout;
  final Duration retryBaseDelay;
  final int maxRetries;

  RemoteProviderAdapter({
    http.Client Function()? clientFactory,
    this.attemptTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(seconds: 90),
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.maxRetries = 2,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    if (attemptTimeout <= Duration.zero ||
        attemptTimeout > const Duration(seconds: 60) ||
        totalTimeout <= Duration.zero ||
        totalTimeout > const Duration(seconds: 120) ||
        retryBaseDelay < Duration.zero ||
        retryBaseDelay > const Duration(seconds: 5) ||
        maxRetries < 0 || maxRetries > 3) {
      throw ArgumentError('Remote limits outside supported bounds');
    }
  }

  static Uri endpoint(String baseUrl, {bool models = false}) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        baseUrl.contains('\\') ||
        uri.pathSegments.any((s) => s == '..' || s == '.' ||
            s.contains('/') || s.contains('\\'))) {
      throw const RemoteProviderException(RemoteErrorKind.invalidEndpoint);
    }
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/chat/completions')) {
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    return uri.replace(path: '$path/${models ? 'models' : 'chat/completions'}');
  }

  Future<RemoteCompletion> complete({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
    required double temperature,
    required int maxOutputTokens,
    RemoteCancellationToken? cancellationToken,
    bool stream = false,
  }) async {
    if (maxOutputTokens < 1 || maxOutputTokens > 32768 ||
        !temperature.isFinite || messages.isEmpty || messages.length > 64) {
      throw const RemoteProviderException(RemoteErrorKind.invalidRequest);
    }
    final body = jsonEncode({
      'model': model, 'messages': messages, 'temperature': temperature,
      'max_tokens': maxOutputTokens, if (stream) 'stream': true,
    });
    if (utf8.encode(body).length > maxRequestBytes) {
      throw const RemoteProviderException(RemoteErrorKind.invalidRequest);
    }
    final text = await _request(endpoint(baseUrl), apiKey,
        body: body, cancellationToken: cancellationToken);
    return stream ? _parseSse(text) : _parseCompletion(_decode(text));
  }

  Future<List<String>> discover(String baseUrl, String apiKey,
      {RemoteCancellationToken? cancellationToken}) async {
    final data = _decode(await _request(endpoint(baseUrl, models: true),
        apiKey, cancellationToken: cancellationToken));
    final items = data is Map ? data['data'] : data;
    if (items is! List || items.length > 10000) _invalid();
    final result = <String>[];
    for (final item in items) {
      if (item is! Map || item['id'] is! String ||
          (item['id'] as String).isEmpty) _invalid();
      result.add(item['id'] as String);
    }
    return result..sort();
  }

  Future<String> _request(Uri uri, String apiKey, {
    String? body, RemoteCancellationToken? cancellationToken,
  }) async {
    if (apiKey.trim().isEmpty || apiKey.contains('\r') || apiKey.contains('\n')) {
      throw const RemoteProviderException(RemoteErrorKind.authentication);
    }
    final scope = RemoteCancellationToken();
    var expired = false;
    final remove = cancellationToken?.onCancel(scope.cancel);
    final deadline = Timer(totalTimeout, () {
      expired = true;
      scope.cancel();
    });
    void check() {
      if (scope.isCancelled) {
        throw RemoteProviderException(expired
            ? RemoteErrorKind.timeout : RemoteErrorKind.cancelled);
      }
    }
    try {
      for (var attempt = 0; ; attempt++) {
        check();
        final client = _clientFactory();
        final aborted = Completer<String>();
        final detach = scope.onCancel(() {
          client.close();
          if (!aborted.isCompleted) {
            aborted.completeError(RemoteProviderException(expired
                ? RemoteErrorKind.timeout : RemoteErrorKind.cancelled));
          }
        });
        var delay = Duration(milliseconds:
            (retryBaseDelay.inMilliseconds * (1 << attempt)).clamp(0, 5000));
        try {
          Future<String> exchange() async {
            final request = http.Request(body == null ? 'GET' : 'POST', uri)
              ..followRedirects = false
              ..headers.addAll({
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
                'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
                'X-Title': 'PrivateAgent',
              });
            if (body != null) request.body = body;
            final response = await client.send(request);
            if (response.statusCode != 200) {
              final retryAfter = response.headers['retry-after'];
              final seconds = int.tryParse(retryAfter ?? '');
              if (seconds != null) {
                delay = Duration(seconds: seconds.clamp(0, 5));
              } else if (retryAfter != null) {
                try {
                  delay = Duration(milliseconds: HttpDate.parse(retryAfter)
                      .difference(DateTime.now()).inMilliseconds.clamp(0, 5000));
                } on FormatException { /* Keep bounded backoff. */ }
              }
              throw RemoteProviderException(
                response.statusCode == 401 || response.statusCode == 403
                    ? RemoteErrorKind.authentication
                    : response.statusCode == 429
                        ? RemoteErrorKind.rateLimit : RemoteErrorKind.httpError,
                statusCode: response.statusCode,
              );
            }
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > maxResponseBytes) _invalid();
              bytes.addAll(chunk);
            }
            try {
              return utf8.decode(bytes);
            } on FormatException {
              _invalid();
            }
          }
          return await Future.any([exchange(), aborted.future])
              .timeout(attemptTimeout, onTimeout: () {
            client.close();
            throw const RemoteProviderException(RemoteErrorKind.timeout);
          });
        } catch (error) {
          check();
          final RemoteProviderException failure;
          if (error is RemoteProviderException) {
            failure = error;
          } else if (error is http.ClientException || error is IOException) {
            failure = const RemoteProviderException(RemoteErrorKind.network);
          } else {
            // Do not echo exceptions that might include URLs or credentials.
            throw const RemoteProviderException(RemoteErrorKind.invalidResponse);
          }
          final transient = failure.kind == RemoteErrorKind.network ||
              failure.kind == RemoteErrorKind.timeout ||
              const [408, 429, 500, 502, 503, 504].contains(failure.statusCode);
          if (!transient || attempt >= maxRetries) throw failure;
        } finally {
          detach();
          client.close();
        }
        await scope.delay(delay);
        check();
      }
    } finally {
      deadline.cancel();
      remove?.call();
    }
  }

  static Never _invalid() =>
      throw const RemoteProviderException(RemoteErrorKind.invalidResponse);

  static dynamic _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      _invalid();
    }
  }

  static String _visible(String content) {
    // Unclosed reasoning blocks are withheld too. Dedicated reasoning fields
    // are never read. SSE is buffered so split tags cannot leak reasoning.
    final visible = content.replaceAll(
        RegExp(r'<think\b[^>]*>.*?(?:</think\s*>|$)',
            dotAll: true, caseSensitive: false), '').trim();
    if (visible.isEmpty || visible.length > maxContentCharacters ||
        visible.toLowerCase().contains('</think')) _invalid();
    return visible;
  }

  static RemoteCompletion _parseCompletion(dynamic data) {
    if (data is! Map || data['choices'] is! List ||
        (data['choices'] as List).isEmpty) _invalid();
    final choice = data['choices'][0];
    if (choice is! Map || choice['message'] is! Map ||
        choice['message']['content'] is! String) _invalid();
    var tokens = 0;
    if (data['usage'] != null) {
      final usage = data['usage'];
      if (usage is! Map) _invalid();
      if (usage['total_tokens'] != null) {
        if (usage['total_tokens'] is! int || usage['total_tokens'] < 0) _invalid();
        tokens = usage['total_tokens'] as int;
      }
    }
    return RemoteCompletion(_visible(choice['message']['content'] as String), tokens);
  }

  static RemoteCompletion _parseSse(String text) {
    final content = StringBuffer();
    var finished = false;
    for (final line in const LineSplitter().convert(text)) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') {
        finished = true;
        break;
      }
      final data = _decode(payload);
      if (data is! Map || data['choices'] is! List) _invalid();
      final choices = data['choices'] as List;
      if (choices.isEmpty) continue; // Optional usage-only chunk.
      final choice = choices.first;
      if (choice is! Map || choice['delta'] is! Map) _invalid();
      final delta = choice['delta'] as Map;
      if (delta['content'] != null) {
        if (delta['content'] is! String) _invalid();
        content.write(delta['content']);
      }
      if (choice['finish_reason'] != null) finished = true;
    }
    if (!finished) _invalid();
    return RemoteCompletion(_visible(content.toString()), 0);
  }
}