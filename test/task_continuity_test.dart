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

  test('bare completion and invented evidence are rejected', () async {
    expect(store.update('t', status: TaskStatus.completed), throwsStateError);
    final result = await store.verifyCompletion('t', {
      'goal': {'Find source': ['action-999']}
    });
    expect(result.execution.verification, 'unverified');
  });

  test('in-flight mutation survives restart and cannot replay', () async {
    await store.beginAction('t', 'press_enter', mutation: true);
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
    await store.beginAction('t', 'write_file', mutation: true);
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

  test('technical mutation success does not establish outcome', () async {
    await store.beginAction('t', 'write_file', mutation: true);
    await store.endAction('t', technicalSuccess: true);
    final refs = {'goal': {'Find source': ['action-1']}};
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'partial');
    await store.update('t', status: TaskStatus.needsRevision);
    await store.confirmActionOutcome('t', 1);
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'unverified');
    await store.confirmCriterion('t', expectedRevision: 0, subtaskId: 'goal',
        criterion: 'Find source', confirmed: true);
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'verified');
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

  test('shared stores serialize actions and refuse racing clears', () async {
    final second = TaskStore(directory: directory);
    await store.beginAction('t', 'read_file', mutation: false);
    expect(second.beginAction('t', 'read_screen', mutation: false), throwsStateError);
    expect(second.clear(), throwsStateError);
    await second.endAction('t', technicalSuccess: true);
    expect((await store.get('t'))!.execution.lastResult!.sequence, 1);
  });

  test('audit is bounded and pending mutation verification is not evicted', () async {
    await store.beginAction('t', 'press_enter', mutation: true);
    await store.endAction('t', technicalSuccess: true);
    for (var i = 0; i < 102; i++) {
      await store.beginAction('t', 'read_screen', mutation: false);
      await store.endAction('t', technicalSuccess: true);
    }
    final state = (await store.get('t'))!.execution;
    expect(state.audit.length, 200);
    expect(state.nextSequence, 104);
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
    expect((await store.verifyCompletion('t', refs)).execution.verification, 'unverified');
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