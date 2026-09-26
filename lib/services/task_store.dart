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
        final resumedExecution = _prepareResume(
          _revised(current, goal).copyWith(clearInFlight: true),
        );
        final claimed = current.copyWith(
          goal: goal,
          execution: resumedExecution,
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
                    subtaskId: pending.subtaskId,
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
                      subtaskId: pending.subtaskId,
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

  TaskExecutionState _prepareResume(TaskExecutionState state) {
    var plan = state.plan
        .map((subtask) => subtask.status == TaskSubtaskStatus.failed
            ? subtask.copyWith(
                status: TaskSubtaskStatus.pending,
                clearFailureCode: true,
              )
            : subtask)
        .toList();
    final unresolvedEvents = state.audit
        .where((event) =>
            event.mutation &&
            state.unverifiedMutations.contains(event.sequence))
        .toList();
    for (final event in unresolvedEvents) {
      if (event.subtaskId == null) continue;
      plan = plan
          .map((subtask) => subtask.id == event.subtaskId
              ? subtask.copyWith(
                  status: TaskSubtaskStatus.needsReview,
                  failureCode: event.phase == 'uncertain'
                      ? 'uncertain_outcome'
                      : 'mutation_outcome_unverified',
                )
              : subtask)
          .toList();
    }
    final hasLegacyUncertainMutation =
        unresolvedEvents.any((event) => event.subtaskId == null);
    if (hasLegacyUncertainMutation &&
        plan.isNotEmpty &&
        plan.every((subtask) =>
            subtask.attempts == 0 &&
            subtask.status == TaskSubtaskStatus.pending)) {
      plan[0] = plan[0].copyWith(
        status: TaskSubtaskStatus.needsReview,
        failureCode: 'uncertain_outcome',
      );
    }
    return state.copyWith(plan: _refreshSubtaskDependencies(plan));
  }

  List<TaskSubtask> _refreshSubtaskDependencies(List<TaskSubtask> plan) {
    var updated = List<TaskSubtask>.from(plan);
    for (var index = 0; index < updated.length; index++) {
      final subtask = updated[index];
      if (subtask.status == TaskSubtaskStatus.completed) continue;
      final dependencies = updated
          .where((candidate) => subtask.dependencies.contains(candidate.id))
          .toList();
      final hasBlockedDependency = dependencies.any((dependency) =>
          const {
            TaskSubtaskStatus.failed,
            TaskSubtaskStatus.blocked,
            TaskSubtaskStatus.needsReview,
          }.contains(dependency.status));
      if (hasBlockedDependency) {
        updated[index] = subtask.copyWith(
          status: TaskSubtaskStatus.blocked,
          failureCode: 'dependency_failed',
        );
      } else if (subtask.status == TaskSubtaskStatus.blocked &&
          dependencies.every((dependency) =>
              dependency.status == TaskSubtaskStatus.completed)) {
        updated[index] = subtask.copyWith(
          status: TaskSubtaskStatus.pending,
          clearFailureCode: true,
        );
      }
    }
    return updated;
  }

  /// Caller must await this durable checkpoint BEFORE invoking a tool.
  Future<TaskRecord> beginAction(String id, String action,
      {required bool mutation, String? subtaskId}) => _mutate(id, (record) {
    final state = record.execution;
    if (record.status != TaskStatus.running || state.inFlight != null) {
      throw StateError('Task not running or action already in flight');
    }
    // Action names are identifiers, never user-provided arguments.
    if (!RegExp(r'^[a-z_]{1,40}$').hasMatch(action)) {
      throw const FormatException('Invalid action name');
    }
    if (subtaskId != null &&
        !state.plan.any((subtask) => subtask.id == subtaskId)) {
      throw const FormatException('Unknown subtask');
    }
    final target = subtaskId == null
        ? null
        : state.plan.firstWhere((subtask) => subtask.id == subtaskId);
    if (target != null &&
        !state.plan
            .where((subtask) => target.dependencies.contains(subtask.id))
            .every((dependency) =>
                dependency.status == TaskSubtaskStatus.completed)) {
      throw StateError('Subtask dependencies are not complete');
    }
    if (target != null &&
        const {
          TaskSubtaskStatus.completed,
          TaskSubtaskStatus.blocked,
          TaskSubtaskStatus.failed,
        }.contains(target.status)) {
      throw StateError('Subtask is not currently runnable');
    }
    if (target?.status == TaskSubtaskStatus.needsReview && mutation) {
      throw StateError('Mutation blocked while subtask outcome needs review');
    }
    if (mutation &&
        state.audit.any((event) =>
            event.mutation &&
            event.action == action &&
            (event.subtaskId == subtaskId || event.subtaskId == null) &&
            (state.unverifiedMutations.contains(event.sequence) ||
                event.technicalSuccess ||
                event.outcome == 'userConfirmed' ||
                event.outcome == 'observed'))) {
      throw StateError('Refusing to replay an external mutation');
    }
    final event = ActionAudit(sequence: state.nextSequence, action: action,
      phase: 'before', timestamp: DateTime.now(), mutation: mutation,
      revision: state.revision, subtaskId: subtaskId);
    final plan = target == null
        ? state.plan
        : state.plan.map((subtask) => subtask.id == subtaskId
            ? subtask.copyWith(
                status: subtask.status == TaskSubtaskStatus.needsReview
                    ? null
                    : TaskSubtaskStatus.inProgress,
                attempts: subtask.attempts + 1,
                clearFailureCode:
                    subtask.status != TaskSubtaskStatus.needsReview,
              )
            : subtask).toList();
    return record.copyWith(execution: state.copyWith(
      plan: plan,
      inFlight: event,
      nextSequence: state.nextSequence + 1,
      audit: _append(state.audit, event),
    ));
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
      technicalSuccess: technicalSuccess, subtaskId: pending.subtaskId);
    var plan = state.plan.map((subtask) {
      if (subtask.id != pending.subtaskId) return subtask;
      if (subtask.status == TaskSubtaskStatus.needsReview &&
          !pending.mutation) {
        return subtask;
      }
      if (pending.mutation && (uncertain || technicalSuccess)) {
        return subtask.copyWith(
          status: TaskSubtaskStatus.needsReview,
          failureCode: uncertain
              ? 'uncertain_outcome'
              : 'mutation_outcome_unverified',
        );
      }
      return subtask.copyWith(
        status: TaskSubtaskStatus.inProgress,
        failureCode: technicalSuccess ? null : 'tool_failed',
        clearFailureCode: technicalSuccess,
      );
    }).toList();
    plan = _refreshSubtaskDependencies(plan);
    return record.copyWith(
      status: uncertain && pending.mutation && !continueAfterUncertain
          ? TaskStatus.needsRevision
          : null,
      execution: state.copyWith(
        plan: plan,
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
      subtaskId: pending.subtaskId,
      outcome: userConfirmedSuccess
          ? 'userConfirmed'
          : 'userConfirmedFailure');
    final plan = _refreshSubtaskDependencies(state.plan.map((subtask) {
      if (subtask.id != pending.subtaskId) return subtask;
      return subtask.copyWith(
        status: userConfirmedSuccess
            ? TaskSubtaskStatus.inProgress
            : TaskSubtaskStatus.pending,
        failureCode: userConfirmedSuccess ? null : 'tool_failed',
        clearFailureCode: userConfirmedSuccess,
      );
    }).toList());
    return record.copyWith(status: TaskStatus.needsRevision,
      execution: state.copyWith(plan: plan, clearInFlight: true, lastResult: event,
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
      subtaskId: event.subtaskId,
      outcome: userConfirmedSuccess
          ? 'userConfirmed'
          : 'userConfirmedFailure',
    );
    final plan = _refreshSubtaskDependencies(state.plan.map((subtask) {
      if (subtask.id != event.subtaskId) return subtask;
      return subtask.copyWith(
        status: userConfirmedSuccess
            ? TaskSubtaskStatus.inProgress
            : TaskSubtaskStatus.pending,
        failureCode: userConfirmedSuccess ? null : 'tool_failed',
        clearFailureCode: userConfirmedSuccess,
      );
    }).toList());
    return record.copyWith(
      status: TaskStatus.needsRevision,
      execution: state.copyWith(
        plan: plan,
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
      revision: event.revision, technicalSuccess: true, outcome: 'userConfirmed',
      subtaskId: event.subtaskId);
    final plan = _refreshSubtaskDependencies(state.plan.map((subtask) {
      if (subtask.id != event.subtaskId || !event.mutation) return subtask;
      return subtask.copyWith(
        status: TaskSubtaskStatus.inProgress,
        clearFailureCode: true,
      );
    }).toList());
    return record.copyWith(execution: state.copyWith(
      plan: plan,
      audit: _append(state.audit, confirmed), lastResult: confirmed,
      unverifiedMutations: state.unverifiedMutations.where((s) => s != sequence).toList()));
  });

  Future<TaskRecord> setPlan(String id, List<TaskSubtask> plan) =>
      _mutate(id, (record) {
    TaskVerifier.validatePlan(plan);
    if (record.execution.inFlight != null) throw StateError('Action in flight');
    final clean = plan.map((s) => TaskSubtask(
      id: s.id,
      objective: s.objective,
      dependencies: s.dependencies,
      criteria: s.criteria,
    )).toList();
    return record.copyWith(execution: record.execution.copyWith(
      revisions: [...record.execution.revisions, record.goal],
      criterionConfirmations: const [],
      plan: clean, verification: 'unverified'));
  });

  Future<TaskRecord> verifyCompletion(String id,
      Map<String, Map<String, List<String>>> references) => _mutate(id, (record) {
    final plan = record.execution.plan.map((s) => TaskSubtask(id: s.id,
      objective: s.objective, dependencies: s.dependencies, criteria: s.criteria,
      status: s.status, attempts: s.attempts, failureCode: s.failureCode,
      evidenceRefs: references[s.id] ?? s.evidenceRefs)).toList();
    final initial = record.execution.copyWith(plan: plan);
    final verifiedIds = TaskVerifier.verifiedSubtaskIds(initial);
    final updatedPlan = initial.plan.map((subtask) {
      if (verifiedIds.contains(subtask.id)) {
        return subtask.copyWith(
          status: TaskSubtaskStatus.completed,
          clearFailureCode: true,
        );
      }
      if (subtask.status == TaskSubtaskStatus.completed) {
        return subtask.copyWith(status: TaskSubtaskStatus.pending);
      }
      return subtask;
    }).toList();
    final state = initial.copyWith(
      plan: _refreshSubtaskDependencies(updatedPlan),
    );
    return record.copyWith(execution:
      state.copyWith(verification: TaskVerifier.verify(state)));
  });

  /// Marks a subtask exhausted only after the planner has declared that no
  /// safe strategy remains. Reasons are fixed metadata codes, not model prose.
  Future<TaskRecord> markSubtaskFailed(
    String id, {
    required String subtaskId,
    required String failureCode,
    required List<String> attemptedStrategies,
    required List<String> remainingStrategies,
  }) => _mutate(id, (record) {
    if (!const {
      'strategies_exhausted',
      'tool_failed',
      'permission_required',
      'service_unavailable',
      'invalid_response',
    }.contains(failureCode)) {
      throw const FormatException('Invalid subtask failure code');
    }
    final state = record.execution;
    if (record.status != TaskStatus.running || state.inFlight != null) {
      throw StateError('Task is not ready to update a subtask');
    }
    if (attemptedStrategies.isEmpty ||
        remainingStrategies.isNotEmpty ||
        attemptedStrategies.any(
          (action) => !RegExp(r'^[a-z_]{1,40}$').hasMatch(action),
        )) {
      throw const FormatException('Subtask strategies are not exhausted');
    }
    final failedActions = state.audit
        .where((event) =>
            event.subtaskId == subtaskId &&
            event.phase != 'before' &&
            !event.technicalSuccess)
        .map((event) => event.action)
        .toSet();
    if (!failedActions.containsAll(attemptedStrategies.toSet())) {
      throw const FormatException('Subtask failure lacks failed action evidence');
    }
    final exists = state.plan.any((subtask) => subtask.id == subtaskId);
    if (!exists) throw const FormatException('Unknown subtask');
    var plan = state.plan.map((subtask) {
      if (subtask.id != subtaskId) return subtask;
      if (const {
        TaskSubtaskStatus.completed,
        TaskSubtaskStatus.blocked,
        TaskSubtaskStatus.needsReview,
      }.contains(subtask.status)) {
        throw StateError('Subtask cannot be marked failed in its current state');
      }
      return subtask.copyWith(
        status: TaskSubtaskStatus.failed,
        failureCode: failureCode,
      );
    }).toList();
    plan = _refreshSubtaskDependencies(plan);
    return record.copyWith(
      execution: state.copyWith(plan: plan, verification: 'partial'),
    );
  });

  Future<String?> runnableSubtaskId(String id) {
    // This is a read-only helper; execution writes still validate the target
    // transactionally in beginAction.
    return _serialized(() async {
      final record = (await _read()).where((item) => item.identifier == id);
      if (record.isEmpty) return null;
      final plan = record.first.execution.plan;
      for (final subtask in plan) {
        if ((subtask.status == TaskSubtaskStatus.pending ||
                subtask.status == TaskSubtaskStatus.inProgress) &&
            plan
                .where((candidate) =>
                    subtask.dependencies.contains(candidate.id))
                .every((dependency) =>
                    dependency.status == TaskSubtaskStatus.completed)) {
          return subtask.id;
        }
      }
      return null;
    });
  }

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