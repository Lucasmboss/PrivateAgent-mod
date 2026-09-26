import '../models/task_record.dart';
import 'task_verifier.dart';

/// Persistence is metadata-only for tool results. Free text is never made safe
/// by attempting to enumerate every possible secret inside a tool response.
class TaskPersistencePrivacy {
  static String goalText(String value) {
    var text = value.replaceAll(RegExp(r'https?://[^\s]+'), '[URL omitted]');
    return _credentials(text);
  }

  static String _credentials(String text) {
    text = text.replaceAll(RegExp(
      r'''(?:bearer|basic)\s+[a-z0-9+/=_\-.]+''', caseSensitive: false),
      '[credential omitted]');
    text = text.replaceAll(RegExp(
      r'''(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|token|password|passwd|secret|authorization|cookie)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false), '[credential omitted]');
    text = text.replaceAll(RegExp(r'\b(?:sk-|nvapi-)[A-Za-z0-9_-]+'), '[credential omitted]');
    return text.length > 2000 ? '${text.substring(0, 2000)} [truncated]' : text;
  }

  static TaskRecord sanitize(TaskRecord record) {
    final json = record.toJson();
    json['goal'] = goalText(record.goal);
    json['originalGoal'] = goalText(record.originalGoal);
    final state = Map<String, dynamic>.from(json['execution']);
    state['revisions'] = record.execution.revisions.map(goalText).toList();
    state['pendingAssistance'] = record.execution.pendingAssistance
        .take(20)
        .map((request) => {
          'id': RegExp(r'^assist-[A-Za-z0-9_-]{1,80}$').hasMatch(request.id)
              ? request.id
              : 'assist-${record.execution.pendingAssistance.indexOf(request)}',
          'question': _credentials(request.question).substring(
            0,
            _credentials(request.question).length > 320
                ? 320
                : _credentials(request.question).length,
          ),
          'blockerType': const {
            'sign_in',
            'private_data',
            'system_permission',
            'human_verification',
          }.contains(request.blockerType)
              ? request.blockerType
              : 'human_verification',
          'evidence': _credentials(request.evidence).substring(
            0,
            _credentials(request.evidence).length > 120
                ? 120
                : _credentials(request.evidence).length,
          ),
        })
        .toList();
    state['plan'] = record.execution.plan.map((s) => {
      'id': goalText(s.id), 'objective': goalText(s.objective),
      'dependencies': s.dependencies.map(goalText).toList(),
      'criteria': s.criteria.map(goalText).toList(),
      'evidenceRefs': s.evidenceRefs.map((key, refs) => MapEntry(goalText(key),
        refs.where((r) => RegExp(r'^action-\d+$').hasMatch(r)).take(200).toList())),
      'status': s.status.name,
      'attempts': s.attempts.clamp(0, 1000),
      'failureCode': const {
        'tool_failed',
        'uncertain_outcome',
        'mutation_outcome_unverified',
        'strategies_exhausted',
        'permission_required',
        'service_unavailable',
        'invalid_response',
        'dependency_failed',
      }.contains(s.failureCode) ? s.failureCode : null,
    }).toList();
    state['criterionConfirmations'] = record.execution.criterionConfirmations.map((c) => {
      ...c.toJson(), 'subtaskId': goalText(c.subtaskId), 'criterion': goalText(c.criterion),
    }).toList();
    Map<String, dynamic> audit(ActionAudit e) => {
      ...e.toJson(),
      'action': RegExp(r'^[a-z_]{1,40}$').hasMatch(e.action) ? e.action : 'unknown',
      'phase': {'before', 'after', 'uncertain'}.contains(e.phase) ? e.phase : 'uncertain',
      'outcome': {
        'unverified',
        'userConfirmed',
        'userConfirmedFailure',
        'observed',
      }.contains(e.outcome)
          ? e.outcome : 'unverified',
      'subtaskId': e.subtaskId != null &&
              RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(e.subtaskId!)
          ? e.subtaskId
          : null,
    };
    final entries = record.execution.audit;
    state['audit'] = entries.skip(entries.length > 200 ? entries.length - 200 : 0)
        .map(audit).toList();
    state['inFlight'] = record.execution.inFlight == null ? null : audit(record.execution.inFlight!);
    state['lastResult'] = record.execution.lastResult == null ? null : audit(record.execution.lastResult!);
    state['verification'] = {'verified', 'unverified', 'partial', 'uncertain'}
        .contains(record.execution.verification) ? record.execution.verification : 'unverified';
    json['execution'] = state;
    final sessionId = record.chatSessionId;
    json['chatSessionId'] = sessionId != null &&
            RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(sessionId)
        ? sessionId
        : null;
    json['stepsCompleted'] = record.stepsCompleted < 0
        ? 0
        : record.stepsCompleted;
    final verification = TaskVerifier.verify(TaskExecutionState.fromJson(state));
    state['verification'] = verification;
    if (record.status == TaskStatus.completed && verification != 'verified') {
      json['status'] = TaskStatus.needsRevision.name;
      json['completedAt'] = null;
    }
    // Never persist incoming bodies, model prose, shell output or free-text
    // error strategies. Safe action/result metadata remains in execution.audit.
    json['results'] = {
      'format': 'metadata-only',
      'actionCount': record.execution.nextSequence - 1,
      'verification': state['verification'],
      'rawContentRetained': false,
    };
    json['failedStrategies'] = <String>[];
    return TaskRecord.fromJson(json);
  }
}