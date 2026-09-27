import 'package:flutter/material.dart';
import '../models/task_record.dart';
import '../services/task_progress_summary.dart';

/// Read-only durable metadata with explicit, caller-owned trusted review actions.
class TaskExecutionDetails extends StatelessWidget {
  final TaskRecord record;
  final ValueChanged<int>? onReviewUncertain;
  final ValueChanged<int>? onConfirmOutcome;
  final void Function(TaskSubtask subtask, String criterion, bool confirmed)?
      onReviewCriterion;
  final VoidCallback? onFinalize;

  const TaskExecutionDetails({super.key, required this.record,
    this.onReviewUncertain, this.onConfirmOutcome, this.onReviewCriterion,
    this.onFinalize});

  Widget _criterion(TaskSubtask task, String criterion) {
    final confirmations = record.execution.criterionConfirmations.where((c) =>
        c.revision == record.execution.revision && c.subtaskId == task.id &&
        c.criterion == criterion);
    final confirmed = confirmations.isNotEmpty;
    final enabled = onReviewCriterion != null &&
        record.status != TaskStatus.running && record.execution.inFlight == null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(criterion),
        Text(
          confirmed
              ? 'Independently confirmed'
              : 'Needs independent confirmation',
        ),
        OutlinedButton(
          onPressed: enabled ? () => onReviewCriterion!(task, criterion, !confirmed) : null,
          child: Text(
            confirmed ? 'Review this confirmation' : 'Review this criterion',
          ),
        ),
      ]),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  @override
  Widget build(BuildContext context) {
    final state = record.execution;
    final latest = <int, ActionAudit>{};
    for (final entry in state.audit) {
      latest[entry.sequence] = entry;
    }
    final pending = state.inFlight;
    final reviewableMutations = <int, ActionAudit>{
      for (final event in latest.values)
        if (event.mutation &&
            ((state.unverifiedMutations.contains(event.sequence)) ||
                event.phase == 'uncertain' ||
                (event.phase == 'after' &&
                    event.technicalSuccess &&
                    !const {'userConfirmed', 'observed'}.contains(
                      event.outcome,
                    ))))
          event.sequence: event,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Saved progress'),
      Text(TaskProgressSummary.describe(record)),
      const Text(
        'Tool success alone does not establish a real-world outcome. '
        'External changes are never replayed while their result is uncertain.',
      ),
      if (state.verification == 'verified' && record.status != TaskStatus.completed)
        FilledButton(onPressed: record.status == TaskStatus.running ||
            state.inFlight != null || state.unverifiedMutations.isNotEmpty
            ? null
            : onFinalize,
            child: const Text('Mark task complete')),
      if (pending?.mutation == true) ...[
        _heading('An external change may need review'),
        const Text(
          'Check the destination before confirming what happened. Do not '
          'repeat the action while its outcome is uncertain.',
        ),
        OutlinedButton(
          onPressed: onReviewUncertain == null
              ? null
              : () => onReviewUncertain!(pending!.sequence),
          child: const Text('Review possible change'),
        ),
      ],
      ...reviewableMutations.values
          .where((event) => event.sequence != pending?.sequence)
          .map((event) {
            final reviewAction =
                event.phase == 'uncertain' ||
                    state.unverifiedMutations.contains(event.sequence)
                ? (onReviewUncertain ?? onConfirmOutcome)
                : onConfirmOutcome;
            return OutlinedButton(
              onPressed: reviewAction == null
                  ? null
                  : () => reviewAction(event.sequence),
              child: const Text('Review an external change'),
            );
          }),
      _heading('Progress by step'),
      if (state.plan.isEmpty) const Text('No saved steps are available yet.'),
      ...state.plan.map((task) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(task.objective),
          Text(switch (task.status) {
            TaskSubtaskStatus.pending => 'Not started',
            TaskSubtaskStatus.inProgress => 'In progress',
            TaskSubtaskStatus.completed => 'Verified',
            TaskSubtaskStatus.failed => 'Not completed yet',
            TaskSubtaskStatus.blocked => 'Waiting on earlier work',
            TaskSubtaskStatus.needsReview => 'Needs your review',
          }),
          if (task.criteria.isEmpty) const Text('No success criteria recorded.'),
          ...task.criteria.map((criterion) => _criterion(task, criterion)),
        ]),
      )),
    ]);
  }
}