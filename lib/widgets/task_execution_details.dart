import 'package:flutter/material.dart';
import '../models/task_record.dart';

/// Read-only durable metadata with explicit, caller-owned trusted review actions.
class TaskExecutionDetails extends StatelessWidget {
  final TaskRecord record;
  final VoidCallback? onReviewUncertain;
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
        SelectableText('Criterion: $criterion\nEvidence action IDs: '
            '${(task.evidenceRefs[criterion] ?? []).isEmpty ? 'None recorded' : task.evidenceRefs[criterion]!.join(', ')}'),
        Text(confirmed
            ? 'User confirmed for revision ${record.execution.revision} at ${confirmations.last.confirmedAt.toLocal()}'
            : 'Not independently confirmed for this revision'),
        OutlinedButton(
          onPressed: enabled ? () => onReviewCriterion!(task, criterion, !confirmed) : null,
          child: Text(confirmed ? 'Review / revoke criterion confirmation' : 'Independently review criterion'),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Execution budget — not goal completion'),
      Text(record.progress.isFinite
          ? 'Recorded step-budget indicator: ${(record.progress.clamp(0, 1) * 100).toStringAsFixed(0)}%'
          : 'Step budget usage unavailable'),
      const Text('Budget consumption does not measure progress toward the goal. '
          'Historical completed records may have this indicator set to 100%; '
          'it is not a verified count of steps.'),
      _heading('Verification'),
      SelectableText('Recorded verification: ${state.verification}\n'
          'Current criteria revision: ${state.revision}'),
      const Text('Technical success is not proof of a real-world outcome. '
          'User confirmations do not automatically verify all criteria.'),
      if (state.verification == 'verified' && record.status != TaskStatus.completed)
        FilledButton(onPressed: record.status == TaskStatus.running ||
            state.inFlight != null || state.unverifiedMutations.isNotEmpty
            ? null : onFinalize, child: const Text('Finalize verified task')),
      if (pending != null) ...[
        _heading(pending.mutation ? 'Uncertain external effect' : 'Unresolved in-flight action'),
        SelectableText('${pending.evidenceId}: ${pending.action}\n'
            'Revision ${pending.revision} • ${pending.phase}\n'
            'Started ${pending.timestamp.toLocal()}'),
        const Text('Do not replay blindly. Independently check the destination '
            'before resolving this action.'),
        OutlinedButton(onPressed: onReviewUncertain,
            child: const Text('Review uncertain action')),
      ],
      if (state.unverifiedMutations.isNotEmpty)
        SelectableText('Unverified mutations: '
            '${state.unverifiedMutations.map((s) => 'action-$s').join(', ')}'),
      _heading('Persistent plan'),
      if (state.plan.isEmpty) const Text('No persistent plan recorded.'),
      ...state.plan.map((task) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SelectableText('${task.id}: ${task.objective}'),
          Text('Depends on: ${task.dependencies.isEmpty ? 'None' : task.dependencies.join(', ')}'),
          if (task.criteria.isEmpty) const Text('No success criteria recorded.'),
          ...task.criteria.map((criterion) => _criterion(task, criterion)),
        ]),
      )),
      _heading('Goal / criteria revisions'),
      SelectableText('Original goal: ${record.originalGoal}'),
      ...state.revisions.asMap().entries.map((entry) =>
          SelectableText('Revision ${entry.key + 1}: ${entry.value}')),
      const Text('A revision may reflect a plan/criteria change even when the goal '
          'text is unchanged. Earlier evidence is retained but may not apply.'),
      _heading('Structured action audit'),
      const Text('Events, not separate actions: the same action ID can appear '
          'before execution, after execution, and after review. Retained audit '
          'may be bounded; missing evidence is not proof of success.'),
      if (state.audit.isEmpty) const Text('No structured audit recorded.'),
      ...state.audit.map((event) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectableText(
          '${event.evidenceId} • ${event.action} • ${event.phase}\n'
          '${event.timestamp.toLocal()} • revision ${event.revision}'
          '${event.revision == state.revision ? ' (current)' : ' (earlier)'}\n'
          'External mutation: ${event.mutation ? 'yes' : 'no'}\n'
          'Technical result: ${event.phase == 'before' ? 'not yet recorded' : event.technicalSuccess ? 'success' : 'not successful / unknown'}\n'
          'Outcome evidence: ${event.outcome == 'userConfirmed' ? 'user-confirmed' : event.outcome == 'observed' ? 'observed' : event.outcome}',
        ),
      )),
      ...latest.values.where((event) => event.phase == 'after' &&
          event.technicalSuccess && event.outcome != 'userConfirmed' &&
          event.outcome != 'observed' && event.sequence != pending?.sequence)
          .map((event) => OutlinedButton(
            onPressed: onConfirmOutcome == null ? null :
                () => onConfirmOutcome!(event.sequence),
            child: Text('Independently review ${event.evidenceId} outcome'),
          )),
    ]);
  }
}