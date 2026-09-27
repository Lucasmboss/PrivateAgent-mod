import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/task_record.dart';
import 'package:private_agent/widgets/resume_task_dialog.dart';

void main() {
  final timestamp = DateTime(2026, 9, 26);
  final task = TaskRecord(
    identifier: 'internal-task-id',
    goal: 'Find the public source',
    status: TaskStatus.paused,
    createdAt: timestamp,
    updatedAt: timestamp,
    execution: const TaskExecutionState(
      plan: [
        TaskSubtask(
          id: 'internal-step-id',
          objective: 'Check the official record',
          criteria: ['The record is available'],
        ),
      ],
    ),
  );

  Future<void> showDialogFor(
    WidgetTester tester,
    ValueChanged<String?> onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(await ResumeTaskDialog.show(context, task));
              },
              child: const Text('Open saved task'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open saved task'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows partial progress and returns one-shot resume context',
      (tester) async {
    String? result;
    await showDialogFor(tester, (value) => result = value);

    expect(find.textContaining('0 of 1 steps'), findsOneWidget);
    expect(find.textContaining('Check the official record'), findsOneWidget);
    expect(find.textContaining('internal-task-id'), findsNothing);
    expect(find.textContaining('internal-step-id'), findsNothing);
    expect(find.textContaining('action-'), findsNothing);
    expect(find.textContaining('budget'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'Use the official source instead.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(result, 'Use the official source instead.');
  });

  testWidgets('cancel does not resume the task', (tester) async {
    String? result = 'not-set';
    await showDialogFor(tester, (value) => result = value);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}