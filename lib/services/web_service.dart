import 'dart:convert';
import 'package:http/http.dart' as http;

class WebService {
  static const int maxResponseLength = 12000;
  static const Duration timeout = Duration(seconds: 20);
  static const Set<String> supportedMethods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
  };

  final http.Client _client;

  WebService({http.Client? client}) : _client = client ?? http.Client();

  Future<String> request({
    required String method,
    required String url,
    Map<String, dynamic>? headers,
    dynamic body,
  }) async {
    try {
      final normalizedMethod = method.trim().toUpperCase();
      if (!supportedMethods.contains(normalizedMethod)) {
        return 'Web request error: unsupported HTTP method "$method". '
            'Supported methods: ${supportedMethods.join(', ')}.';
      }

      final uri = Uri.tryParse(url.trim());
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return 'Web request error: URL must be a valid http or https URL.';
      }

      final request = http.Request(normalizedMethod, uri);

      // Headers
      if (headers != null) {
        headers.forEach((key, value) {
          request.headers[key] = value.toString();
        });
      }

      request.headers.putIfAbsent(
        'Accept',
        () => 'application/json, text/plain, */*',
      );

      // Body
      if (body != null) {
        if (body is String) {
          request.body = body;
        } else {
          request.headers.putIfAbsent(
            'Content-Type',
            () => 'application/json',
          );
          request.body = jsonEncode(body);
        }
      }

      final streamedResponse = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(timeout);

      var responseBody = response.body;

      if (responseBody.length > maxResponseLength) {
        responseBody =
            '${responseBody.substring(0, maxResponseLength)}\n'
            '[Response truncated]';
      }

      return 'HTTP ${response.statusCode}\n$responseBody';
    } catch (e) {
      return 'Web request error: $e';
    }
  }

  /// The executor treats redirects as a completed HTTP exchange because the
  /// http client follows normal redirects by default.
  static bool isSuccessfulResponse(String result) {
    final match = RegExp(r'^HTTP\s+(\d{3})').firstMatch(result.trim());
    if (match == null) return false;

    final status = int.tryParse(match.group(1)!);
    return status != null && status >= 200 && status < 400;
  }
}