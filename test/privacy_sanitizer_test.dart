import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/privacy_sanitizer.dart';
import 'package:private_agent/services/chat_history_service.dart';
import 'package:private_agent/services/task_history_logger.dart';

void main() {
  group('PrivacySanitizer', () {
    test('redacts recognisable credentials without changing ordinary text', () {
      const ordinary = 'Open the weather page for tomorrow';
      expect(PrivacySanitizer.sanitizeText(ordinary), ordinary);

      final result = PrivacySanitizer.sanitizeText(
        'Authorization: Bearer abc.def-123 '
        'api_key=sk-abcdefghijklmnopqrstuvwxyz '
        'https://example.test/?token=secret-value',
      );
      expect(result, isNot(contains('abc.def-123')));
      expect(result, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
      expect(result, isNot(contains('secret-value')));
      expect(result, contains(PrivacySanitizer.redacted));
    });

    test('omits raw task bodies and bounds other trace text', () {
      expect(
        PrivacySanitizer.sanitizeTaskTrace('HTTP response body: secret data'),
        '[http details omitted]',
      );
      expect(
        PrivacySanitizer.sanitizeTaskTrace('screen XML content: <node />'),
        '[screen details omitted]',
      );
      expect(
        PrivacySanitizer.sanitizeTaskTrace('file content: private bytes'),
        '[file details omitted]',
      );
      expect(
        PrivacySanitizer.sanitizeTaskTrace(
          List.filled(1000, 'x').join(),
        ).length,
        lessThanOrEqualTo(301),
      );
    });
  });

  group('bounded retention', () {
    test('task history drops expired and oldest excess records', () {
      final now = DateTime.utc(2025, 1, 31);
      final records = List.generate(
        6,
        (index) => <String, dynamic>{
          'timestamp': now
              .subtract(Duration(days: 5 - index))
              .toIso8601String(),
        },
      );

      final retained = TaskHistoryLogger.applyRetention(
        records,
        retentionDays: 4,
        maxEntries: 2,
        now: now,
      );

      expect(retained, hasLength(2));
      expect(retained.first['timestamp'], records[4]['timestamp']);
      expect(retained.last['timestamp'], records[5]['timestamp']);
    });

    test('chat retention sorts newest first and enforces maximum', () {
      final now = DateTime.utc(2025, 2, 1);
      final sessions = List.generate(
        5,
        (index) => ChatSession(
          id: '$index',
          title: 'Session $index',
          timestamp: now.subtract(Duration(days: index)),
          messages: const [],
        ),
      ).reversed.toList();

      final retained = ChatHistoryService.applyRetention(
        sessions,
        retentionDays: 3,
        maxEntries: 2,
        now: now,
      );

      expect(retained.map((session) => session.id), ['0', '1']);
    });

    test('invalid retention configuration is rejected', () {
      expect(
        () => TaskHistoryLogger.applyRetention(
          const [],
          retentionDays: 0,
          now: DateTime.utc(2025),
        ),
        throwsArgumentError,
      );
    });
  });
}
