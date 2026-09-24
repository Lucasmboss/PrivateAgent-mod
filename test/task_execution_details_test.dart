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
    expect(find.text('Finalize verified task'), findsNothing);
    await tester.ensureVisible(find.text('Independently review criterion'));
    await tester.tap(find.text('Independently review criterion'));
    expect(calls, [true]);

    await render(tester, record(TaskExecutionState(plan: const [task],
        criterionConfirmations: [CriterionConfirmation(revision: 0,
            subtaskId: 'delivery', criterion: 'Receipt exists', confirmedAt: date)])),
        criterionReview: review);
    await tester.ensureVisible(find.text('Review / revoke criterion confirmation'));
    await tester.tap(find.text('Review / revoke criterion confirmation'));
    expect(calls, [true, false]);

    await render(tester, record(TaskExecutionState(plan: const [task],
        revisions: const ['New goal'],
        criterionConfirmations: [CriterionConfirmation(revision: 0,
            subtaskId: 'delivery', criterion: 'Receipt exists', confirmedAt: date)])),
        criterionReview: review);
    expect(find.text('Not independently confirmed for this revision'), findsOneWidget);
    expect(find.text('Review / revoke criterion confirmation'), findsNothing);
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
        find.widgetWithText(OutlinedButton, 'Independently review criterion')).onPressed, isNull);
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Finalize verified task')).onPressed, isNull);
    await render(tester, record(state), finalize: () => finalized++);
    expect(finalized, 0);
    await tester.ensureVisible(find.text('Finalize verified task'));
    await tester.tap(find.text('Finalize verified task'));
    expect(finalized, 1);
  });

  testWidgets('shows criteria evidence and honest budget without auto-confirming',
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
    expect(find.text('Recorded step-budget indicator: 50%'), findsOneWidget);
    expect(find.text('Depends on: send'), findsOneWidget);
    expect(find.textContaining('Evidence action IDs: action-3'), findsOneWidget);
    expect(find.textContaining('Technical result: success'), findsOneWidget);
    expect(find.textContaining('Outcome evidence: unverified'), findsOneWidget);
    expect(confirmations, 0);
    await tester.ensureVisible(find.text('Independently review action-3 outcome'));
    await tester.tap(find.text('Independently review action-3 outcome'));
    expect(confirmations, 1);
  });

  testWidgets('uncertain mutation requires explicit review and respects disabled state',
      (tester) async {
    final pending = ActionAudit(sequence: 4, action: 'write_file',
        phase: 'before', timestamp: date, mutation: true, revision: 0);
    final task = record(TaskExecutionState(inFlight: pending, audit: [pending]));
    await render(tester, task);
    expect(find.text('Uncertain external effect'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Review uncertain action'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('Technical result: not yet recorded'), findsOneWidget);
    var reviews = 0;
    await render(tester, task, review: (sequence) {
      reviews++;
      expect(sequence, 4);
    });
    expect(reviews, 0);
    await tester.tap(find.text('Review uncertain action'));
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
    const label = 'Review uncertain action-7 outcome';
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    expect(reviewedSequence, 7);
  });
}