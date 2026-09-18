import 'dart:convert';
import 'package:http/http.dart' as http;

class WebService {
  static const int maxResponseLength = 12000;
  static const Duration timeout = Duration(seconds: 20);

  Future<String> request({
    required String method,
    required String url,
    Map<String, dynamic>? headers,
    dynamic body,
  }) async {
    try {
      final uri = Uri.parse(url);

      final request = http.Request(method.toUpperCase(), uri);

      // Headers
      if (headers != null) {
        headers.forEach((key, value) {
          request.headers[key] = value.toString();
        });
      }

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

      final streamedResponse = await request.send().timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);

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
}