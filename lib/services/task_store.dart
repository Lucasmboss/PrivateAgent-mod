import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/task_record.dart';

class TaskStore {
  final Directory? directory;
  final Future<Directory> Function()? directoryProvider;
  final String fileName;
  static Future<void> _queue = Future.value();

  TaskStore({
    this.directory,
    this.directoryProvider,
    this.fileName = 'tasks.json',
  }) : assert(directory == null || directoryProvider == null);

  Future<Directory> _directory() =>
      directoryProvider?.call() ??
      (directory != null
          ? Future.value(directory!)
          : getApplicationDocumentsDirectory());

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  /// Atomically claims a saved task so it cannot be resumed twice.
  Future<TaskRecord> claim(String identifier, String goal) =>
      _serialized(() async {
        final records = await _read();
        final index = records.indexWhere((record) => record.identifier == identifier);
        if (index < 0 ||
            records[index].status == TaskStatus.running ||
            records[index].status == TaskStatus.completed) {
          throw StateError('Task is missing or cannot be resumed');
        }
        final current = records[index];
        final claimed = current.copyWith(
          goal: goal,
          status: TaskStatus.running,
          updatedAt: DateTime.now(),
        );
        records[index] = claimed;
        await _write(records);
        return claimed;
      });

  Future<List<TaskRecord>> _read() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) throw const FormatException('Invalid task store');
    return decoded
        .map((item) => TaskRecord.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _write(List<TaskRecord> records) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temporary.writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()),
        flush: true);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      // A rename can fail across filesystems; the fallback still only replaces
      // the destination after the complete temporary file has been written.
      await file.writeAsString(await temporary.readAsString(), flush: true);
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<TaskRecord> create({
    required String goal,
    String? identifier,
    TaskStatus status = TaskStatus.running,
    DateTime? now,
    double progress = 0,
    int tokens = 0,
    dynamic results,
    List<String> failedStrategies = const [],
  }) =>
      _serialized(() async {
        final records = await _read();
        final timestamp = now ?? DateTime.now();
        final record = TaskRecord(
          identifier: identifier ?? _newIdentifier(timestamp, records),
          goal: goal,
          status: status,
          createdAt: timestamp,
          updatedAt: timestamp,
          startedAt: status == TaskStatus.running ? timestamp : null,
          progress: progress,
          tokens: tokens,
          results: results,
          failedStrategies: List.unmodifiable(failedStrategies),
        );
        if (records.any((item) => item.identifier == record.identifier)) {
          throw StateError('A task with this identifier already exists');
        }
        records.add(record);
        await _write(records);
        return record;
      });

  String _newIdentifier(DateTime timestamp, List<TaskRecord> records) {
    final prefix = timestamp.microsecondsSinceEpoch.toString();
    var identifier = prefix;
    var suffix = 1;
    while (records.any((record) => record.identifier == identifier)) {
      identifier = '$prefix-$suffix';
      suffix++;
    }
    return identifier;
  }

  Future<TaskRecord> update(
    String identifier, {
    String? goal,
    TaskStatus? status,
    DateTime? now,
    double? progress,
    int? tokens,
    dynamic results,
    List<String>? failedStrategies,
  }) =>
      _serialized(() async {
        final records = await _read();
        final index = records.indexWhere((item) => item.identifier == identifier);
        if (index < 0) throw StateError('Task not found');
        final current = records[index];
        final nextStatus = status ?? current.status;
        final timestamp = now ?? DateTime.now();
        final updated = current.copyWith(
          goal: goal,
          status: nextStatus,
          updatedAt: timestamp,
          startedAt: nextStatus == TaskStatus.running
              ? (current.startedAt ?? timestamp)
              : current.startedAt,
          completedAt: nextStatus == TaskStatus.completed ? timestamp : null,
          progress: progress,
          tokens: tokens,
          results: results,
          failedStrategies: failedStrategies == null
              ? null
              : List.unmodifiable(failedStrategies),
        );
        records[index] = updated;
        await _write(records);
        return updated;
      });

  Future<TaskRecord?> get(String identifier) async {
    final records = await list();
    for (final record in records) {
      if (record.identifier == identifier) return record;
    }
    return null;
  }

  /// Marks tasks that were running when the process stopped as paused.
  ///
  /// Call this once during application startup, before presenting/resuming
  /// tasks. Normal reads intentionally do not mutate persisted state.
  Future<List<TaskRecord>> recoverInterrupted() => _serialized(() async {
        final records = await _read();
        var changed = false;
        final recovered = records.map((record) {
          if (record.status != TaskStatus.running) return record;
          changed = true;
          return record.copyWith(
            status: TaskStatus.paused,
            updatedAt: DateTime.now(),
          );
        }).toList();
        if (changed) await _write(recovered);
        return List.unmodifiable(recovered);
      });

  Future<List<TaskRecord>> list() => _serialized(() async {
        return List.unmodifiable(await _read());
      });

  Future<void> clear() => _serialized(() async {
        final file = await _file();
        if (await file.exists()) await file.delete();
      });
}