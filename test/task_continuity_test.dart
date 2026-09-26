import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/task_execution_state.dart';
import 'package:private_agent/models/task_record.dart';
import 'package:private_agent/services/task_store.dart';
import 'package:private_agent/services/task_verifier.dart';

void main() {
  late Directory directory;
  late TaskStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('continuity-');
    store = TaskStore(directory: directory);
    await store.create(goal: 'Find source', identifier: 't');
  });
  tearDown(() => directory.delete(recursive: true));

  test('mutations require a validated subtask scope', () {
    expect(
      store.beginAction('t', 'write_file', mutation: true),
      throwsFormatException,
    );
  });

  test('bare completion and invented evidence are rejected', () async {
    expect(store.update('t', status: TaskStatus.completed), throwsStateError);
    final result = await store.verifyCompletion('t', {
      'goal': {'Find source': ['action-999']}
    });
    expect(result.execution.verification, 'unverified');
  });

  test('in-flight mutation survives restart and cannot replay', () async {
    await store.beginAction(
      't',
      'press_enter',
      mutation: true,
      subtaskId: 'goal',
    );
    final fresh = TaskStore(directory: directory);
    await fresh.recoverInterrupted();
    final recovered = (await fresh.get('t'))!;
    expect(recovered.status, TaskStatus.needsRevision);
    expect(recovered.execution.inFlight, isNull);
    expect(recovered.execution.unverifiedMutations, [1]);
    expect(recovered.execution.audit.last.phase, 'uncertain');
    expect(fresh.clear(), throwsStateError);
    await fresh.resolveUncertainAuditAction(
      't',
      sequence: 1,
      userConfirmedSuccess: true,
    );
    expect((await fresh.claim('t', 'Find source')).status, TaskStatus.running);
  });

  test('an independently verified failed mutation is not recorded as success',
      () async {
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction(
      't',
      technicalSuccess: false,
      uncertain: true,
      continueAfterUncertain: true,
    );
    await store.update('t', status: TaskStatus.needsRevision);
    await store.resolveUncertainAuditAction(
      't',
      sequence: 1,
      userConfirmedSuccess: false,
    );

    final resolved = (await store.get('t'))!;
    expect(resolved.execution.unverifiedMutations, isEmpty);
    expect(resolved.execution.audit.last.outcome, 'userConfirmedFailure');
    expect(resolved.execution.audit.last.technicalSuccess, isFalse);
  });

  test('a confirmed missing effect permits a new safe attempt', () async {
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    await store.update('t', status: TaskStatus.needsRevision);
    await store.confirmActionOutcome(
      't',
      1,
      userConfirmedSuccess: false,
    );

    var record = (await store.get('t'))!;
    expect(record.execution.unverifiedMutations, isEmpty);
    expect(record.execution.audit.last.outcome, 'userConfirmedFailure');
    expect(record.execution.audit.last.technicalSuccess, isFalse);
    expect(record.execution.plan.single.status, TaskSubtaskStatus.pending);

    await store.update('t', status: TaskStatus.running);
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: false);
    record = (await store.get('t'))!;
    expect(record.execution.audit.last.sequence, 2);
    expect(record.execution.unverifiedMutations, isEmpty);
    expect(TaskVerifier.verify(record.execution), 'unverified');
  });

  test('same-chat checkpoint keeps its session and completed step count', () async {
    await store.create(
      goal: 'Continue a draft',
      identifier: 'same-chat',
      chatSessionId: 'chat-session-1',
    );
    await store.update(
      'same-chat',
      status: TaskStatus.paused,
      stepsCompleted: 6,
    );

    final restarted = TaskStore(directory: directory);
    await restarted.recoverInterrupted();
    final loaded = (await restarted.get('same-chat'))!;
    expect(loaded.chatSessionId, 'chat-session-1');
    expect(loaded.stepsCompleted, 6);

    final resumed = await restarted.claim('same-chat', 'Continue a draft');
    expect(resumed.chatSessionId, 'chat-session-1');
    expect(resumed.stepsCompleted, 6);
  });

  test('queued human assistance prevents completion until resolved', () async {
    await store.addPendingAssistance(
      't',
      const PendingAssistanceRequest(
        id: 'assist-1',
        question: 'Complete sign-in directly in the app',
        blockerType: 'sign_in',
        evidence: 'The destination requested human sign-in',
      ),
    );
    final partial = await store.verifyCompletion('t', const {});
    expect(partial.execution.verification, 'partial');
    expect(
      store.update('t', status: TaskStatus.completed),
      throwsStateError,
    );

    await store.update('t', status: TaskStatus.needsRevision);
    await store.resolvePendingAssistance('t', {'assist-1'});
    expect((await store.get('t'))!.execution.pendingAssistance, isEmpty);
  });

  test('a linked read alone cannot attest a successful mutation outcome', () async {
    await store.setPlan('t', const [
      TaskSubtask(
        id: 'goal',
        objective: 'Find source',
        criteria: ['Find source'],
      ),
    ]);
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    final mutationOnly = {'goal': {'Find source': ['action-1']}};
    expect(
      (await store.verifyCompletion('t', mutationOnly)).execution.verification,
      'partial',
    );
    await store.beginAction(
      't',
      'read_file',
      mutation: false,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    final observed = {'goal': {'Find source': ['action-2']}};
    final needsReview = await store.verifyCompletion('t', observed);
    expect(needsReview.execution.verification, 'partial');
    expect(needsReview.execution.unverifiedMutations, [1]);
    expect(
      needsReview.execution.plan.single.status,
      TaskSubtaskStatus.needsReview,
    );
    expect(
      needsReview.execution.audit
          .firstWhere((event) => event.sequence == 1 && event.phase == 'after')
          .outcome,
      'unverified',
    );
  });

  test('mutation review blocks only dependents and preserves status on resume',
      () async {
    await store.setPlan('t', const [
      TaskSubtask(
        id: 'changed',
        objective: 'Apply the requested change',
        criteria: ['change is present'],
      ),
      TaskSubtask(
        id: 'followup',
        objective: 'Use the changed state',
        dependencies: ['changed'],
        criteria: ['follow-up is complete'],
      ),
      TaskSubtask(
        id: 'independent',
        objective: 'Complete independent work',
        criteria: ['independent work is complete'],
      ),
    ]);
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'changed',
    );
    await store.endAction('t', technicalSuccess: true);

    final refs = {
      'changed': {
        'change is present': ['action-1'],
      },
    };
    await store.verifyCompletion('t', refs);
    var record = (await store.get('t'))!;
    var subtasks = {
      for (final item in record.execution.plan) item.id: item,
    };
    expect(subtasks['changed']!.status, TaskSubtaskStatus.needsReview);
    expect(subtasks['followup']!.status, TaskSubtaskStatus.blocked);
    expect(subtasks['independent']!.status, TaskSubtaskStatus.pending);
    expect(await store.runnableSubtaskId('t'), 'independent');

    await store.update('t', status: TaskStatus.needsRevision);
    await store.claim('t', 'Find source');
    record = (await store.get('t'))!;
    subtasks = {
      for (final item in record.execution.plan) item.id: item,
    };
    expect(subtasks['changed']!.status, TaskSubtaskStatus.needsReview);
    expect(subtasks['followup']!.status, TaskSubtaskStatus.blocked);
    expect(subtasks['independent']!.status, TaskSubtaskStatus.pending);

    await store.update('t', status: TaskStatus.needsRevision);
    await store.confirmActionOutcome('t', 1);
    await store.update('t', status: TaskStatus.running);
    expect(
      store.beginAction(
        't',
        'write_file',
        mutation: true,
        subtaskId: 'changed',
      ),
      throwsStateError,
    );
    await store.update('t', status: TaskStatus.needsRevision);
    await store.confirmCriterion(
      't',
      expectedRevision: record.execution.revision,
      subtaskId: 'changed',
      criterion: 'change is present',
      confirmed: true,
    );
    record = await store.verifyCompletion('t', refs);
    subtasks = {
      for (final item in record.execution.plan) item.id: item,
    };
    expect(subtasks['changed']!.status, TaskSubtaskStatus.completed);
    expect(subtasks['followup']!.status, TaskSubtaskStatus.pending);
    expect(subtasks['independent']!.status, TaskSubtaskStatus.pending);
  });

  test('revision preserves original goal and invalidates old evidence', () async {
    await store.beginAction('t', 'read_file', mutation: false);
    await store.endAction('t', technicalSuccess: true);
    await store.update('t', status: TaskStatus.paused);
    final resumed = await store.claim('t', 'Different criterion');
    expect(resumed.originalGoal, 'Find source');
    expect(resumed.execution.revisions, ['Different criterion']);
    final result = await store.verifyCompletion('t', {
      'goal': {'Different criterion': ['action-1']}
    });
    expect(result.execution.verification, 'unverified');
  });

  test('a new criteria revision cannot unblock an unresolved mutation', () async {
    await store.setPlan('t', const [
      TaskSubtask(
        id: 'goal',
        objective: 'Apply the requested change',
        criteria: ['The change is present'],
      ),
    ]);
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    await store.update('t', status: TaskStatus.needsRevision);
    await store.claim('t', 'Find source');
    await store.setPlan('t', const [
      TaskSubtask(
        id: 'goal',
        objective: 'Verify the changed file',
        criteria: ['The updated content is present'],
      ),
    ]);

    await store.beginAction(
      't',
      'read_file',
      mutation: false,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    final revised = await store.verifyCompletion('t', {
      'goal': {
        'The updated content is present': ['action-2'],
      },
    });

    expect(revised.execution.verification, 'partial');
    expect(revised.execution.unverifiedMutations, [1]);
    expect(
      revised.execution.plan.single.status,
      TaskSubtaskStatus.needsReview,
    );
    expect(await store.runnableSubtaskId('t'), isNull);
  });

  test('legacy unscoped mutation blocks all subtasks until reviewed', () async {
    await store.setPlan('t', const [
      TaskSubtask(
        id: 'changed',
        objective: 'Apply a change',
        criteria: ['Change is present'],
      ),
      TaskSubtask(
        id: 'followup',
        objective: 'Use the changed state',
        dependencies: ['changed'],
        criteria: ['Follow-up is complete'],
      ),
      TaskSubtask(
        id: 'independent',
        objective: 'Complete independent work',
        criteria: ['Independent work is complete'],
      ),
    ]);
    await store.beginAction(
      't',
      'write_file',
      mutation: true,
      subtaskId: 'changed',
    );
    await store.endAction('t', technicalSuccess: true);
    await store.update('t', status: TaskStatus.needsRevision);

    final file = File('${directory.path}/tasks.json');
    final records = (jsonDecode(await file.readAsString()) as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final execution = Map<String, dynamic>.from(
      records.single['execution'] as Map,
    );
    execution['audit'] = (execution['audit'] as List)
        .map(
          (item) => Map<String, dynamic>.from(item as Map)
            ..['subtaskId'] = null,
        )
        .toList();
    records.single['execution'] = execution;
    await file.writeAsString(jsonEncode(records));

    final restarted = TaskStore(directory: directory);
    await restarted.claim('t', 'Find source');
    expect(await restarted.runnableSubtaskId('t'), isNull);

    await restarted.update('t', status: TaskStatus.needsRevision);
    await restarted.confirmActionOutcome('t', 1);
    expect(
      (await restarted.get('t'))!.execution.unverifiedMutations,
      isEmpty,
    );
    expect(await restarted.runnableSubtaskId('t'), 'changed');
  });

  test('shared stores serialize actions and refuse racing clears', () async {
    final second = TaskStore(directory: directory);
    await store.beginAction('t', 'read_file', mutation: false);
    expect(second.beginAction('t', 'read_screen', mutation: false), throwsStateError);
    expect(second.clear(), throwsStateError);
    await second.endAction('t', technicalSuccess: true);
    expect((await store.get('t'))!.execution.lastResult!.sequence, 1);
  });

  test('audit is bounded and pending mutation verification is not evicted', () async {
    await store.beginAction(
      't',
      'press_enter',
      mutation: true,
      subtaskId: 'goal',
    );
    await store.endAction('t', technicalSuccess: true);
    for (var i = 0; i < 102; i++) {
      await store.beginAction('t', 'read_screen', mutation: false);
      await store.endAction('t', technicalSuccess: true);
    }
    final state = (await store.get('t'))!.execution;
    expect(state.audit.length, 200);
    expect(state.nextSequence, 104);
    expect(
      state.audit.any(
        (event) =>
            event.sequence == 1 &&
            event.mutation &&
            event.phase == 'after',
      ),
      isTrue,
    );
    expect(
      TaskVerifier.unresolvedMutationSubtaskIds(state),
      contains('goal'),
    );
    expect(TaskVerifier.verify(state), 'partial');
  });

  test('legacy JSON gets safe defaults', () {
    final record = TaskRecord.fromJson({
      'identifier': 'old', 'goal': 'Old goal', 'status': 'paused',
      'createdAt': '2025-01-01T00:00:00Z', 'updatedAt': '2025-01-01T00:00:00Z',
    });
    expect(record.originalGoal, 'Old goal');
    expect(TaskVerifier.verify(record.execution), 'unverified');
  });

  test('dependency cycles and forward references are rejected', () {
    expect(() => TaskVerifier.validatePlan([
      const TaskSubtask(id: 'a', objective: 'A', dependencies: ['b'], criteria: ['A']),
      const TaskSubtask(id: 'b', objective: 'B', dependencies: ['a'], criteria: ['B']),
    ]), throwsFormatException);
  });

  test('unrelated successful read cannot prove an arbitrary criterion', () async {
    await store.beginAction('t', 'read_screen', mutation: false);
    await store.endAction('t', technicalSuccess: true);
    final refs = {'goal': {'Find source': ['action-1']}};
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'partial');
    expect(store.update('t', status: TaskStatus.completed), throwsStateError);
    await store.update('t', status: TaskStatus.needsRevision);
    await store.confirmCriterion('t', expectedRevision: 0, subtaskId: 'goal',
        criterion: 'Find source', confirmed: true);
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'verified');
    await store.setPlan('t', [
      const TaskSubtask(id: 'goal', objective: 'Find source', criteria: ['Find source']),
    ]);
    expect((await store.get('t'))!.execution.criterionConfirmations, isEmpty);
    expect(store.confirmCriterion('t', expectedRevision: 0, subtaskId: 'goal',
        criterion: 'Find source', confirmed: true), throwsStateError);
  });

  test('raw traces and obvious goal credentials never cross persistence boundary', () async {
    const secret = 'sensitive-password-value';
    final created = await store.create(identifier: 'private',
      goal: 'Use password=$secret and https://user:pass@example.org/?token=abc',
      results: ['HTTP body $secret'], failedStrategies: ['shell output $secret']);
    expect(created.encode(), isNot(contains(secret)));
    await store.update('private', results: {'body': secret},
        failedStrategies: ['Authorization: Bearer $secret']);
    final disk = await File('${directory.path}/tasks.json').readAsString();
    expect(disk, isNot(contains(secret)));
    expect(disk, isNot(contains('user:pass')));
    expect((await store.get('private'))!.results['rawContentRetained'], false);
  });

  test('legacy free-text results are removed on read and subsequent rewrite', () async {
    const raw = 'RAW-PRIVATE-BODY';
    final legacy = (await store.get('t'))!.toJson();
    legacy['results'] = [raw];
    legacy['failedStrategies'] = [raw];
    await File('${directory.path}/tasks.json').writeAsString(jsonEncode([legacy]));
    expect((await store.get('t'))!.encode(), isNot(contains(raw)));
    await store.update('t', tokens: 2);
    expect(await File('${directory.path}/tasks.json').readAsString(), isNot(contains(raw)));
  });
}