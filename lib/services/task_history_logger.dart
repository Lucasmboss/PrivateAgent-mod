import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../privacy_sanitizer.dart';

class TaskHistoryLogger {
  static const int maxRecords = 200;

  static Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/task_history.jsonl');
  }

  /// Appends a task execution record to the history file
  static Future<void> logTask(
    String goal,
    String status,
    int totalTokens,
    int steps,
    List<String> trace,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(PrivacyPreferenceKeys.taskHistoryEnabled) ?? true)) {
      return;
    }
    final file = await _localFile;
    final now = DateTime.now();
    final data = {
      "goal": PrivacySanitizer.sanitizeText(goal.trim()),
      "status": status, // "Success", "Failed", "Cancelled"
      "total_tokens": totalTokens,
      "steps_taken": steps,
      // Detailed tool output can contain unlabelled file, HTTP, or screen
      // bodies. Persist only a useful count rather than trying to infer PII.
      "trace": const <String>[],
      "trace_event_count": trace.length,
      "timestamp": now.toIso8601String(),
    };
    final existing = await _readOldestFirst(file);
    existing.add(data);
    final retained = applyRetention(
      existing,
      retentionDays:
          prefs.getInt(PrivacyPreferenceKeys.historyRetentionDays) ??
          PrivacyPreferenceKeys.defaultRetentionDays,
      now: now,
    );
    await _write(file, retained);
  }

  /// Reads the entire task history file for previewing
  static Future<List<Map<String, dynamic>>> readHistory() async {
    final file = await _localFile;
    final prefs = await SharedPreferences.getInstance();
    final records = applyRetention(
      await _readOldestFirst(file),
      retentionDays:
          prefs.getInt(PrivacyPreferenceKeys.historyRetentionDays) ??
          PrivacyPreferenceKeys.defaultRetentionDays,
      now: DateTime.now(),
    );
    // Rewrite legacy entries after sanitising them so raw trace bodies are
    // removed from disk, not merely hidden in the UI.
    if (await file.exists()) await _write(file, records);
    return records.reversed.toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>> _readOldestFirst(File file) async {
    if (!await file.exists()) return [];
    final records = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Invalid task history record');
      }
      final record = Map<String, dynamic>.from(decoded);
      final trace = record['trace'];
      if (trace != null && trace is! List) {
        throw const FormatException('Invalid task history trace');
      }
      record['goal'] = PrivacySanitizer.sanitizeText(
        (record['goal'] ?? '').toString(),
      );
      record['trace_event_count'] =
          (record['trace_event_count'] as num?)?.toInt() ??
          (trace as List? ?? const []).length;
      record['trace'] = const <String>[];
      records.add(record);
    }
    return records;
  }

  static List<Map<String, dynamic>> applyRetention(
    List<Map<String, dynamic>> records, {
    required int retentionDays,
    required DateTime now,
    int maxEntries = maxRecords,
  }) {
    if (retentionDays < 1 || maxEntries < 1) {
      throw ArgumentError('Retention limits must be positive');
    }
    final cutoff = now.subtract(Duration(days: retentionDays));
    final retained = records.where((record) {
      final timestamp = record['timestamp'];
      if (timestamp is! String) {
        throw const FormatException('Invalid task history timestamp');
      }
      return DateTime.parse(timestamp).isAfter(cutoff);
    }).toList();
    return retained.length <= maxEntries
        ? retained
        : retained.sublist(retained.length - maxEntries);
  }

  static Future<void> _write(
    File file,
    List<Map<String, dynamic>> records,
  ) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      records.map(jsonEncode).join('\n') + (records.isEmpty ? '' : '\n'),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  /// Clears the task history file
  static Future<void> clearHistory() async {
    final file = await _localFile;
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Calculates analytics from task history
  static Future<Map<String, dynamic>> getAnalytics() async {
    final history = await readHistory();
    if (history.isEmpty) {
      return {
        'totalTasks': 0,
        'successRate': 0.0,
        'successCount': 0,
        'failedCount': 0,
      };
    }

    int successCount = 0;
    int failedCount = 0;

    for (final task in history) {
      if (task['status'] == 'Success') {
        successCount++;
      } else if (task['status'] == 'Failed' || task['status'] == 'Cancelled') {
        failedCount++;
      }
    }

    return {
      'totalTasks': history.length,
      'successRate': successCount / history.length,
      'successCount': successCount,
      'failedCount': failedCount,
    };
  }
}
