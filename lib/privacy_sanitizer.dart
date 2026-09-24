/// Conservative redaction for secrets that have recognisable syntax.
///
/// This is deliberately not advertised as general PII detection. Free-form
/// names, addresses, and other personal data cannot be identified reliably.
class PrivacySanitizer {
  static const redacted = '[REDACTED]';

  static final _authorization = RegExp(
    r'\bauthorization\s*[:=]\s*(?:bearer|basic)\s+[^\s,;"\x27]+',
    caseSensitive: false,
  );
  static final _credentialAssignment = RegExp(
    r'''\b(api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|password|passwd|secret|bot[_-]?token)\b(\s*[:=]\s*)(["']?)[^\s,;"']+\3''',
    caseSensitive: false,
  );
  static final _queryCredential = RegExp(
    r'([?&](?:api[_-]?key|access[_-]?token|token|secret|password)=)[^&#\s]+',
    caseSensitive: false,
  );
  static final _jwt = RegExp(
    r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
  );
  static final _openAiStyleKey = RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b');
  static final _telegramToken = RegExp(r'\b\d{6,12}:[A-Za-z0-9_-]{20,}\b');

  /// Redacts only obvious credential/token formats.
  static String sanitizeText(String value) {
    var result = value.replaceAllMapped(
      _authorization,
      (_) => 'Authorization: $redacted',
    );
    result = result.replaceAllMapped(
      _credentialAssignment,
      (match) => '${match.group(1)}${match.group(2)}$redacted',
    );
    result = result.replaceAllMapped(
      _queryCredential,
      (match) => '${match.group(1)}$redacted',
    );
    result = result.replaceAll(_jwt, redacted);
    result = result.replaceAll(_openAiStyleKey, redacted);
    return result.replaceAll(_telegramToken, redacted);
  }

  /// Converts an execution trace into bounded metadata. Raw file, HTTP, and
  /// screen bodies are intentionally never retained.
  static String sanitizeTaskTrace(String value) {
    final trimmed = value.trim();
    final bodyMarker = RegExp(
      r'\b(response\s*body|request\s*body|http\s*body|file\s*(?:body|content)|screen(?:shot)?\s*(?:body|content|dump|xml)|page\s*(?:body|content|html))\b',
      caseSensitive: false,
    );
    if (bodyMarker.hasMatch(trimmed)) {
      final category = RegExp(r'screen', caseSensitive: false).hasMatch(trimmed)
          ? 'screen'
          : RegExp(r'file', caseSensitive: false).hasMatch(trimmed)
          ? 'file'
          : 'http';
      return '[$category details omitted]';
    }
    final sanitized = sanitizeText(trimmed).replaceAll(RegExp(r'[\r\n]+'), ' ');
    return sanitized.length <= 300
        ? sanitized
        : '${sanitized.substring(0, 300)}…';
  }

  static Object? sanitizeJson(Object? value, {bool taskTrace = false}) {
    if (value is String) {
      return taskTrace ? sanitizeTaskTrace(value) : sanitizeText(value);
    }
    if (value is List) {
      return value
          .map((item) => sanitizeJson(item, taskTrace: taskTrace))
          .toList();
    }
    if (value is Map) {
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), sanitizeJson(item, taskTrace: taskTrace)),
      );
    }
    return value;
  }
}

class PrivacyPreferenceKeys {
  static const chatHistoryEnabled = 'chat_history_persistence_enabled';
  static const taskHistoryEnabled = 'task_history_persistence_enabled';
  static const historyRetentionDays = 'history_retention_days';
  static const telegramAllowedChatId = 'telegram_allowed_chat_id';

  static const defaultRetentionDays = 30;
}
