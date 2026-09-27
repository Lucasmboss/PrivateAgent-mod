import '../models/task_record.dart';
import 'task_persistence_privacy.dart';
import 'task_verifier.dart';

/// Produces a concise, human-readable progress summary without exposing the
/// task's internal IDs, tool traces, or execution-budget percentages.
class TaskProgressSummary {
  static String describe(TaskRecord record, {DateTime? now}) {
    final state = record.execution;
    if (state.plan.isEmpty) {
      return 'This task is saved, but no validated steps are available yet.';
    }

    final verifiedIds = TaskVerifier.verifiedSubtaskIds(state);
    final lines = <String>[
      '${verifiedIds.length} of ${state.plan.length} steps are independently verified.',
    ];

    final completed = state.plan
        .where((task) => verifiedIds.contains(task.id))
        .take(2)
        .toList();
    for (final task in completed) {
      final hasFreshSummary = TaskVerifier.hasFreshReusableSummary(
        state,
        task,
        now: now,
      );
      final detail = hasFreshSummary
          ? task.reusableSummary!
          : TaskPersistencePrivacy.reusableSummaryText(task.objective);
      if (detail.isNotEmpty) lines.add('Done: $detail');
    }

    final savedHints = TaskVerifier.freshReusableSummaries(
      state,
      now: now,
    ).where((task) => !verifiedIds.contains(task.id)).take(2);
    for (final task in savedHints) {
      final detail = TaskPersistencePrivacy.reusableSummaryText(
        task.reusableSummary ?? '',
      );
      if (detail.isNotEmpty) lines.add('Saved result: $detail');
    }

    final next = state.plan.cast<TaskSubtask?>().firstWhere(
      (task) =>
          task != null &&
          !verifiedIds.contains(task.id) &&
          (task.status == TaskSubtaskStatus.pending ||
              task.status == TaskSubtaskStatus.inProgress) &&
          state.plan
              .where((dependency) => task.dependencies.contains(dependency.id))
              .every((dependency) => verifiedIds.contains(dependency.id)),
      orElse: () => null,
    );
    if (next != null) {
      final objective = TaskPersistencePrivacy.reusableSummaryText(
        next.objective,
      );
      if (objective.isNotEmpty) lines.add('Next: $objective');
    }

    if (state.unverifiedMutations.isNotEmpty) {
      lines.add(
        '${state.unverifiedMutations.length} external change(s) need review '
        'before related work can continue; they will not be replayed.',
      );
    }
    if (state.pendingAssistance.isNotEmpty) {
      lines.add('A step needs your input before the task can continue.');
    }
    if (state.plan.any(
      (task) =>
          task.status == TaskSubtaskStatus.failed ||
          task.status == TaskSubtaskStatus.blocked ||
          task.status == TaskSubtaskStatus.needsReview,
    )) {
      lines.add(
        'Some work remains incomplete. Add context or try a different approach '
        'when you continue.',
      );
    }
    return lines.join('\n');
  }
}