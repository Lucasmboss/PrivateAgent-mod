import 'package:http/http.dart' as http;

class WebSearchService {
  static const Duration timeout = Duration(seconds: 15);
  static const int maxResults = 8;

  Future<String> search(String query) async {
    try {
      final uri = Uri.https(
        'html.duckduckgo.com',
        '/html/',
        {
          'q': query,
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Android; Mobile) AppleWebKit/537.36 '
              'Chrome/120.0 Mobile Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(timeout);

      if (response.statusCode != 200) {
        return 'Web search error: HTTP ${response.statusCode}';
      }

      final html = response.body;

      final results = <Map<String, String>>[];

      final resultPattern = RegExp(
        r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        caseSensitive: false,
        dotAll: true,
      );

      final matches = resultPattern.allMatches(html);

      for (final match in matches.take(maxResults)) {
        var url = match.group(1) ?? '';
        var title = match.group(2) ?? '';

        title = _cleanHtml(title);
        url = _decodeUrl(url);

        if (title.isEmpty || url.isEmpty) {
          continue;
        }

        results.add({
          'title': title,
          'url': url,
        });
      }

      if (results.isEmpty) {
        return 'Web search returned no results for: $query';
      }

      final buffer = StringBuffer();

      buffer.writeln('SEARCH RESULTS');
      buffer.writeln('Query: $query');
      buffer.writeln();

      for (int i = 0; i < results.length; i++) {
        final result = results[i];

        buffer.writeln('[${i + 1}]');
        buffer.writeln('Title: ${result['title']}');
        buffer.writeln('URL: ${result['url']}');
        buffer.writeln();
      }

      return buffer.toString().trim();
    } catch (e) {
      return 'Web search error: $e';
    }
  }

  String _cleanHtml(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _decodeUrl(String value) {
    try {
      final uri = Uri.parse(value);

      final uddg = uri.queryParameters['uddg'];

      if (uddg != null && uddg.isNotEmpty) {
        return Uri.decodeComponent(uddg);
      }

      return value;
    } catch (_) {
      return value;
    }
  }
}