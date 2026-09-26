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
    final evidence = {for (final e in state.audit)
      if (e.phase == 'after' && e.technicalSuccess && e.revision == state.revision)
        e.evidenceId: e};
    if (evidence.isEmpty) return 'unverified';
    // Technical success of a mutation is never proof of its user-facing outcome.
    if (evidence.values.any((e) => e.mutation &&
        e.outcome != 'userConfirmed' && e.outcome != 'observed')) return 'partial';
    final completed = <String>{};
    for (final task in state.plan) {
      if (!completed.containsAll(task.dependencies) || task.criteria.isEmpty) return 'partial';
      for (final criterion in task.criteria) {
        // Successful reads are supporting material, never semantic proof.
        // Only an explicit trusted UI attestation can verify arbitrary goals.
        if (!state.criterionConfirmations.any((c) =>
            c.revision == state.revision && c.subtaskId == task.id &&
            c.criterion == criterion)) return 'unverified';
        final refs = task.evidenceRefs[criterion] ?? [];
        if (refs.isEmpty || refs.any((ref) => !evidence.containsKey(ref))) return 'partial';
        if (!refs.any((ref) => evidence[ref]!.action != 'wait')) return 'partial';
      }
      completed.add(task.id);
    }
    return 'verified';
  }

  /// Returns only subtasks whose trusted criterion review and evidence refs
  /// independently pass. A separate unresolved subtask must not hide progress.
  static Set<String> verifiedSubtaskIds(TaskExecutionState state) {
    final evidence = {
      for (final event in state.audit)
        if (event.phase == 'after' &&
            event.technicalSuccess &&
            event.revision == state.revision)
          event.evidenceId: event,
    };
    final completed = <String>{};
    for (final task in state.plan) {
      if (const {
            TaskSubtaskStatus.failed,
            TaskSubtaskStatus.blocked,
            TaskSubtaskStatus.needsReview,
          }.contains(task.status) ||
          !completed.containsAll(task.dependencies) ||
          task.criteria.isEmpty) {
        continue;
      }
      var valid = true;
      for (final criterion in task.criteria) {
        final confirmed = state.criterionConfirmations.any((confirmation) =>
            confirmation.revision == state.revision &&
            confirmation.subtaskId == task.id &&
            confirmation.criterion == criterion);
        final refs = task.evidenceRefs[criterion] ?? const <String>[];
        if (!confirmed ||
            refs.isEmpty ||
            refs.any((ref) => !evidence.containsKey(ref)) ||
            !refs.any((ref) => evidence[ref]!.action != 'wait')) {
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