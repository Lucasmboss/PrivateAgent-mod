import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/task_record.dart';
import 'task_verifier.dart';
import 'task_persistence_privacy.dart';

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
        goal = TaskPersistencePrivacy.goalText(goal);
        final records = await _read();
        final index = records.indexWhere((record) => record.identifier == identifier);
        if (index < 0 ||
            records[index].status == TaskStatus.running ||
            records[index].status == TaskStatus.completed) {
          throw StateError('Task is missing or cannot be resumed');
        }
        final current = records[index];
        if (current.execution.inFlight?.mutation == true) {
          records[index] = current.copyWith(status: TaskStatus.needsRevision);
          await _write(records);
          throw StateError('Uncertain side effect: review and resolve the pending action before resuming');
        }
        final claimed = current.copyWith(
          goal: goal,
          execution: _revised(current, goal).copyWith(clearInFlight: true),
          status: TaskStatus.running,
          stepsCompleted: goal == current.goal ? current.stepsCompleted : 0,
          progress: goal == current.goal ? current.progress : 0,
          updatedAt: DateTime.now(),
        );
        records[index] = claimed;
        await _write(records);
        return TaskPersistencePrivacy.sanitize(claimed);
      });

  Future<List<TaskRecord>> _read() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) throw const FormatException('Invalid task store');
    return decoded
        .map((item) => TaskPersistencePrivacy.sanitize(
            TaskRecord.fromJson(Map<String, dynamic>.from(item))))
        .toList();
  }

  Future<void> _write(List<TaskRecord> records) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temporary.writeAsString(jsonEncode(records.map((r) =>
        TaskPersistencePrivacy.sanitize(r).toJson()).toList()),
        flush: true);
    // Same-directory rename is atomic. Never fall back to truncating live data.
    await temporary.rename(file.path);
  }

  Future<TaskRecord> create({
    required String goal,
    String? identifier,
    String? chatSessionId,
    TaskStatus status = TaskStatus.running,
    DateTime? now,
    double progress = 0,
    int tokens = 0,
    dynamic results,
    List<String> failedStrategies = const [],
  }) =>
      _serialized(() async {
        goal = TaskPersistencePrivacy.goalText(goal);
        final records = await _read();
        final timestamp = now ?? DateTime.now();
        final record = TaskRecord(
          identifier: identifier ?? _newIdentifier(timestamp, records),
          goal: goal,
          chatSessionId: chatSessionId,
          execution: TaskExecutionState(plan: [
            TaskSubtask(id: 'goal', objective: goal, criteria: [goal]),
          ]),
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
        return TaskPersistencePrivacy.sanitize(record);
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
    int? stepsCompleted,
    int? tokens,
    dynamic results,
    List<String>? failedStrategies,
  }) =>
      _serialized(() async {
        if (goal != null) goal = TaskPersistencePrivacy.goalText(goal!);
        final records = await _read();
        final index = records.indexWhere((item) => item.identifier == identifier);
        if (index < 0) throw StateError('Task not found');
        final current = records[index];
        final nextStatus = status ?? current.status;
        final goalChanged = goal != null && goal != current.goal;
        final nextExecution = goal == null ? current.execution : _revised(current, goal!);
        if (nextStatus == TaskStatus.completed &&
            TaskVerifier.verify(nextExecution) != 'verified') {
          throw StateError('Completion requires verified criterion evidence');
        }
        final timestamp = now ?? DateTime.now();
        final updated = current.copyWith(
          goal: goal,
          execution: nextExecution,
          status: nextStatus,
          updatedAt: timestamp,
          startedAt: nextStatus == TaskStatus.running
              ? (current.startedAt ?? timestamp)
              : current.startedAt,
          completedAt: nextStatus == TaskStatus.completed ? timestamp : null,
          progress: goalChanged ? 0 : progress,
          stepsCompleted: goalChanged ? 0 : stepsCompleted,
          tokens: tokens,
          results: results,
          failedStrategies: failedStrategies == null
              ? null
              : List.unmodifiable(failedStrategies),
        );
        records[index] = updated;
        await _write(records);
        return TaskPersistencePrivacy.sanitize(updated);
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
          final pending = record.execution.inFlight;
          final recoveredExecution = pending == null
              ? record.execution
              : record.execution.copyWith(
                  clearInFlight: true,
                  lastResult: ActionAudit(
                    sequence: pending.sequence,
                    action: pending.action,
                    phase: pending.mutation ? 'uncertain' : 'after',
                    timestamp: DateTime.now(),
                    mutation: pending.mutation,
                    revision: pending.revision,
                    technicalSuccess: false,
                  ),
                  audit: _append(
                    record.execution.audit,
                    ActionAudit(
                      sequence: pending.sequence,
                      action: pending.action,
                      phase: pending.mutation ? 'uncertain' : 'after',
                      timestamp: DateTime.now(),
                      mutation: pending.mutation,
                      revision: pending.revision,
                      technicalSuccess: false,
                    ),
                  ),
                  unverifiedMutations: pending.mutation
                      ? [...record.execution.unverifiedMutations, pending.sequence]
                          .toSet()
                          .toList()
                      : record.execution.unverifiedMutations,
                  verification: pending.mutation ? 'uncertain' : 'unverified',
                );
          return record.copyWith(
            execution: recoveredExecution,
            status: pending?.mutation == true
                ? TaskStatus.needsRevision
                : TaskStatus.paused,
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
        if ((await _read()).any((r) =>
            r.status == TaskStatus.running ||
            r.execution.inFlight != null ||
            r.execution.unverifiedMutations.isNotEmpty ||
            r.execution.pendingAssistance.isNotEmpty)) {
          throw StateError('Cannot clear active or unresolved tasks');
        }
        final file = await _file();
        if (await file.exists()) await file.delete();
      });

  TaskExecutionState _revised(TaskRecord record, String goal) {
    if (goal == record.goal) return record.execution;
    return record.execution.copyWith(
      revisions: [...record.execution.revisions, goal],
      plan: [TaskSubtask(id: 'goal', objective: goal, criteria: [goal])],
      criterionConfirmations: const [],
      verification: 'unverified');
  }

  Future<TaskRecord> _mutate(String id,
      TaskRecord Function(TaskRecord) change) => _serialized(() async {
    final records = await _read();
    final index = records.indexWhere((r) => r.identifier == id);
    if (index < 0) throw StateError('Task not found');
    final updated = TaskPersistencePrivacy.sanitize(
        change(records[index]).copyWith(updatedAt: DateTime.now()));
    records[index] = updated;
    await _write(records);
    return updated;
  });

  List<ActionAudit> _append(List<ActionAudit> audit, ActionAudit entry) {
    final next = [...audit, entry];
    return next.length <= 200 ? next : next.sublist(next.length - 200);
  }

  /// Caller must await this durable checkpoint BEFORE invoking a tool.
  Future<TaskRecord> beginAction(String id, String action,
      {required bool mutation}) => _mutate(id, (record) {
    final state = record.execution;
    if (record.status != TaskStatus.running || state.inFlight != null) {
      throw StateError('Task not running or action already in flight');
    }
    // Action names are identifiers, never user-provided arguments.
    if (!RegExp(r'^[a-z_]{1,40}$').hasMatch(action)) {
      throw const FormatException('Invalid action name');
    }
    final event = ActionAudit(sequence: state.nextSequence, action: action,
      phase: 'before', timestamp: DateTime.now(), mutation: mutation,
      revision: state.revision);
    return record.copyWith(execution: state.copyWith(inFlight: event,
      nextSequence: state.nextSequence + 1, audit: _append(state.audit, event)));
  });

  Future<TaskRecord> endAction(String id, {required bool technicalSuccess,
      bool uncertain = false, bool continueAfterUncertain = false}) =>
      _mutate(id, (record) {
    final state = record.execution;
    final pending = state.inFlight;
    if (pending == null) throw StateError('No pending action');
    final event = ActionAudit(sequence: pending.sequence, action: pending.action,
      phase: uncertain ? 'uncertain' : 'after', timestamp: DateTime.now(),
      mutation: pending.mutation, revision: pending.revision,
      technicalSuccess: technicalSuccess);
    return record.copyWith(
      status: uncertain && pending.mutation && !continueAfterUncertain
          ? TaskStatus.needsRevision
          : null,
      execution: state.copyWith(
        clearInFlight:
            !uncertain || !pending.mutation || continueAfterUncertain,
        unverifiedMutations: pending.mutation && (technicalSuccess || uncertain)
            ? [...state.unverifiedMutations, pending.sequence].toSet().toList()
            : state.unverifiedMutations,
        lastResult: event, audit: _append(state.audit, event),
        verification: uncertain ? 'uncertain' : 'unverified'));
  });

  Future<TaskRecord> addPendingAssistance(
    String id,
    PendingAssistanceRequest request,
  ) => _mutate(id, (record) {
    if (!RegExp(r'^assist-[A-Za-z0-9_-]{1,80}$').hasMatch(request.id) ||
        request.question.trim().isEmpty ||
        request.question.length > 320 ||
        request.evidence.trim().length < 4 ||
        request.evidence.length > 120) {
      throw const FormatException('Invalid pending assistance request');
    }
    final pending = [...record.execution.pendingAssistance];
    if (pending.any((item) => item.id == request.id)) return record;
    if (pending.length >= 20) {
      throw StateError('The task already has the maximum pending requests');
    }
    return record.copyWith(
      execution: record.execution.copyWith(
        pendingAssistance: [...pending, request],
      ),
    );
  });

  Future<TaskRecord> resolvePendingAssistance(
    String id,
    Set<String> resolvedIds,
  ) => _mutate(id, (record) => record.copyWith(
    execution: record.execution.copyWith(
      pendingAssistance: record.execution.pendingAssistance
          .where((item) => !resolvedIds.contains(item.id))
          .toList(),
    ),
  ));

  /// Only trusted user-review UI may call this; never expose it as an AI tool.
  /// Resolves ambiguous execution without replaying the operation.
  Future<TaskRecord> resolveUncertainAction(String id,
      {required bool userConfirmedSuccess}) => _mutate(id, (record) {
    final state = record.execution;
    final pending = state.inFlight;
    if (pending == null) throw StateError('No uncertain action');
    if (record.status == TaskStatus.running) throw StateError('Stop task before review');
    final event = ActionAudit(sequence: pending.sequence, action: pending.action,
      phase: 'after', timestamp: DateTime.now(), mutation: pending.mutation,
      revision: pending.revision, technicalSuccess: userConfirmedSuccess,
      outcome: userConfirmedSuccess
          ? 'userConfirmed'
          : 'userConfirmedFailure');
    return record.copyWith(status: TaskStatus.needsRevision,
      execution: state.copyWith(clearInFlight: true, lastResult: event,
        unverifiedMutations: state.unverifiedMutations
            .where((s) => s != pending.sequence).toList(),
        audit: _append(state.audit, event), verification: 'unverified'));
  });

  Future<TaskRecord> resolveUncertainAuditAction(
    String id, {
    required int sequence,
    required bool userConfirmedSuccess,
  }) => _mutate(id, (record) {
    if (record.status == TaskStatus.running) {
      throw StateError('Stop task before review');
    }
    final state = record.execution;
    final event = state.audit.lastWhere(
      (item) =>
          item.sequence == sequence &&
          item.phase == 'uncertain' &&
          item.mutation,
    );
    final resolved = ActionAudit(
      sequence: event.sequence,
      action: event.action,
      phase: 'after',
      timestamp: DateTime.now(),
      mutation: true,
      revision: event.revision,
      technicalSuccess: userConfirmedSuccess,
      outcome: userConfirmedSuccess
          ? 'userConfirmed'
          : 'userConfirmedFailure',
    );
    return record.copyWith(
      status: TaskStatus.needsRevision,
      execution: state.copyWith(
        lastResult: resolved,
        audit: _append(state.audit, resolved),
        unverifiedMutations: state.unverifiedMutations
            .where((item) => item != sequence)
            .toList(),
        verification: 'unverified',
      ),
    );
  });

  /// New criteria invalidate old evidence by advancing the revision.
  /// Trusted UI only: explicit user attestation, not model-generated evidence.
  Future<TaskRecord> confirmActionOutcome(String id, int sequence) =>
      _mutate(id, (record) {
    if (record.status == TaskStatus.running) throw StateError('Stop task before review');
    final state = record.execution;
    final event = state.audit.lastWhere((e) => e.sequence == sequence &&
        e.phase == 'after' && e.technicalSuccess);
    final confirmed = ActionAudit(sequence: event.sequence, action: event.action,
      phase: 'after', timestamp: DateTime.now(), mutation: event.mutation,
      revision: event.revision, technicalSuccess: true, outcome: 'userConfirmed');
    return record.copyWith(execution: state.copyWith(
      audit: _append(state.audit, confirmed), lastResult: confirmed,
      unverifiedMutations: state.unverifiedMutations.where((s) => s != sequence).toList()));
  });

  Future<TaskRecord> setPlan(String id, List<TaskSubtask> plan) =>
      _mutate(id, (record) {
    TaskVerifier.validatePlan(plan);
    if (record.execution.inFlight != null) throw StateError('Action in flight');
    final clean = plan.map((s) => TaskSubtask(id: s.id, objective: s.objective,
      dependencies: s.dependencies, criteria: s.criteria)).toList();
    return record.copyWith(execution: record.execution.copyWith(
      revisions: [...record.execution.revisions, record.goal],
      criterionConfirmations: const [],
      plan: clean, verification: 'unverified'));
  });

  Future<TaskRecord> verifyCompletion(String id,
      Map<String, Map<String, List<String>>> references) => _mutate(id, (record) {
    final plan = record.execution.plan.map((s) => TaskSubtask(id: s.id,
      objective: s.objective, dependencies: s.dependencies, criteria: s.criteria,
      evidenceRefs: references[s.id] ?? s.evidenceRefs)).toList();
    final state = record.execution.copyWith(plan: plan);
    return record.copyWith(execution:
      state.copyWith(verification: TaskVerifier.verify(state)));
  });

  /// Trusted UI ONLY, never an AI tool. Pass the revision shown to the user;
  /// a stale dialog cannot attest to a subsequently changed criterion.
  Future<TaskRecord> confirmCriterion(String id, {
    required int expectedRevision,
    required String subtaskId,
    required String criterion,
    required bool confirmed,
  }) => _mutate(id, (record) {
    final state = record.execution;
    if (record.status == TaskStatus.running || state.inFlight != null) {
      throw StateError('Stop task before criterion review');
    }
    if (state.revision != expectedRevision ||
        !state.plan.any((s) => s.id == subtaskId && s.criteria.contains(criterion))) {
      throw StateError('Criterion or revision changed; refresh review');
    }
    final confirmations = state.criterionConfirmations.where((c) =>
      !(c.subtaskId == subtaskId && c.criterion == criterion)).toList();
    if (confirmed) confirmations.add(CriterionConfirmation(
      revision: expectedRevision, subtaskId: subtaskId, criterion: criterion,
      confirmedAt: DateTime.now()));
    final next = state.copyWith(criterionConfirmations: confirmations);
    return record.copyWith(status: TaskStatus.needsRevision,
      execution: next.copyWith(verification: TaskVerifier.verify(next)));
  });
}