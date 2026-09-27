import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/task_record.dart';
import 'package:private_agent/widgets/task_execution_details.dart';

void main() {
  final date = DateTime(2026);
  TaskRecord record(TaskExecutionState execution) => TaskRecord(
    identifier: 'test', goal: 'Verify delivery', status: TaskStatus.needsRevision,
    createdAt: date, updatedAt: date, progress: .5, execution: execution);

  Future<void> render(WidgetTester tester, TaskRecord task,
      {ValueChanged<int>? review, ValueChanged<int>? confirm,
      void Function(TaskSubtask, String, bool)? criterionReview,
      VoidCallback? finalize}) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: TaskExecutionDetails(record: task,
        onReviewUncertain: review, onConfirmOutcome: confirm,
        onReviewCriterion: criterionReview, onFinalize: finalize)),
    )));
  }

  testWidgets('criterion review is explicit, revision-bound, and revocable',
      (tester) async {
    const task = TaskSubtask(id: 'delivery', objective: 'Check delivery',
        criteria: ['Receipt exists'], evidenceRefs: {'Receipt exists': ['action-3']});
    final calls = <bool>[];
    void review(TaskSubtask subtask, String criterion, bool confirmed) {
      expect(subtask.id, 'delivery');
      expect(criterion, 'Receipt exists');
      calls.add(confirmed);
    }
    await render(tester, record(const TaskExecutionState(plan: [task])),
        criterionReview: review);
    expect(calls, isEmpty);
    expect(find.text('Mark task complete'), findsNothing);
    await tester.ensureVisible(find.text('Review this criterion'));
    await tester.tap(find.text('Review this criterion'));
    expect(calls, [true]);

    await render(tester, record(TaskExecutionState(plan: const [task],
        criterionConfirmations: [CriterionConfirmation(revision: 0,
            subtaskId: 'delivery', criterion: 'Receipt exists', confirmedAt: date)])),
        criterionReview: review);
    await tester.ensureVisible(find.text('Review this confirmation'));
    await tester.tap(find.text('Review this confirmation'));
    expect(calls, [true, false]);

    await render(tester, record(TaskExecutionState(plan: const [task],
        revisions: const ['New goal'],
        criterionConfirmations: [CriterionConfirmation(revision: 0,
            subtaskId: 'delivery', criterion: 'Receipt exists', confirmedAt: date)])),
        criterionReview: review);
    expect(find.text('Needs independent confirmation'), findsOneWidget);
    expect(find.text('Review this confirmation'), findsNothing);
    expect(calls, [true, false]);
  });

  testWidgets('running criterion reviews disabled; finalize requires explicit tap',
      (tester) async {
    const state = TaskExecutionState(verification: 'verified',
        plan: [TaskSubtask(id: 'goal', objective: 'Goal', criteria: ['Done'])]);
    var finalized = 0;
    await render(tester, record(state).copyWith(status: TaskStatus.running),
        criterionReview: (_, _, _) => fail('Must not review running task'),
        finalize: () => finalized++);
    expect(tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Review this criterion')).onPressed, isNull);
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Mark task complete')).onPressed, isNull);
    await render(tester, record(state), finalize: () => finalized++);
    expect(finalized, 0);
    await tester.ensureVisible(find.text('Mark task complete'));
    await tester.tap(find.text('Mark task complete'));
    expect(finalized, 1);
  });

  testWidgets('shows human progress without exposing technical traces',
      (tester) async {
    var confirmations = 0;
    await render(tester, record(TaskExecutionState(
      plan: const [TaskSubtask(id: 'delivery', objective: 'Check delivery',
        dependencies: ['send'], criteria: ['Receipt exists'],
        evidenceRefs: {'Receipt exists': ['action-3']})],
      audit: [ActionAudit(sequence: 3, action: 'send_message', phase: 'after',
        timestamp: date, mutation: true, revision: 0, technicalSuccess: true)],
      unverifiedMutations: const [3],
    )), confirm: (_) => confirmations++);
    expect(find.textContaining('50%'), findsNothing);
    expect(find.textContaining('action-3'), findsNothing);
    expect(find.textContaining('send_message'), findsNothing);
    expect(find.textContaining('Check delivery'), findsOneWidget);
    expect(confirmations, 0);
    await tester.ensureVisible(find.text('Review an external change'));
    await tester.tap(find.text('Review an external change'));
    expect(confirmations, 1);
  });

  testWidgets('uncertain mutation requires explicit review and respects disabled state',
      (tester) async {
    final pending = ActionAudit(sequence: 4, action: 'write_file',
        phase: 'before', timestamp: date, mutation: true, revision: 0);
    final task = record(TaskExecutionState(inFlight: pending, audit: [pending]));
    await render(tester, task);
    expect(find.text('An external change may need review'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Review possible change'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('action-4'), findsNothing);
    expect(find.textContaining('write_file'), findsNothing);
    var reviews = 0;
    await render(tester, task, review: (sequence) {
      reviews++;
      expect(sequence, 4);
    });
    expect(reviews, 0);
    await tester.tap(find.text('Review possible change'));
    expect(reviews, 1);
  });

  testWidgets('recovered uncertain audit remains independently reviewable',
      (tester) async {
    final uncertain = ActionAudit(
      sequence: 7,
      action: 'write_file',
      phase: 'uncertain',
      timestamp: date,
      mutation: true,
      revision: 0,
      technicalSuccess: false,
    );
    int? reviewedSequence;
    await render(
      tester,
      record(
        TaskExecutionState(
          audit: [uncertain],
          unverifiedMutations: const [7],
          verification: 'uncertain',
        ),
      ),
      review: (sequence) => reviewedSequence = sequence,
    );
    const label = 'Review an external change';
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    expect(reviewedSequence, 7);
  });
}