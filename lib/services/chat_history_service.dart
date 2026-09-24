import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../privacy_sanitizer.dart';

class ChatSession {
  final String id;
  final String title;
  final DateTime timestamp;
  final List<Map<String, dynamic>> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.timestamp,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'timestamp': timestamp.toIso8601String(),
    'messages': messages,
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
    id: json['id'] as String,
    title: json['title'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
    messages: List<Map<String, dynamic>>.from(json['messages'] as List),
  );
}

class ChatHistoryService {
  static const int maxSessions = 100;
  static Future<void> _persistenceQueue = Future<void>.value();
  static int _temporaryFileSequence = 0;

  static Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _persistenceQueue = _persistenceQueue.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  static Future<bool> isPersistenceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(PrivacyPreferenceKeys.chatHistoryEnabled) ?? true;
  }

  static Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/chat_history_sessions.json');
  }

  static Future<Directory> get _overlayHandoffDirectory async {
    final directory = await getApplicationDocumentsDirectory();
    return Directory('${directory.path}/overlay_chat_handoff');
  }

  static Future<void> appendOverlayMessage(Map<String, dynamic> message) async {
    if (!await isPersistenceEnabled()) {
      await clearPendingHandoffs();
      return;
    }
    final directory = await _overlayHandoffDirectory;
    await directory.create(recursive: true);
    final eventId = DateTime.now().microsecondsSinceEpoch;
    final temporary = File('${directory.path}/$eventId.tmp');
    final event = File('${directory.path}/$eventId.json');
    final sanitized = PrivacySanitizer.sanitizeJson(message);
    await temporary.writeAsString(jsonEncode(sanitized), flush: true);
    await temporary.rename(event.path);
  }

  static Future<List<Map<String, dynamic>>> consumeOverlayMessages() async {
    if (!await isPersistenceEnabled()) {
      await clearPendingHandoffs();
      return [];
    }
    final directory = await _overlayHandoffDirectory;
    if (!await directory.exists()) return [];

    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));

    final messages = <Map<String, dynamic>>[];
    for (final file in files) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Invalid overlay history event');
      }
      messages.add(
        Map<String, dynamic>.from(
          PrivacySanitizer.sanitizeJson(decoded) as Map,
        ),
      );
      await file.delete();
    }
    return messages;
  }

  /// Saves a session. Overwrites if ID already exists.
  static Future<void> saveSession(ChatSession session) =>
      _runSerialized(() => _saveSession(session));

  static Future<void> _saveSession(ChatSession session) async {
    if (!await isPersistenceEnabled()) return;
    final file = await _localFile;
    List<ChatSession> sessions = await _loadSessions();
    final clean = _sanitizeSession(session);

    final index = sessions.indexWhere((s) => s.id == clean.id);
    if (index >= 0) {
      sessions[index] = clean;
    } else {
      sessions.insert(0, clean); // Newest first
    }

    sessions = await _applyConfiguredRetention(sessions);
    await _write(file, sessions);
  }

  /// Loads all saved chat sessions.
  static Future<List<ChatSession>> loadSessions() =>
      _runSerialized(_loadSessions);

  static Future<ChatSession?> getSession(String id) =>
      _runSerialized(() async {
        final sessions = await _loadSessions();
        for (final session in sessions) {
          if (session.id == id) return session;
        }
        return null;
      });

  static Future<List<ChatSession>> _loadSessions() async {
    if (!await isPersistenceEnabled()) return [];
    final file = await _localFile;
    if (!await file.exists()) return [];

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      throw const FormatException('Chat history file is empty');
    }

    final decoded = jsonDecode(content);
    if (decoded is! List) {
      throw const FormatException('Invalid chat history');
    }
    final sessions = decoded.map((item) {
      if (item is! Map) throw const FormatException('Invalid chat session');
      return _sanitizeSession(
        ChatSession.fromJson(Map<String, dynamic>.from(item)),
      );
    }).toList();
    final retained = await _applyConfiguredRetention(sessions);
    // This also migrates legacy content by replacing obvious credentials.
    await _write(file, retained);
    return retained;
  }

  static ChatSession _sanitizeSession(ChatSession session) => ChatSession(
    id: session.id,
    title: PrivacySanitizer.sanitizeText(session.title),
    timestamp: session.timestamp,
    messages: session.messages
        .map(
          (message) => Map<String, dynamic>.from(
            PrivacySanitizer.sanitizeJson(message) as Map,
          ),
        )
        .toList(growable: false),
  );

  static List<ChatSession> applyRetention(
    List<ChatSession> sessions, {
    required int retentionDays,
    required DateTime now,
    int maxEntries = maxSessions,
  }) {
    if (retentionDays < 1 || maxEntries < 1) {
      throw ArgumentError('Retention limits must be positive');
    }
    final cutoff = now.subtract(Duration(days: retentionDays));
    final retained =
        sessions.where((session) => session.timestamp.isAfter(cutoff)).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return retained.length <= maxEntries
        ? retained
        : retained.sublist(0, maxEntries);
  }

  static Future<List<ChatSession>> _applyConfiguredRetention(
    List<ChatSession> sessions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    return applyRetention(
      sessions,
      retentionDays:
          prefs.getInt(PrivacyPreferenceKeys.historyRetentionDays) ??
          PrivacyPreferenceKeys.defaultRetentionDays,
      now: DateTime.now(),
    );
  }

  static Future<void> _write(File file, List<ChatSession> sessions) async {
    await file.parent.create(recursive: true);
    final sequence = _temporaryFileSequence++;
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode(sessions.map((session) => session.toJson()).toList()),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// Deletes a specific session.
  static Future<void> deleteSession(String id) =>
      _runSerialized(() => _deleteSession(id));

  static Future<void> _deleteSession(String id) async {
    if (!await isPersistenceEnabled()) return;
    final file = await _localFile;
    List<ChatSession> sessions = await _loadSessions();
    sessions.removeWhere((s) => s.id == id);

    await _write(file, sessions);
  }

  /// Clears all saved chat sessions.
  static Future<void> clearAll() => _runSerialized(_clearAll);

  static Future<void> _clearAll() async {
    final file = await _localFile;
    if (await file.exists()) {
      await file.delete();
    }
    await clearPendingHandoffs();
  }

  static Future<void> clearPendingHandoffs() async {
    final directory = await _overlayHandoffDirectory;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
