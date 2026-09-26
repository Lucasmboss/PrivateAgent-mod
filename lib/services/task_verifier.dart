import '../models/task_record.dart';

/// A model's completion claim is not evidence. References must resolve to
/// successful observations in the current criteria revision.
class TaskVerifier {
  static bool isMutation(String action, Map<String, dynamic> params) {
    if (action == 'web_request') {
      return !{'GET', 'HEAD'}.contains((params['method'] ?? 'GET').toString().toUpperCase());
    }
    return !{'web_search', 'read_screen', 'read_file', 'list_files', 'wait'}.contains(action);
  }

  /// Audit actions whose successful result can serve as observed evidence.
  /// A task-specific observation must still be linked to the same subtask.
  static bool isObservationAction(String action) => const {
    'web_search',
    'web_request',
    'read_screen',
    'read_file',
    'list_files',
  }.contains(action);

  static bool hasValidCriterionEvidence(
    TaskSubtask task,
    String criterion,
    Map<String, ActionAudit> evidence,
  ) {
    final refs = task.evidenceRefs[criterion] ?? const <String>[];
    return refs.isNotEmpty &&
        refs.every(
          (ref) =>
              evidence.containsKey(ref) &&
              evidence[ref]!.subtaskId == task.id,
        ) &&
        refs.any(
          (ref) =>
              isObservationAction(evidence[ref]!.action) &&
              !evidence[ref]!.mutation,
        );
  }

  /// Unreviewed external effects stay attached to their subtasks across plan
  /// revisions. Criteria can change; an already-dispatched effect cannot.
  static Set<String> unresolvedMutationSubtaskIds(TaskExecutionState state) {
    final trustedOutcomes = {
      for (final event in state.audit)
        if (event.mutation &&
            event.phase == 'after' &&
            const {'userConfirmed', 'userConfirmedFailure', 'observed'}
                .contains(event.outcome))
          event.sequence,
    };
    return {
      for (final event in state.audit)
        if (event.subtaskId != null &&
            event.mutation &&
            event.phase != 'before' &&
            !trustedOutcomes.contains(event.sequence) &&
            (state.unverifiedMutations.contains(event.sequence) ||
                event.phase == 'uncertain' ||
                (event.phase == 'after' && event.technicalSuccess)))
          event.subtaskId!,
    };
  }

  /// Without a reliable subtask association, no dependent work is safe to run.
  static bool hasUnscopedUnresolvedMutation(TaskExecutionState state) {
    final trustedOutcomes = {
      for (final event in state.audit)
        if (event.mutation &&
            event.phase == 'after' &&
            const {'userConfirmed', 'userConfirmedFailure', 'observed'}
                .contains(event.outcome))
          event.sequence,
    };
    final unresolvedEvents = state.audit.where(
      (event) =>
          event.mutation &&
          event.phase != 'before' &&
          !trustedOutcomes.contains(event.sequence) &&
          (state.unverifiedMutations.contains(event.sequence) ||
              event.phase == 'uncertain' ||
              (event.phase == 'after' && event.technicalSuccess)),
    );
    if (unresolvedEvents.any((event) => event.subtaskId == null)) return true;
    for (final sequence in state.unverifiedMutations) {
      if (trustedOutcomes.contains(sequence)) continue;
      final events = state.audit
          .where((event) => event.sequence == sequence && event.mutation)
          .toList();
      if (events.isEmpty || events.any((event) => event.subtaskId == null)) {
        return true;
      }
    }
    return false;
  }

  static Map<String, ActionAudit> _successfulEvidence(
    TaskExecutionState state,
  ) {
    final latestBySequence = <int, ActionAudit>{};
    for (final event in state.audit) {
      if (event.phase == 'after' && event.revision == state.revision) {
        latestBySequence[event.sequence] = event;
      }
    }
    return {
      for (final event in latestBySequence.values)
        if (event.technicalSuccess) event.evidenceId: event,
    };
  }

  static String verify(TaskExecutionState state) {
    if (state.inFlight != null) return 'uncertain';
    if (state.unverifiedMutations.isNotEmpty) return 'partial';
    if (state.pendingAssistance.isNotEmpty) return 'partial';
    if (state.plan.isEmpty) return 'unverified';
    if (state.plan.any((task) => const {
          TaskSubtaskStatus.failed,
          TaskSubtaskStatus.blocked,
          TaskSubtaskStatus.needsReview,
        }.contains(task.status))) {
      return 'partial';
    }
    final evidence = _successfulEvidence(state);
    if (evidence.isEmpty) return 'unverified';
    // Technical success of a mutation is never proof of its user-facing outcome.
    if (evidence.values.any((e) => e.mutation &&
        e.outcome != 'userConfirmed' && e.outcome != 'observed')) return 'partial';
    final completed = <String>{};
    for (final task in state.plan) {
      if (!completed.containsAll(task.dependencies) || task.criteria.isEmpty) return 'partial';
      for (final criterion in task.criteria) {
        if (!hasValidCriterionEvidence(task, criterion, evidence)) {
          return 'partial';
        }
      }
      completed.add(task.id);
    }
    return 'verified';
  }

  /// Returns only subtasks whose trusted criterion review and evidence refs
  /// independently pass. A separate unresolved subtask must not hide progress.
  static Set<String> verifiedSubtaskIds(TaskExecutionState state) {
    final evidence = _successfulEvidence(state);
    if (hasUnscopedUnresolvedMutation(state)) return {};
    final unresolvedMutationSubtasks =
        unresolvedMutationSubtaskIds(state);
    final completed = <String>{};
    for (final task in state.plan) {
      if (const {
            TaskSubtaskStatus.failed,
            TaskSubtaskStatus.blocked,
            TaskSubtaskStatus.needsReview,
          }.contains(task.status) ||
          !completed.containsAll(task.dependencies) ||
          task.criteria.isEmpty ||
          unresolvedMutationSubtasks.contains(task.id)) {
        continue;
      }
      var valid = true;
      for (final criterion in task.criteria) {
        if (!hasValidCriterionEvidence(task, criterion, evidence)) {
          valid = false;
          break;
        }
      }
      if (valid) completed.add(task.id);
    }
    return completed;
  }

  static void validatePlan(List<TaskSubtask> plan) {
    if (plan.isEmpty || plan.length > 30) throw const FormatException('Plan requires 1–30 subtasks');
    final ids = <String>{};
    for (final task in plan) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(task.id) ||
          ids.contains(task.id) ||
          !ids.containsAll(task.dependencies) || task.criteria.isEmpty ||
          task.criteria.toSet().length != task.criteria.length) {
        throw const FormatException('Invalid plan IDs, dependency order or criteria');
      }
      ids.add(task.id);
    }
  }
}