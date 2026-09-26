/// Durable execution metadata deliberately excludes tool arguments and output.
enum TaskSubtaskStatus {
  pending,
  inProgress,
  completed,
  failed,
  blocked,
  needsReview,
}

class TaskSubtask {
  final String id;
  final String objective;
  final List<String> dependencies;
  final List<String> criteria;
  final Map<String, List<String>> evidenceRefs;
  final TaskSubtaskStatus status;
  final int attempts;
  final String? failureCode;

  const TaskSubtask({
    required this.id,
    required this.objective,
    this.dependencies = const [],
    this.criteria = const [],
    this.evidenceRefs = const {},
    this.status = TaskSubtaskStatus.pending,
    this.attempts = 0,
    this.failureCode,
  });

  TaskSubtask copyWith({
    List<String>? dependencies,
    List<String>? criteria,
    Map<String, List<String>>? evidenceRefs,
    TaskSubtaskStatus? status,
    int? attempts,
    String? failureCode,
    bool clearFailureCode = false,
  }) => TaskSubtask(
    id: id,
    objective: objective,
    dependencies: dependencies ?? this.dependencies,
    criteria: criteria ?? this.criteria,
    evidenceRefs: evidenceRefs ?? this.evidenceRefs,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    failureCode: clearFailureCode ? null : failureCode ?? this.failureCode,
  );

  Map<String, dynamic> toJson() => {'id': id, 'objective': objective,
    'dependencies': dependencies, 'criteria': criteria, 'evidenceRefs': evidenceRefs,
    'status': status.name, 'attempts': attempts, 'failureCode': failureCode};

  static TaskSubtaskStatus _statusFromJson(Object? value) =>
      TaskSubtaskStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => TaskSubtaskStatus.pending,
      );

  factory TaskSubtask.fromJson(Map<String, dynamic> j) => TaskSubtask(
    id: j['id'] as String, objective: j['objective'] as String,
    dependencies: List<String>.from(j['dependencies'] ?? []),
    criteria: List<String>.from(j['criteria'] ?? []),
    evidenceRefs: (j['evidenceRefs'] as Map? ?? {}).map((k, v) =>
      MapEntry(k as String, List<String>.from(v))),
    status: _statusFromJson(j['status']),
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    failureCode: j['failureCode'] as String?,
  );
}

class ActionAudit {
  final int sequence;
  final String action;
  final String phase;
  final DateTime timestamp;
  final bool mutation;
  final bool technicalSuccess;
  final int revision;
  final String outcome;
  final String? subtaskId;
  const ActionAudit({required this.sequence, required this.action,
    required this.phase, required this.timestamp, required this.mutation,
    required this.revision, this.technicalSuccess = false,
    this.outcome = 'unverified', this.subtaskId});
  String get evidenceId => 'action-$sequence';
  Map<String, dynamic> toJson() => {'sequence': sequence, 'action': action,
    'phase': phase, 'timestamp': timestamp.toIso8601String(),
    'mutation': mutation, 'technicalSuccess': technicalSuccess,
    'revision': revision, 'outcome': outcome, 'subtaskId': subtaskId};
  factory ActionAudit.fromJson(Map<String, dynamic> j) => ActionAudit(
    sequence: j['sequence'] as int, action: j['action'] as String,
    phase: j['phase'] as String, timestamp: DateTime.parse(j['timestamp']),
    mutation: j['mutation'] == true, technicalSuccess: j['technicalSuccess'] == true,
    revision: j['revision'] as int? ?? 0, outcome: j['outcome'] ?? 'unverified',
    subtaskId: j['subtaskId'] as String?);
}

class CriterionConfirmation {
  final int revision;
  final String subtaskId;
  final String criterion;
  final DateTime confirmedAt;
  const CriterionConfirmation({required this.revision, required this.subtaskId,
    required this.criterion, required this.confirmedAt});
  Map<String, dynamic> toJson() => {'revision': revision, 'subtaskId': subtaskId,
    'criterion': criterion, 'confirmedAt': confirmedAt.toIso8601String()};
  factory CriterionConfirmation.fromJson(Map<String, dynamic> j) =>
    CriterionConfirmation(revision: j['revision'] as int,
      subtaskId: j['subtaskId'] as String, criterion: j['criterion'] as String,
      confirmedAt: DateTime.parse(j['confirmedAt'] as String));
}

class PendingAssistanceRequest {
  final String id;
  final String question;
  final String blockerType;
  final String evidence;

  const PendingAssistanceRequest({
    required this.id,
    required this.question,
    required this.blockerType,
    required this.evidence,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question,
    'blockerType': blockerType,
    'evidence': evidence,
  };

  factory PendingAssistanceRequest.fromJson(Map<String, dynamic> json) =>
      PendingAssistanceRequest(
        id: json['id'] as String,
        question: json['question'] as String,
        blockerType: json['blockerType'] as String,
        evidence: json['evidence'] as String,
      );
}

enum TaskAssistanceKind { humanStep, criterionReview, mutationReview }

class TaskAssistanceItem {
  final String id;
  final TaskAssistanceKind kind;
  final String title;
  final String details;
  final String? subtaskId;
  final String? criterion;
  final int? actionSequence;

  const TaskAssistanceItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.details,
    this.subtaskId,
    this.criterion,
    this.actionSequence,
  });
}

class TaskExecutionState {
  final List<CriterionConfirmation> criterionConfirmations;
  final List<PendingAssistanceRequest> pendingAssistance;
  final List<String> revisions;
  final List<TaskSubtask> plan;
  final List<ActionAudit> audit;
  final int nextSequence;
  final ActionAudit? inFlight;
  final ActionAudit? lastResult;
  final String verification;
  final List<int> unverifiedMutations;
  const TaskExecutionState({this.revisions = const [], this.plan = const [],
    this.audit = const [], this.nextSequence = 1, this.inFlight,
    this.lastResult, this.verification = 'unverified',
    this.unverifiedMutations = const [], this.criterionConfirmations = const [],
    this.pendingAssistance = const []});
  int get revision => revisions.length;
  TaskExecutionState copyWith({List<String>? revisions, List<TaskSubtask>? plan,
    List<ActionAudit>? audit, int? nextSequence, ActionAudit? inFlight,
    bool clearInFlight = false, ActionAudit? lastResult, String? verification,
     List<int>? unverifiedMutations, List<CriterionConfirmation>? criterionConfirmations,
     List<PendingAssistanceRequest>? pendingAssistance}) =>
    TaskExecutionState(revisions: revisions ?? this.revisions, plan: plan ?? this.plan,
      audit: audit ?? this.audit, nextSequence: nextSequence ?? this.nextSequence,
      inFlight: clearInFlight ? null : inFlight ?? this.inFlight,
      lastResult: lastResult ?? this.lastResult,
      unverifiedMutations: unverifiedMutations ?? this.unverifiedMutations,
      criterionConfirmations: criterionConfirmations ?? this.criterionConfirmations,
      pendingAssistance: pendingAssistance ?? this.pendingAssistance,
      verification: verification ?? this.verification);
  Map<String, dynamic> toJson() => {'revisions': revisions,
    'plan': plan.map((e) => e.toJson()).toList(),
    'audit': audit.map((e) => e.toJson()).toList(), 'nextSequence': nextSequence,
    'inFlight': inFlight?.toJson(), 'lastResult': lastResult?.toJson(),
    'verification': verification, 'unverifiedMutations': unverifiedMutations,
    'criterionConfirmations': criterionConfirmations.map((e) => e.toJson()).toList(),
    'pendingAssistance': pendingAssistance.map((e) => e.toJson()).toList()};
  factory TaskExecutionState.fromJson(Map<String, dynamic> j) => TaskExecutionState(
    revisions: List<String>.from(j['revisions'] ?? []),
    plan: (j['plan'] as List? ?? []).map((e) => TaskSubtask.fromJson(Map<String, dynamic>.from(e))).toList(),
    audit: (j['audit'] as List? ?? []).map((e) => ActionAudit.fromJson(Map<String, dynamic>.from(e))).toList(),
    nextSequence: j['nextSequence'] as int? ?? 1,
    inFlight: j['inFlight'] == null ? null : ActionAudit.fromJson(Map<String, dynamic>.from(j['inFlight'])),
    lastResult: j['lastResult'] == null ? null : ActionAudit.fromJson(Map<String, dynamic>.from(j['lastResult'])),
    verification: j['verification'] as String? ?? 'unverified',
    unverifiedMutations: List<int>.from(j['unverifiedMutations'] ?? []),
    criterionConfirmations: (j['criterionConfirmations'] as List? ?? [])
      .map((e) => CriterionConfirmation.fromJson(Map<String, dynamic>.from(e))).toList(),
    pendingAssistance: (j['pendingAssistance'] as List? ?? [])
      .map((e) => PendingAssistanceRequest.fromJson(Map<String, dynamic>.from(e))).toList());
}