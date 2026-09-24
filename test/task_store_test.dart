import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/task_record.dart';
import 'package:private_agent/services/task_store.dart';

void main() {
  late Directory directory;
  late TaskStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('task-store-test-');
    store = TaskStore(directory: directory);
  });

  tearDown(() => directory.delete(recursive: true));

  test('persists and updates records', () async {
    final created = await store.create(goal: 'Do something', identifier: 'one');
    expect((await store.get('one'))?.goal, 'Do something');
    await store.beginAction('one', 'read_screen', mutation: false);
    await store.endAction('one', technicalSuccess: true);
    await store.verifyCompletion('one', {'goal': {'Do something': ['action-1']}});
    await store.update('one', status: TaskStatus.needsRevision);
    await store.confirmCriterion('one', expectedRevision: 0,
        subtaskId: 'goal', criterion: 'Do something', confirmed: true);
    final updated = await store.update(created.identifier,
        status: TaskStatus.completed, tokens: 12, progress: 1);
    expect(updated.status, TaskStatus.completed);
    expect((await store.list()).single.tokens, 12);
  });

  test('recovers running records as paused', () async {
    await store.create(goal: 'Interrupted', identifier: 'one');
    final freshStore = TaskStore(directory: directory);
    expect((await freshStore.list()).single.status, TaskStatus.running);
    await freshStore.recoverInterrupted();
    expect((await freshStore.get('one'))?.status, TaskStatus.paused);
  });

  test('drops raw results when updating', () async {
    await store.create(goal: 'Keep result', identifier: 'one');
    await store.update('one', results: {'answer': 'done'});
    expect((await store.get('one'))?.results['format'], 'metadata-only');
    expect((await store.get('one'))?.results['answer'], isNull);
  });

  test('clears records', () async {
    await store.create(goal: 'Temporary', status: TaskStatus.paused);
    await store.clear();
    expect(await store.list(), isEmpty);
  });
}