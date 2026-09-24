import 'dart:convert';

enum TaskStatus {
  running,
  paused,
  cancelled,
  failed,
  completed,
  needsRevision,
}

TaskStatus taskStatusFromJson(Object? value) {
  if (value is TaskStatus) return value;
  final name = value?.toString().split('.').last;
  return TaskStatus.values.firstWhere(
    (status) => status.name == name,
    orElse: () => throw FormatException('Invalid task status'),
  );
}

class TaskRecord {
  final String identifier;
  final String goal;
  final TaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final double progress;
  final int tokens;
  final dynamic results;
  final List<String> failedStrategies;

  const TaskRecord({
    required this.identifier,
    required this.goal,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.completedAt,
    this.progress = 0,
    this.tokens = 0,
    this.results,
    this.failedStrategies = const [],
  });

  TaskRecord copyWith({
    String? identifier,
    String? goal,
    TaskStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    double? progress,
    int? tokens,
    dynamic results,
    List<String>? failedStrategies,
  }) =>
      TaskRecord(
        identifier: identifier ?? this.identifier,
        goal: goal ?? this.goal,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        startedAt: startedAt ?? this.startedAt,
        completedAt: completedAt ?? this.completedAt,
        progress: progress ?? this.progress,
        tokens: tokens ?? this.tokens,
        results: results ?? this.results,
        failedStrategies: failedStrategies ?? this.failedStrategies,
      );

  Map<String, dynamic> toJson() => {
        'identifier': identifier,
        'goal': goal,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'startedAt': startedAt?.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'progress': progress,
        'tokens': tokens,
        'results': results,
        'failedStrategies': failedStrategies,
      };

  factory TaskRecord.fromJson(Map<String, dynamic> json) {
    DateTime date(String key) {
      final value = json[key];
      if (value is! String) throw const FormatException('Invalid task timestamp');
      return DateTime.parse(value);
    }

    DateTime? optionalDate(String key) {
      final value = json[key];
      return value == null ? null : DateTime.parse(value as String);
    }

    final failed = json['failedStrategies'];
    return TaskRecord(
      identifier: json['identifier'] as String,
      goal: json['goal'] as String,
      status: taskStatusFromJson(json['status']),
      createdAt: date('createdAt'),
      updatedAt: date('updatedAt'),
      startedAt: optionalDate('startedAt'),
      completedAt: optionalDate('completedAt'),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      tokens: (json['tokens'] as num?)?.toInt() ?? 0,
      results: json['results'],
      failedStrategies: failed == null
          ? const []
          : List<String>.from(failed as List),
    );
  }

  String encode() => jsonEncode(toJson());
}