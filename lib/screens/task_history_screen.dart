
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/task_record.dart';
import '../services/task_history_logger.dart';
import '../services/task_store.dart';
import '../services/task_progress_summary.dart';
import '../widgets/task_execution_details.dart';

class TaskHistoryScreen extends StatefulWidget {
  const TaskHistoryScreen({super.key});

  @override
  State<TaskHistoryScreen> createState() => _TaskHistoryScreenState();
}

class _TaskHistoryScreenState extends State<TaskHistoryScreen> {
  final TaskStore _store = TaskStore();
  List<TaskRecord> _records = [];
  List<Map<String, dynamic>> _legacy = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await _store.list();
      if (mounted) setState(() => _records = records.reversed.toList());
      final legacy = await TaskHistoryLogger.readHistory();
      if (mounted) setState(() => _legacy = legacy);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not refresh history: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
      if (mounted) await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = 'Operation failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _safeToResume(TaskRecord record) =>
      record.status != TaskStatus.running &&
      record.status != TaskStatus.completed &&
      record.execution.inFlight == null &&
      record.execution.unverifiedMutations.isEmpty;

  Future<void> _resume(TaskRecord record) async {
    final controller = TextEditingController(text: record.goal);
    final goal = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revise and resume'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Changing the goal invalidates current criterion evidence. '
                'Previous actions are retained in the audit, not undone.'),
            const SizedBox(height: 12),
            TextField(controller: controller, maxLines: 4,
                decoration: const InputDecoration(labelText: 'Goal')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(context, controller.text.trim());
            }
          }, child: const Text('Resume')),
        ],
      ),
    );
    // Allow the dialog's closing animation to detach its TextField.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (goal == null || !mounted) return;
    await _perform(() async {
      final current = await _store.get(record.identifier);
      if (current == null || !_safeToResume(current)) {
        throw StateError('Task changed or has unresolved actions. Refresh and review before resuming.');
      }
      if (mounted) Navigator.pop(context, current.copyWith(goal: goal));
    });
  }

  Future<void> _review(TaskRecord record, {int? sequence}) async {
    final pending = record.execution.inFlight;
    final unresolvedUncertain = record.execution.audit
        .where(
          (event) =>
              event.phase == 'uncertain' &&
              record.execution.unverifiedMutations.contains(event.sequence),
        )
        .toList();
    final reviewSequence =
        sequence ?? pending?.sequence ??
        (unresolvedUncertain.isEmpty ? null : unresolvedUncertain.last.sequence);
    if (reviewSequence == null) return;
    final auditEvent = pending?.sequence == reviewSequence
        ? pending!
        : record.execution.audit.lastWhere(
            (event) =>
                event.sequence == reviewSequence && event.phase != 'before',
          );
    final uncertain =
        (pending?.sequence == reviewSequence && pending!.mutation) ||
        auditEvent.phase == 'uncertain';
    final decision = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Review possible external change'),
        content: SingleChildScrollView(child: Text(
          'Check the destination app, file, or service before deciding what '
          'happened. A successful tool response or AI claim is not proof.\n\n'
          'This review does not undo an external change. Confirm success only '
          'after you independently verify it. For an external action, mark '
          'failure only if you verify that it did not occur. Unresolved or '
          'successful actions are never replayed. If unsure, keep it unresolved.',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Keep unresolved')),
          if (auditEvent.mutation)
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Verified: intended effect did not occur')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('I independently verified success')),
        ],
      ),
    );
    if (decision == null || !mounted) return;
    await _perform(() async {
      final current = await _store.get(record.identifier);
      if (current == null || current.status == TaskStatus.running ||
          (uncertain &&
              (pending?.sequence == reviewSequence
                  ? current.execution.inFlight?.sequence != reviewSequence
                  : !current.execution.unverifiedMutations.contains(
                      reviewSequence,
                    )))) {
        throw StateError('Task changed during review. Refresh and review the current action.');
      }
      if (uncertain) {
        if (pending?.sequence == reviewSequence) {
          await _store.resolveUncertainAction(
            record.identifier,
            userConfirmedSuccess: decision,
          );
        } else {
          await _store.resolveUncertainAuditAction(
            record.identifier,
            sequence: reviewSequence,
            userConfirmedSuccess: decision,
          );
        }
      } else {
        await _store.confirmActionOutcome(
          record.identifier,
          reviewSequence,
          userConfirmedSuccess: decision,
        );
      }
    });
  }

  Future<void> _reviewCriterion(TaskRecord record, TaskSubtask subtask,
      String criterion, bool confirmed) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(confirmed ? 'Independently verify criterion' : 'Revoke criterion confirmation?'),
        content: SingleChildScrollView(child: SelectableText(
          'Task: ${record.goal}\n'
          'Step: ${subtask.objective}\n'
          'Criterion: $criterion\n\n'
          'Tool success does not establish that this criterion is met. '
          'You must independently verify the actual effects in the destination '
          'app, file, or service. Do not rely on an AI claim.\n\n'
          '${confirmed ? 'Confirm only this criterion if you personally verified it. If unsure, cancel.' : 'Revoking removes your confirmation and requires verification again. It does not undo any external effects.'}',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: Text(confirmed ? 'I independently verified this criterion' : 'Revoke confirmation')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _perform(() async {
      // The store atomically rejects stale revisions and running/in-flight tasks.
      await _store.confirmCriterion(record.identifier,
          expectedRevision: record.execution.revision, subtaskId: subtask.id,
          criterion: criterion, confirmed: confirmed);
    });
  }

  Future<void> _finalize(TaskRecord record) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finalize verified task?'),
        content: const Text('Mark this task completed using its current criterion '
            'confirmations. This does not execute actions or confirm new evidence.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Mark completed')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _perform(() async {
      final current = await _store.get(record.identifier);
      if (current == null || current.execution.revision != record.execution.revision ||
          current.execution.verification != 'verified' || !_safeToResume(current)) {
        throw StateError('Task changed or is not safely verified. Refresh before finalizing.');
      }
      await _store.update(record.identifier, status: TaskStatus.completed);
    });
  }

  Future<void> _clear() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear task history?'),
        content: const Text('Delete saved plans, evidence, audit and legacy logs? '
            'Active or unresolved tasks cannot be cleared. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete history')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _perform(() async {
      // Check the durable store guard before touching the legacy log.
      await _store.clear();
      await TaskHistoryLogger.clearHistory();
    });
  }

  String _date(DateTime date) => DateFormat('MMM d, y h:mm a').format(date);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Task history'), actions: [
      IconButton(tooltip: 'Refresh', onPressed: _busy || _loading ? null : _refresh,
          icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Clear history', onPressed: _busy || _loading ? null : _clear,
          icon: const Icon(Icons.delete_outline)),
    ]),
    body: Column(children: [
      if (_error != null)
        Material(color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(child: SelectableText(_error!)),
              TextButton(onPressed: _loading || _busy ? null : _refresh,
                  child: const Text('Refresh')),
            ]),
          ),
        ),
      if (_loading || _busy) const LinearProgressIndicator(),
      Expanded(child: RefreshIndicator(
        onRefresh: () async { if (!_busy && !_loading) await _refresh(); },
        child: ListView(padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
             Text('Saved tasks (${_records.length})',
                style: Theme.of(context).textTheme.titleLarge),
            if (!_loading && _records.isEmpty)
              const Text('No saved tasks.'),
            ..._records.map((record) => Card(child: ExpansionTile(
              key: PageStorageKey(record.identifier),
              title: Text(record.goal),
              subtitle: Text(
                '${TaskProgressSummary.describe(record)}\n'
                'Updated ${_date(record.updatedAt)}',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                Padding(padding: const EdgeInsets.all(16), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TaskExecutionDetails(record: record,
                      onReviewCriterion: _busy || _loading ? null :
                          (subtask, criterion, confirmed) =>
                              _reviewCriterion(record, subtask, criterion, confirmed),
                      onFinalize: _busy || _loading ? null : () => _finalize(record),
                      onReviewUncertain: _busy || _loading ||
                          record.status == TaskStatus.running ? null :
                          (sequence) => _review(record, sequence: sequence),
                      onConfirmOutcome: _busy || _loading ||
                          record.status == TaskStatus.running ? null :
                          (sequence) => _review(record, sequence: sequence)),
                    Wrap(spacing: 8, children: [
                      FilledButton(onPressed: _busy || _loading || !_safeToResume(record)
                          ? null : () => _resume(record),
                            child: const Text('Review and continue')),
                    ]),
                    if (record.execution.inFlight != null ||
                        record.execution.unverifiedMutations.isNotEmpty)
                      const Text(
                        'Any unresolved effect remains protected against automatic replay and '
                        'will be included in the next combined review.',
                      ),
                  ],
                )),
              ],
            ))),
            const SizedBox(height: 24),
            Text('Legacy execution logs (${_legacy.length})',
                style: Theme.of(context).textTheme.titleLarge),
            const Text('Separate historical logs may overlap saved tasks. Counts are not '
                'added together. Legacy “Success” is a recorded claim, not verified completion.'),
            ..._legacy.map((entry) => Card(child: ExpansionTile(
              title: Text('${entry['goal'] ?? 'Unknown goal'}'),
              subtitle: Text('${entry['status'] ?? 'Unknown'} • ${entry['timestamp'] ?? 'Unknown date'}'),
              children: [Padding(padding: const EdgeInsets.all(16),
                child: SelectableText('Steps: ${entry['steps_taken'] ?? 'Unknown'} • '
                    'Tokens: ${entry['total_tokens'] ?? 'Unknown'}\n'
                    'Trace events: ${entry['trace_event_count'] ?? 0}\n'
                    'Detailed legacy traces are omitted for privacy.'))],
            ))),
          ],
        ),
      )),
    ]),
  );
}