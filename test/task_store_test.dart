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
    final updated = await store.update(created.identifier,
        status: TaskStatus.completed, tokens: 12, progress: 1);
    expect(updated.status, TaskStatus.completed);
    expect((await store.list()).single.tokens, 12);
  }, skip: true);

  test('recovers running records as paused', () async {
    await store.create(goal: 'Interrupted', identifier: 'one');
    final freshStore = TaskStore(directory: directory);
    expect((await freshStore.list()).single.status, TaskStatus.running);
    await freshStore.recoverInterrupted();
    expect((await freshStore.get('one'))?.status, TaskStatus.paused);
  }, skip: true);

  test('persists results when updating', () async {
    await store.create(goal: 'Keep result', identifier: 'one');
    await store.update('one', results: {'answer': 'done'});
    expect((await store.get('one'))?.results, {'answer': 'done'});
  }, skip: true);

  test('clears records', () async {
    await store.create(goal: 'Temporary');
    await store.clear();
    expect(await store.list(), isEmpty);
  }, skip: true);
}