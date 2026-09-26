import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'ai_service.dart';
import 'remote_provider_adapter.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'skill_memory_service.dart';
import 'web_service.dart';
import 'web_search_service.dart';
import 'file_service.dart';
import 'tool_registry.dart';
import 'tool_policy.dart';
import 'user_assistance_policy.dart';
import '../privacy_sanitizer.dart';
import 'task_store.dart';
import 'task_persistence_privacy.dart';
import 'task_verifier.dart';
import '../models/task_record.dart';
import '../models/saved_skill.dart';

typedef TaskUserQuestionCallback = Future<Set<String>?> Function(
  List<TaskAssistanceItem> items,
);

/// Executes autonomous multi-step tasks using multiple strategies.
///
/// Strategy priority:
/// 1. Direct HTTP/API
/// 2. Android app/API access
/// 3. Shizuku / shell
/// 4. Screen automation fallback
///
/// The LLM decides which strategy is appropriate for each step.
class ToolOutcomeUncertainException implements Exception {
  const ToolOutcomeUncertainException(this.toolName);

  final String toolName;

  String get userMessage =>
      'The outcome of $toolName is uncertain. The task is paused for review; '
      'confirm the device state before resuming or retrying.';

  @override
  String toString() => userMessage;
}

class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;

  final NotificationService _notificationService;

  final SkillMemoryService _skillMemory = SkillMemoryService();

  /// Direct Internet / HTTP access.
  ///
  /// Kept internal for this first architectural iteration so we do not
  /// need to modify ActionHandler yet.
  final WebService _webService = WebService();
  final FileService _files = FileService();
  final TaskStore _taskStore;
  String? _activeTaskId;
  TaskStatus? lastStatus;
  String? lastTaskId;

  final WebSearchService _webSearchService = WebSearchService();

  /// Callback to report progress messages to the UI.
  final void Function(String message)? onProgress;
  final ToolApprovalCallback? onApproval;
  final TaskUserQuestionCallback? onUserQuestion;
  final String? chatSessionId;
  final int maxTaskTokens;
  final Duration maxTaskDuration;
  RemoteCancellationToken _remoteCancellation = RemoteCancellationToken();
  Timer? _budgetTimer;
  bool _budgetExpired = false;

  /// Set to true to cancel the running task.
  bool _cancelled = false;
  bool _paused = false;
  bool _actionInFlight = false;
  bool _assistanceBatchShown = false;
  bool _blockedByHostPolicy = false;
  bool _blockedByProviderConfiguration = false;
  bool _blockedByResourceLimit = false;

  Completer<void>? _cancelCompleter;
  bool get isActionInFlight => _actionInFlight;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
    this.onApproval,
    this.onUserQuestion,
    this.chatSessionId,
    this.maxTaskTokens = 100000,
    this.maxTaskDuration = const Duration(minutes: 30),
    TaskStore? taskStore,
    NotificationService? notificationService,
  }) : _aiService = aiService,
       _notificationService = notificationService ?? NotificationService(),
       _taskStore = taskStore ?? TaskStore(),
       _screenService = screenService,
       _appLauncher = appLauncher,
       _shizukuService = shizukuService;

  // ===========================================================================
  // CANCEL
  // ===========================================================================

  void cancel() {
    _cancelled = true;
    _remoteCancellation.cancel();

    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  void pause() {
    _paused = true;
    _remoteCancellation.cancel();
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  // ===========================================================================
  // AGENT SYSTEM PROMPT
  // ===========================================================================

  static const String _taskSystemPrompt = '''
You are the execution engine of an autonomous Android agent.

Your objective is to accomplish the user's TASK, not merely perform UI actions.

You have several possible strategies. Choose the most appropriate one.

STRATEGY PRIORITY:

1. Web search for discovering information and relevant sources
2. Direct HTTP/API/web access
3. Android app/API access
4. Shizuku / shell commands
5. Screen automation as fallback

IMPORTANT:
- Do NOT open Chrome merely because the task involves the Internet.
- Use web_search when the task requires discovering information, finding current information, locating webpages, news, documentation, products, services, or other online sources.
- After web_search, use web_request to retrieve the actual contents of relevant webpages when necessary.
- If information can be retrieved directly with HTTP/API, prefer web_request.
- Use open_url only when opening an actual webpage externally is useful or when direct HTTP access cannot provide the required functionality.
- If a webpage requires JavaScript, browser interaction, authentication, or another capability that HTTP cannot provide, consider open_url followed by Screen Automation.
- Use Android UI only when direct/API methods are insufficient.
- If one strategy fails, analyze the result and consider another strategy.
- A failure in one subtask must not stop independent subtasks.
- Never run a subtask while any dependency is incomplete or blocked.
- Do not blindly repeat failed actions.
- The current Android screen may NOT have been read yet.
- If UI interaction is required and the screen has not been read,
  use read_screen first.
- You can combine web actions, Android actions and UI actions in one task.

AVAILABLE ACTIONS:

1. web_search

Search the Internet for information or relevant webpages.

Parameters:
{
  "query": "search query"
}

Use this when the task requires discovering information, finding current information, locating webpages, news, documentation, products, services, or other online sources.

Do NOT open Chrome merely to perform a web search.

After searching, use web_request to retrieve the contents of relevant webpages when necessary.

2. web_request

Direct HTTP/API request.

Parameters:
{
  "method": "GET|POST|PUT|PATCH|DELETE",
  "url": "https://...",
  "headers": {},
  "body": {}
}

Use this whenever direct web/API access is appropriate.

3. open_url

Open a URL externally.

Parameters:
{
  "url": "https://..."
}

Use this when a webpage requires browser interaction, JavaScript rendering, authentication, or another capability that web_request cannot provide.

4. open_app

Open an Android application.

Parameters:
{
  "app_name": "Chrome"
}

5. run_adb_command

Execute an Android shell command through the available Shizuku mechanism.

Parameters:
{
  "command": "..."
}

6. read_screen

Read the current Android accessibility screen.

Parameters:
{}

7. click_text

Click a visible UI element by text.

Parameters:
{
  "text": "exact visible text"
}

8. click_at

Click screen coordinates.

Parameters:
{
  "x": 540,
  "y": 960
}

9. type_text

Type text into the currently focused field.

Parameters:
{
  "text": "hello",
  "field_hint": "optional"
}

10. press_enter

Press the Enter/Search key.

Parameters:
{}

11. scroll

Scroll the current UI.

Parameters:
{
  "direction": "up|down"
}

12. swipe

Perform a swipe.

Parameters:
{
  "startX": 540,
  "startY": 2000,
  "endX": 540,
  "endY": 500
}

13. press_back

Press Android Back.

Parameters:
{}

14. press_home

Press Android Home.

Parameters:
{}

15. wait

Wait for an application or webpage to load.

Parameters:
{
  "milliseconds": 1000
}

16. ask_user

Ask only when a human-only blocker prevents the requested task, after all
applicable automated strategies have been attempted. Never ask for per-action
approval or a general preference.

Parameters:
{
  "question": "Tell the user what to do directly in the target app or Android Settings, then return and tap Done.",
  "blocker_type": "sign_in | private_data | system_permission | human_verification",
  "evidence": "Exact phrase copied from CURRENT SCREEN or an actual tool result",
  "attempted_strategies": ["open_app", "read_screen"],
  "remaining_strategies": []
}

Only name actions listed in ATTEMPTED ACTIONS THIS TASK. Evidence must match an
actual screen or tool result. List every remaining automated strategy; call
ask_user only when that list is empty. Never request passwords, tokens,
verification codes, or other credentials in chat. The user can only confirm
completion or choose not to continue; this is not approval for extra actions.
Wait up to 5 minutes. If the user does not complete the step, use a safe
alternative or report the blocker. Never bypass sign-in or Android security.

17. subtask_failed

Mark a subtask exhausted only after every safe applicable strategy has failed.
This is a status report, not a tool invocation.

Parameters:
{
  "subtask_id": "the planned subtask id",
  "failure_code": "strategies_exhausted",
  "attempted_strategies": ["web_search", "web_request"],
  "remaining_strategies": []
}

The runtime checks that the listed actions actually failed for this subtask.
After marking it failed, continue with independent runnable subtasks.

18. done

Finish the task.

Parameters:
{}

FILE ACTIONS (only in the application's private agent_files directory):
- list_files: {}
- read_file: {"path": "notes.txt"}
- write_file: {"path": "notes.txt", "content": "text"}
- delete_file: {"path": "notes.txt"} (only when explicitly requested by the user)
Do not claim these tools can access arbitrary Android storage.

RESPONSE FORMAT:

Return ONLY valid JSON.

{
  "action": "web_search",
  "params": {},
  "subtask_id": "research",
  "reasoning": "Brief reason for choosing this action.",
  "is_complete": false
}

GENERAL RULES:

- Before starting tools, you may use action "plan" with params.subtasks: an
  ordered array of {id, objective, dependencies: [earlier IDs], criteria: [text]}.
  Changing a plan invalidates prior evidence. Do not re-plan merely to finish.
- Every action that works on a planned subtask must include top-level
  "subtask_id" naming that subtask. Read its persisted status first. Do not
  target completed, failed, or blocked subtasks. A needs-review subtask allows
  read-only observation only; never mutate it or act on its dependents.
- After a tool failure, try a different safe strategy for that subtask, then
  continue with other runnable independent subtasks. Never stop the whole task
  because one subtask failed.
- Use "subtask_failed" only when applicable strategies are exhausted and the
  runtime has recorded those failed attempts. Leave remaining_strategies empty;
  do not invent a failure or mark an uncertain mutation as failed.
- Completion requires action "done" and params.evidence:
  {subtaskId: {criterionText: ["action-N"]}} using persisted successful evidence
  from that same subtask and the current criteria revision.
- Every criterion must cite at least one successful observation action; a bare
  done/is_complete claim or a mutation by itself is not evidence.
- Never replay a successful or uncertain external mutation. To verify its
  outcome, perform a safe read-only observation after it and cite that
  observation for the affected subtask's criterion. If no safe observation can
  establish the effect, keep the task incomplete.

- Choose exactly ONE action at a time.
- Never invent tool results.
- Base decisions on actual previous results.
- If web_search returns no useful results, analyze the failure and consider another search query or another strategy.
- If web_request returns HTTP 4xx, HTTP 5xx, CAPTCHA,
  bot protection or unusable content, do not blindly repeat it.
  Consider another strategy.
- HTTP failure is a strategy failure, NOT a UI failure.
- If a webpage requires JavaScript or interaction that HTTP cannot provide,
  consider open_url followed by Screen Automation.
- If a task can be completed entirely using web_search and web_request,
  do not use UI.
- If a task can be completed entirely using web_request, do not use UI.
- If a task can be completed entirely using Android APIs or shell,
  do not use UI.
- If UI is required, use read_screen before interacting with unknown UI.
- The original task authorizes validated actions needed for its goal. Never ask
  the user to approve each action or expand beyond the requested scope.
- Use ask_user only for a verified human-only blocker after trying all
  applicable automated strategies. Include exact observed evidence, the actual
  attempted action names, and an empty remaining_strategies list. Runtime checks
  reject unsupported blockers, invented evidence, unattempted actions, and
  credential requests. After the user confirms the step, read the screen again.
- If the user does not complete the step, use a safe alternative or report the
  blocker. Never request credentials or bypass authentication or Android
  security.
- Do not claim success unless the user's requested objective was actually achieved.
- Keep reasoning very brief.
''';

  // ===========================================================================
  // JSON EXTRACTION
  // ===========================================================================

  // ===========================================================================
  // EXECUTE TASK
  // ===========================================================================

  Future<String> executeTask(String userGoal, {String? resumeTaskId}) async {
    if (_activeTaskId != null) throw StateError('Executor already running');
    _cancelled = false;
    _paused = false;
    _blockedByHostPolicy = false;
    _blockedByProviderConfiguration = false;
    _blockedByResourceLimit = false;
    var checkpointId = resumeTaskId;
    var continuationCount = 0;
    try {
      while (true) {
        if (_cancelled || _paused) {
          final id = checkpointId ?? lastTaskId;
          if (id != null) {
            final status = _cancelled ? TaskStatus.cancelled : TaskStatus.paused;
            await _taskStore.update(id, status: status);
            lastStatus = status;
            await _notifyTaskCheckpoint(status);
          }
          return _cancelled
              ? 'Task cancelled. Its checkpoint remains available.'
              : 'Task paused. Its checkpoint remains available.';
        }

        String result;
        try {
          result = await _executeTask(userGoal, resumeTaskId: checkpointId);
        } catch (error) {
          if (error is ToolOutcomeUncertainException) {
            _report(error.userMessage);
          } else {
            _report(
              'A recoverable execution error occurred. Saving the checkpoint '
              'and continuing with a fresh attempt.',
            );
            if (error is RemoteProviderException &&
                const {
                  RemoteErrorKind.authentication,
                  RemoteErrorKind.invalidEndpoint,
                  RemoteErrorKind.invalidRequest,
                }.contains(error.kind)) {
              _blockedByProviderConfiguration = true;
            }
          }
          await failUnexpected(error);
          result = error is ToolOutcomeUncertainException
              ? error.userMessage
              : 'Execution interrupted. Continuing from the saved checkpoint.';
        } finally {
          _cancelCompleter = null;
          _budgetTimer?.cancel();
        }

        if (lastStatus == TaskStatus.completed ||
            lastStatus == TaskStatus.cancelled ||
            lastStatus == TaskStatus.paused ||
            lastStatus == TaskStatus.failed) {
          if (lastStatus == TaskStatus.paused ||
              lastStatus == TaskStatus.failed) {
            await _notifyTaskCheckpoint(lastStatus!);
          }
          return result;
        }
        final id = lastTaskId ?? checkpointId;
        if (id == null) return result;
        final checkpoint = await _taskStore.get(id);
        if (checkpoint == null) return result;
        if (checkpoint.status == TaskStatus.completed ||
            checkpoint.status == TaskStatus.cancelled ||
            checkpoint.status == TaskStatus.paused ||
            checkpoint.execution.pendingAssistance.isNotEmpty ||
            _blockedByHostPolicy ||
            _blockedByProviderConfiguration ||
            _blockedByResourceLimit) {
          await _notifyTaskCheckpoint(checkpoint.status);
          return result;
        }
        final nextRunnableSubtask =
            await _taskStore.runnableSubtaskId(id);
        if (nextRunnableSubtask == null) {
          // A fresh planner window cannot make terminal or review-blocked work
          // safe to retry. Keep the checkpoint instead of spinning.
          await _notifyTaskCheckpoint(checkpoint.status);
          return result;
        }

        checkpointId = id;
        continuationCount++;
        _report(
          'Saved checkpoint reached an execution-window boundary. '
          'Continuing automatically (window $continuationCount).',
        );
        await _showTaskNotification(
          'Task Continuing',
          'The task reached an execution-window boundary and is continuing '
              'from its saved checkpoint.',
        );
        await _waitForRetry(continuationCount);
      }
    } finally {
      _cancelCompleter = null;
      _budgetTimer?.cancel();
    }
  }

  Future<String> _executeTask(String userGoal, {String? resumeTaskId}) async {
    _budgetExpired = false;
    _remoteCancellation = RemoteCancellationToken();
    _cancelCompleter = null;
    lastStatus = null;
    lastTaskId = null;
    _assistanceBatchShown = false;
    await ScreenAutomationService.logToNative(
      '[TaskExecutor] executeTask() started',
    );
    final previousTask = resumeTaskId == null
        ? null
        : await _taskStore.get(resumeTaskId);
    final task = previousTask == null
        ? resumeTaskId == null
              ? await _taskStore.create(
                  goal: userGoal,
                  chatSessionId: chatSessionId,
                )
              : throw StateError('Task not found')
        : await _taskStore.claim(resumeTaskId!, userGoal);
    _activeTaskId = task.identifier;
    lastTaskId = task.identifier;
    // The wall-clock and token budgets are cumulative across automatic planner
    // windows and explicit resumes.
    final remainingTime =
        maxTaskDuration - DateTime.now().difference(task.createdAt);
    if (remainingTime <= Duration.zero) {
      _budgetExpired = true;
    } else {
      _budgetTimer = Timer(remainingTime, () {
        _budgetExpired = true;
        _remoteCancellation.cancel();
        if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
          _cancelCompleter!.complete();
        }
      });
    }

    final results = <String>[];

    results.add('Starting task: $userGoal');
    if (previousTask != null) {
      results.insertAll(0, [
        'Resuming from saved checkpoint at step ${previousTask.stepsCompleted}.',
        'The durable plan and action audit are restored. Raw tool output is not stored.',
      ]);
    }

    _report('Starting task: $userGoal');

    // Every operation goes through the checkpointed planner and policy gate.
    String lastAction = '';

    int sameActionCount = 0;

    int consecutiveFailures = 0;
    String lastFailedAction = '';

    final List<String> failedStrategies = [
      for (final event in previousTask?.execution.audit ?? const <ActionAudit>[])
        if (event.mutation &&
            event.phase == 'uncertain' &&
            (previousTask?.execution.unverifiedMutations.contains(
                  event.sequence,
                ) ??
                false))
          '${event.action}: prior external effect remains unverified; do not replay',
      for (final event in previousTask?.execution.audit ?? const <ActionAudit>[])
        if (event.phase == 'after' &&
            !event.technicalSuccess &&
            event.subtaskId != null)
          '${event.subtaskId}: ${event.action} failed previously; do not repeat '
              'without a materially different strategy',
    ];

    int totalTokens = previousTask?.tokens ?? 0;

    final List<ActionStep> executedSteps = [];
    final attemptedActions = <String>{};
    attemptedActions.addAll(
      previousTask?.execution.audit.map((event) => event.action) ??
          const <String>[],
    );
    for (final result in results) {
      const attemptPrefix = 'Attempted actions so far: ';
      if (result.startsWith(attemptPrefix)) {
        attemptedActions.addAll(
          result
              .substring(attemptPrefix.length)
              .split(',')
              .map((action) => action.trim())
              .where((action) => action.isNotEmpty),
        );
      }
    }

    // -------------------------------------------------------------------------
    // Screen state
    //
    // Empty means:
    // "The screen has not been read yet or is stale."
    //
    // This is the key architectural change.
    // -------------------------------------------------------------------------

    String screenContent = '';

    String previousResult = '';

    // -------------------------------------------------------------------------
    // MAIN AGENT LOOP
    // -------------------------------------------------------------------------

    var consecutiveVerifierGaps = 0;
    var plannerFailures = 0;
    var formatFailures = 0;
    var invalidPlanFailures = 0;
    final stepBase = task.stepsCompleted;
    final finalRetrySubtaskIds = <String>{};

    Future<bool> tryFinalSafeRetry() async {
      final reopened = await _taskStore.reopenSafeFailedSubtasksForRetry(
        _activeTaskId!,
        alreadyRetriedSubtaskIds: finalRetrySubtaskIds,
      );
      if (reopened.isEmpty) return false;

      finalRetrySubtaskIds.addAll(reopened);
      final latest = (await _taskStore.get(_activeTaskId!))!;
      for (final subtaskId in reopened) {
        for (final event in latest.execution.audit.where(
          (event) =>
              event.subtaskId == subtaskId &&
              event.phase == 'after' &&
              !event.technicalSuccess,
        )) {
          final hint =
              '$subtaskId: ${event.action} failed earlier; use a materially '
              'different safe strategy and do not repeat it.';
          if (!failedStrategies.contains(hint)) failedStrategies.add(hint);
        }
      }

      previousResult =
          'All currently runnable independent work is exhausted. Starting a '
          'bounded final retry for safe failed subtasks: ${reopened.join(', ')}. '
          'Choose a materially different strategy; never replay an uncertain '
          'external effect.';
      results.add(previousResult);
      _report(previousResult);
      screenContent = '';
      consecutiveVerifierGaps = 0;
      return true;
    }

    for (int runStep = 0; runStep < _aiService.maxSteps; runStep++) {
      final step = stepBase + runStep;
      // -----------------------------------------------------------------------
      // Cancellation
      // -----------------------------------------------------------------------

      if (_cancelled) {
        return await _handleCancellation(userGoal, totalTokens, step, results);
      }
      if (_paused) {
        return await _handlePause(
          userGoal,
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }
      if (_budgetExpired || totalTokens >= maxTaskTokens) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }

      await _taskStore.update(
        _activeTaskId!,
        progress: task.progress >
                (runStep / _aiService.maxSteps).clamp(0, 0.99).toDouble()
            ? task.progress
            : (runStep / _aiService.maxSteps).clamp(0, 0.99).toDouble(),
        stepsCompleted: step,
        tokens: totalTokens,
        results: results.length <= 20
            ? results
            : results.sublist(results.length - 20),
        failedStrategies: failedStrategies,
      );

      // -----------------------------------------------------------------------
      // Adaptive delay
      //
      // Web/API actions do not need the old UI delays.
      // -----------------------------------------------------------------------

      if (lastAction == 'open_app') {
        await Future.delayed(const Duration(milliseconds: 1800));
      } else if (lastAction == 'type_text') {
        await Future.delayed(const Duration(milliseconds: 1200));
      } else if (lastAction == 'click_text' || lastAction == 'click_at') {
        await Future.delayed(const Duration(milliseconds: 800));
      } else if (lastAction == 'scroll' || lastAction == 'swipe') {
        await Future.delayed(const Duration(milliseconds: 600));
      }

      // -----------------------------------------------------------------------
      // Build recent results
      // -----------------------------------------------------------------------

      final recentResults = results.length <= 5
          ? results
          : results.sublist(results.length - 5);

      final previousResultText = previousResult.isEmpty
          ? 'None'
          : previousResult;

      String failureHint = '';

      if (consecutiveFailures >= 3) {
        failureHint =
            '''
WARNING:
The agent has failed $consecutiveFailures times recently.

Do NOT blindly repeat the same strategy.
Consider a different tool or method.
''';
      }

      // -----------------------------------------------------------------------
      // Planner prompt
      // -----------------------------------------------------------------------

      final durable = (await _taskStore.get(_activeTaskId!))!;
      final prompt =
          '''
TASK:
$userGoal

ORIGINAL GOAL:
${durable.originalGoal}
PERSISTED PLAN AND SAFE EVIDENCE:
${jsonEncode(durable.execution.toJson())}

CURRENT STEP:
${runStep + 1}/${_aiService.maxSteps}

CURRENT SCREEN:
${screenContent.isEmpty ? 'Not read yet.' : screenContent}

PREVIOUS ACTION:
${lastAction.isEmpty ? 'None' : lastAction}

PREVIOUS ACTION RESULT:
$previousResultText

RECENT RESULTS:
${recentResults.isEmpty ? 'None' : recentResults.join('\n\n')}

CONSECUTIVE FAILURES:
$consecutiveFailures

FAILED STRATEGIES:
${failedStrategies.isEmpty ? 'None' : failedStrategies.join('\n')}

ATTEMPTED ACTIONS THIS TASK:
${attemptedActions.isEmpty ? 'None' : attemptedActions.join(', ')}

$failureHint

Choose the single best next action.

Remember:
- Prefer direct HTTP/API when possible.
- Do NOT open Chrome merely to obtain web information.
- web_search is for discovering information and sources.
- web_request is for retrieving a specific URL or calling a known API.
- Do NOT use web_request as a substitute for web_search.
- If HTTP/API is blocked, change strategy.
- NEVER repeat a strategy listed under FAILED STRATEGIES.
- If a domain has failed because of CAPTCHA, anti-bot, access denial,
  or automated-request blocking, do NOT keep requesting that domain.
- Use web_search or another source instead.
- If UI is necessary and CURRENT SCREEN is "Not read yet.",
  use read_screen first.
- Do not claim completion without actually completing the task.
''';

      // -----------------------------------------------------------------------
      // AI
      // -----------------------------------------------------------------------

      String response;

      try {
        if (_paused)
          return await _handlePause(
            userGoal,
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        if (_cancelled)
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        if (_budgetExpired || totalTokens >= maxTaskTokens) {
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        _cancelCompleter = Completer<void>();

        final aiFuture = _aiService.sendTaskMessage(
          _taskSystemPrompt,
          prompt,
          cancellationToken: _remoteCancellation,
          maxOutputTokens: _remainingOutputTokens(totalTokens),
        );

        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);

        if (_budgetExpired) {
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        if (_paused) {
          return await _handlePause(
            userGoal,
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        if (result == null || _cancelled) {
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        }

        final aiResponse = result;

        response = aiResponse.content;
        plannerFailures = 0;

        totalTokens += aiResponse.totalTokens;
        if (totalTokens >= maxTaskTokens) {
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
      } catch (e) {
        if (_budgetExpired) {
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        if (_paused) {
          return await _handlePause(
            userGoal,
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        if (_cancelled) {
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        }

        if (e is RemoteProviderException &&
            const {
              RemoteErrorKind.authentication,
              RemoteErrorKind.invalidEndpoint,
              RemoteErrorKind.invalidRequest,
            }.contains(e.kind)) {
          _blockedByProviderConfiguration = true;
          const message =
              'The AI provider is not configured or authorized. No action was '
              'dispatched; update the provider configuration to continue.';
          results.add(message);
          _report(message);
          await _finishTask(
            TaskStatus.needsRevision,
            step,
            totalTokens,
            results,
            failedStrategies,
          );
          return message;
        }

        const plannerFailure =
            'The AI planner is temporarily unavailable. No new action was '
            'dispatched; the saved checkpoint will be retried automatically.';
        plannerFailures++;
        previousResult = '$plannerFailure Retry $plannerFailures.';
        results.add(previousResult);
        consecutiveFailures++;
        await _waitForRetry(plannerFailures);
        continue;
      }

      // -----------------------------------------------------------------------
      // Parse action
      // -----------------------------------------------------------------------

      ParsedActionResponse? parsedResponse;
      if (_budgetExpired) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }

      try {
        parsedResponse = _aiService.parseActionResponse(response);
        if (parsedResponse == null) {
          throw const FormatException('No action object in AI response.');
        }
      } catch (firstError) {
        developer.log(
          'AI response was not valid JSON: $firstError',
          name: 'PrivateAgent',
        );

        _report('Retrying step ${step + 1}...');

        await Future.delayed(const Duration(seconds: 1));

        try {
          if (_paused)
            return await _handlePause(
              userGoal,
              totalTokens,
              step,
              results,
              failedStrategies,
            );
          if (_cancelled)
            return await _handleCancellation(
              userGoal,
              totalTokens,
              step,
              results,
            );
          if (_budgetExpired || totalTokens >= maxTaskTokens) {
            return await _stopForBudget(
              totalTokens,
              step,
              results,
              failedStrategies,
            );
          }
          final retryResponse = await _aiService.sendTaskMessage(
            _taskSystemPrompt,
            prompt,
            cancellationToken: _remoteCancellation,
            maxOutputTokens: _remainingOutputTokens(totalTokens),
          );

          totalTokens += retryResponse.totalTokens;
          if (totalTokens >= maxTaskTokens) {
            return await _stopForBudget(
              totalTokens,
              step,
              results,
              failedStrategies,
            );
          }

          parsedResponse = _aiService.parseActionResponse(
            retryResponse.content,
          );
          if (parsedResponse == null) {
            throw const FormatException('No action object in AI response.');
          }
        } catch (e) {
          if (_budgetExpired)
            return await _stopForBudget(
              totalTokens,
              step,
              results,
              failedStrategies,
            );
          if (_paused)
            return await _handlePause(
              userGoal,
              totalTokens,
              step,
              results,
              failedStrategies,
            );
          if (_cancelled)
            return await _handleCancellation(
              userGoal,
              totalTokens,
              step,
              results,
            );
          const formattingFailure =
              'The AI response remained invalid after a retry. No tool was '
              'dispatched; requesting a fresh response automatically.';
          formatFailures++;
          previousResult = '$formattingFailure Retry $formatFailures.';
          results.add(previousResult);
          consecutiveFailures++;
          _report(previousResult);
          await _waitForRetry(formatFailures);
          continue;
        }
      }

      // ----------------------------------------------------------------------
      // NORMALIZE TOOL CALL
      // ----------------------------------------------------------------------

      final toolResponse = parsedResponse;
      if (toolResponse == null) {
        previousResult = 'Tool rejected: invalid or missing action.';
        results.add(previousResult);
        consecutiveFailures++;
        continue;
      }
      formatFailures = 0;

      var action = toolResponse.action.action;
      var params = toolResponse.action.params;
      final reasoning = toolResponse.reasoning;
      final isComplete = toolResponse.isComplete;
      developer.log('Selected action: $action', name: 'PrivateAgent');

      String? activeSubtaskId;
      if (!const {'ask_user', 'done', 'plan', 'subtask_failed'}
          .contains(action)) {
        final saved = await _taskStore.get(_activeTaskId!);
        final plan = saved?.execution.plan ?? const <TaskSubtask>[];
        if (plan.isNotEmpty) {
          final requestedId = toolResponse.subtaskId?.trim();
          final targetId = requestedId == null || requestedId.isEmpty
              ? await _taskStore.runnableSubtaskId(_activeTaskId!)
              : requestedId;
          final targets = plan.where((subtask) => subtask.id == targetId);
          if (targetId == null || targets.isEmpty) {
            previousResult =
                'No runnable subtask matches this action. Select a pending '
                'subtask whose dependencies are complete.';
            results.add(previousResult);
            consecutiveFailures++;
            continue;
          }
          final target = targets.first;
          final dependenciesComplete = plan
              .where((subtask) => target.dependencies.contains(subtask.id))
              .every((subtask) =>
                  subtask.status == TaskSubtaskStatus.completed);
          if (!dependenciesComplete ||
              const {
                TaskSubtaskStatus.completed,
                TaskSubtaskStatus.failed,
                TaskSubtaskStatus.blocked,
              }.contains(target.status) ||
              (target.status == TaskSubtaskStatus.needsReview &&
                  TaskVerifier.isMutation(action, params))) {
            previousResult =
                'Subtask ${target.id} is not runnable. Do not repeat it; '
                'choose an independent pending subtask.';
            results.add(previousResult);
            consecutiveFailures++;
            continue;
          }
          activeSubtaskId = target.id;
        } else if (toolResponse.subtaskId?.trim().isNotEmpty == true) {
          previousResult = 'The task has no plan containing that subtask id.';
          results.add(previousResult);
          consecutiveFailures++;
          continue;
        }
      }

      _report('Step ${step + 1}: $reasoning');
      if (_paused) {
        return await _handlePause(
          userGoal,
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }
      if (_cancelled) {
        return await _handleCancellation(userGoal, totalTokens, step, results);
      }
      if (_budgetExpired) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }
      ValidatedToolCall call;
      try {
        call = const ToolRegistry().validate(action, params);
      } on ToolValidationException {
        previousResult = 'Tool rejected: invalid or unsupported parameters.';
        results.add(previousResult);
        consecutiveFailures++;
        continue;
      }
      action = call.name;
      params = call.params;
      if (onApproval != null && const ToolPolicy().isMutation(call)) {
        _report('Checking host policy: $action');
      }
      final decision = await _authorizeTool(call);
      // Recheck stop conditions after any host policy callback before acting.
      if (_paused)
        return await _handlePause(
          userGoal,
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      if (_cancelled)
        return await _handleCancellation(userGoal, totalTokens, step, results);
      if (_budgetExpired) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }
      if (!decision.allowed) {
        _blockedByHostPolicy = true;
        const denied =
            'Action denied. Task requires revision; no tool was executed.';
        results.add(denied);
        _report(denied);
        await _finishTask(
          TaskStatus.needsRevision,
          step,
          totalTokens,
          results,
          failedStrategies,
        );
        return denied;
      }

      if (!const {'ask_user', 'done', 'plan', 'subtask_failed'}
          .contains(action)) {
        attemptedActions.add(action);
        results.add('Attempted actions so far: ${attemptedActions.join(', ')}');
      }

      // -----------------------------------------------------------------------
      // Repeat protection
      // -----------------------------------------------------------------------

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;

      final repeatLimit = action == 'press_enter'
          ? 2
          : (action == 'scroll' || action == 'swipe')
          ? 3
          : 1000;

      if (sameActionCount > repeatLimit) {
        final blockedResult =
            'Blocked repeated $action action. '
            'Use a different strategy.';

        results.add(blockedResult);

        _report(blockedResult);

        previousResult = blockedResult;

        consecutiveFailures++;

        lastFailedAction = action;

        lastAction = action;

        continue;
      }

      lastAction = action;

      if (action == 'subtask_failed') {
        final attempted = List<String>.from(
          params['attempted_strategies'] as List,
        );
        final remaining = List<String>.from(
          params['remaining_strategies'] as List,
        );
        try {
          if (params['failure_code'] != 'strategies_exhausted') {
            throw const FormatException('Invalid subtask failure code');
          }
          final subtaskId = params['subtask_id'] as String;
          await _taskStore.markSubtaskFailed(
            _activeTaskId!,
            subtaskId: subtaskId,
            failureCode: 'strategies_exhausted',
            attemptedStrategies: attempted,
            remainingStrategies: remaining,
          );
          previousResult =
              'Subtask $subtaskId is recorded as failed after its listed '
              'strategies were exhausted. Continue with independent subtasks.';
          results.add(previousResult);
          _report(previousResult);
          consecutiveFailures = 0;
        } catch (_) {
          previousResult =
              'Subtask failure report rejected: failed attempts or exhausted '
              'strategies could not be verified. Continue safely.';
          results.add(previousResult);
          consecutiveFailures++;
        }
        continue;
      }

      // -----------------------------------------------------------------------
      // DONE
      // -----------------------------------------------------------------------

      // is_complete attached to a tool is only a hint: execute the tool first.
      if (action == 'done') {
        final references = <String, Map<String, List<String>>>{};
        final rawEvidence = params['evidence'];
        if (rawEvidence is Map) {
          for (final entry in rawEvidence.entries) {
            if (entry.value is Map) {
              references[entry.key.toString()] = (entry.value as Map).map(
                (k, v) => MapEntry(
                  k.toString(),
                  v is List ? v.whereType<String>().toList() : <String>[],
                ),
              );
            }
          }
        }
        var verified = await _taskStore.verifyCompletion(
          _activeTaskId!,
          references,
        );
        if (_paused)
          return await _handlePause(
            userGoal,
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        if (_cancelled)
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        if (_budgetExpired)
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        final missingEvidence = _completionEvidenceGaps(verified.execution);
        final assistanceItems = _assistanceItems(verified.execution);
        if (verified.execution.verification != 'verified' ||
            assistanceItems.isNotEmpty) {
          if (verified.execution.verification != 'verified') {
            consecutiveVerifierGaps++;
          }
          final nextRunnableSubtask =
              await _taskStore.runnableSubtaskId(_activeTaskId!);
          final readyForBatch =
              missingEvidence.isEmpty ||
              consecutiveVerifierGaps >= 2 ||
              nextRunnableSubtask == null;
          if (!_assistanceBatchShown &&
              readyForBatch &&
              assistanceItems.isNotEmpty) {
            _assistanceBatchShown = true;
            await _taskStore.update(
              _activeTaskId!,
              status: TaskStatus.needsRevision,
            );
            _report(
              'Automated work is complete. Asking only for the verified '
              'human-only steps that remain.',
            );
            final selectedIds = await _requestUserAnswer(assistanceItems);
            if (_paused) {
              return await _handlePause(
                userGoal,
                totalTokens,
                step,
                results,
                failedStrategies,
              );
            }
            if (_cancelled) {
              return await _handleCancellation(
                userGoal,
                totalTokens,
                step,
                results,
              );
            }
            if (_budgetExpired) {
              return await _stopForBudget(
                totalTokens,
                step,
                results,
                failedStrategies,
              );
            }
            if (selectedIds == null) {
              if (await tryFinalSafeRetry()) continue;
              final outcome = await _subtaskOutcomeReport();
              final message =
                  'Task checkpoint saved. The combined review request timed out '
                  'or was declined; resume it from this chat when ready.\n'
                  '$outcome';
              results.add(message);
              await _finishTask(
                TaskStatus.needsRevision,
                step,
                totalTokens,
                results,
                failedStrategies,
              );
              _report(message);
              return message;
            }

            final allowedIds = assistanceItems.map((item) => item.id).toSet();
            final acceptedIds = selectedIds.intersection(allowedIds);
            final resolvedHumanIds = assistanceItems
                .where(
                  (item) =>
                      item.kind == TaskAssistanceKind.humanStep &&
                      acceptedIds.contains(item.id),
                )
                .map((item) => item.id)
                .toSet();
            if (resolvedHumanIds.isNotEmpty) {
              await _taskStore.resolvePendingAssistance(
                _activeTaskId!,
                resolvedHumanIds,
              );
            }

            var current = (await _taskStore.get(_activeTaskId!))!;
            for (final item in assistanceItems) {
              if (!acceptedIds.contains(item.id)) continue;
              if (item.kind == TaskAssistanceKind.criterionReview &&
                  item.subtaskId != null &&
                  item.criterion != null) {
                await _taskStore.confirmCriterion(
                  _activeTaskId!,
                  expectedRevision: current.execution.revision,
                  subtaskId: item.subtaskId!,
                  criterion: item.criterion!,
                  confirmed: true,
                );
                current = (await _taskStore.get(_activeTaskId!))!;
              } else if (item.kind == TaskAssistanceKind.mutationReview &&
                  item.actionSequence != null) {
                final event = current.execution.audit.lastWhere(
                  (entry) =>
                      entry.sequence == item.actionSequence &&
                      entry.mutation &&
                      entry.phase != 'before',
                );
                if (event.phase == 'uncertain') {
                  await _taskStore.resolveUncertainAuditAction(
                    _activeTaskId!,
                    sequence: event.sequence,
                    userConfirmedSuccess: true,
                  );
                } else if (event.technicalSuccess) {
                  await _taskStore.confirmActionOutcome(
                    _activeTaskId!,
                    event.sequence,
                  );
                }
                current = (await _taskStore.get(_activeTaskId!))!;
              }
            }
            verified = await _taskStore.verifyCompletion(
              _activeTaskId!,
              const {},
            );
            if (resolvedHumanIds.isNotEmpty) {
              await _taskStore.update(
                _activeTaskId!,
                status: TaskStatus.running,
              );
              previousResult =
                  'The user completed one or more queued human-only steps. '
                  'Re-read the current state and continue the original goal. '
                  'Do not replay unresolved mutations.';
              screenContent = '';
              continue;
            }
            if (verified.execution.verification != 'verified' ||
                verified.execution.pendingAssistance.isNotEmpty) {
              final runnable =
                  await _taskStore.runnableSubtaskId(_activeTaskId!);
              if (runnable != null) {
                await _taskStore.update(
                  _activeTaskId!,
                  status: TaskStatus.running,
                );
                previousResult =
                    'Review is complete for the selected items. Continue with '
                    'the remaining independent runnable subtasks.';
                screenContent = '';
                continue;
              }
              if (await tryFinalSafeRetry()) continue;
              final report = await _subtaskOutcomeReport();
              results.add(report);
              await _finishTask(
                TaskStatus.needsRevision,
                step,
                totalTokens,
                results,
                failedStrategies,
              );
              _report(report);
              return report;
            }
          }

          if (verified.execution.verification != 'verified' ||
              verified.execution.pendingAssistance.isNotEmpty) {
          final runnable =
              await _taskStore.runnableSubtaskId(_activeTaskId!);
          if (runnable == null) {
            if (await tryFinalSafeRetry()) continue;
            final report = await _subtaskOutcomeReport();
            results.add(report);
            await _finishTask(
              TaskStatus.needsRevision,
              step,
              totalTokens,
              results,
              failedStrategies,
            );
            _report(report);
            return report;
          }
            if (_assistanceBatchShown && finalRetrySubtaskIds.isEmpty) {
            final report = await _subtaskOutcomeReport();
            final message =
                'Task checkpoint saved. Remaining criteria or human-only steps '
                'are listed for review; continue from this chat when ready.\n'
                '$report';
            results.add(message);
              await _finishTask(
                TaskStatus.needsRevision,
                step,
                totalTokens,
                results,
                failedStrategies,
              );
              _report(message);
              return message;
            }
            previousResult = missingEvidence.isEmpty
                ? 'Completion is not verified. Gather new evidence or complete '
                      'another useful independent step; do not repeat done.'
                : 'Completion evidence is missing for: '
                      '${missingEvidence.join('; ')}. Continue with a different '
                      'strategy or another independent subtask. Do not stop yet.';
            results.add(
              'Completion check found gaps; the planner will continue autonomously.',
            );
            continue;
          }
        }
        consecutiveVerifierGaps = 0;
        final explanation = PrivacySanitizer.sanitizeTaskTrace(
          reasoning.trim().isEmpty ? 'Done.' : reasoning.trim(),
        );
        final evidenceSummary = await _verifiedCompletionEvidenceSummary();
        final finalText = '$explanation\n$evidenceSummary';

        results.add('Task complete: $finalText');

        _report('Task complete: $finalText');

        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          finalText,
        );

        await _finishTask(
          TaskStatus.completed,
          step,
          totalTokens,
          results,
          failedStrategies,
        );

        // Only save UI-based skills.
        //
        // Web/API tasks should not become UI skills.
        if (executedSteps.isNotEmpty) {
          await _skillMemory.saveSkill(userGoal, executedSteps);
        }

        // Toast requires Accessibility, so only use it when available.
        if (await _screenService.isServiceRunning()) {
          await _screenService.showToast('Task completed');
        }

        return finalText;
      }

      // -----------------------------------------------------------------------
      // READ SCREEN
      // -----------------------------------------------------------------------

      if (action == 'plan') {
        try {
          final rawPlan = params['subtasks'];
          if (rawPlan is! List) {
            throw const FormatException('Missing subtasks');
          }
          await _taskStore.setPlan(
            _activeTaskId!,
            rawPlan
                .map((item) => TaskSubtask.fromJson(
                      Map<String, dynamic>.from(item),
                    ))
                .toList(),
          );
        } catch (error) {
          if (error is! FormatException &&
              error is! TypeError &&
              error is! ArgumentError) {
            rethrow;
          }
          invalidPlanFailures++;
          previousResult =
              'The proposed plan was rejected by structural safety checks. '
              'Create a corrected plan; do not repeat the invalid structure.';
          results.add(previousResult);
          consecutiveFailures++;
          _report(previousResult);
          await _waitForRetry(invalidPlanFailures);
          continue;
        }
        invalidPlanFailures = 0;
        previousResult =
            'Structured plan saved; prior criterion evidence invalidated.';
        continue;
      }

      if (action == 'ask_user') {
        final question = params['question'] as String;
        final eligibility = const UserAssistancePolicy().evaluate(
          question: question,
          blockerType: params['blocker_type'] as String,
          evidence: params['evidence'] as String,
          attemptedStrategies: List<String>.from(
            params['attempted_strategies'] as List,
          ),
          remainingStrategies: List<String>.from(
            params['remaining_strategies'] as List,
          ),
          attemptedActions: attemptedActions,
          currentScreen: screenContent,
          previousResult: previousResult,
          failedStrategies: failedStrategies,
        );
        if (!eligibility.allowed) {
          previousResult =
              'User assistance request rejected: ${eligibility.reason} '
              'Continue autonomously or report the blocker.';
          results.add('User assistance request rejected by runtime checks.');
          consecutiveFailures++;
          continue;
        }
        final requestId =
            'assist-${DateTime.now().microsecondsSinceEpoch}';
        await _taskStore.addPendingAssistance(
          _activeTaskId!,
          PendingAssistanceRequest(
            id: requestId,
            question: question,
            blockerType: params['blocker_type'] as String,
            evidence: params['evidence'] as String,
          ),
        );
        _assistanceBatchShown = false;
        previousResult =
            'A verified human-only step was queued. Continue all independent '
            'work; the user will receive one combined request at the end.';
        results.add('ask_user: human-only step queued for end-of-task review.');
        continue;
      }

      final durableBeforeDispatch = await _taskStore.get(_activeTaskId!);
      final unresolvedMutationSequences =
          durableBeforeDispatch?.execution.unverifiedMutations.toSet() ??
              const <int>{};
      final unresolvedPriorAction = durableBeforeDispatch?.execution.audit.any(
            (event) =>
                event.mutation &&
                (unresolvedMutationSequences.contains(event.sequence) ||
                    event.technicalSuccess ||
                    event.outcome == 'userConfirmed' ||
                    event.outcome == 'observed') &&
                (event.subtaskId == activeSubtaskId ||
                    event.subtaskId == null) &&
                event.action == action,
          ) ??
          false;
      if (call.mutation != ToolMutation.readOnly && unresolvedPriorAction) {
        previousResult =
            'Refused to repeat $action because a prior external effect remains '
            'unverified. '
            'Use a read-only observation or another independent strategy.';
        results.add('$action: not replayed; prior mutation needs review.');
        failedStrategies.add('$action: prior effect remains unverified');
        consecutiveFailures++;
        continue;
      }

      await _taskStore.beginAction(
        _activeTaskId!,
        action,
        mutation: call.mutation != ToolMutation.readOnly,
        subtaskId: activeSubtaskId,
      );
      _actionInFlight = true;
      bool toolSucceeded = false;
      bool toolThrew = false;
      bool toolNeedsReview = false;
      try {
        if (_paused || _cancelled || _budgetExpired) {
          // Clear the just-created checkpoint as not executed, then the loop's
          // stop handling will preserve the task. Never dispatch after a stop.
          previousResult = 'Action stopped before dispatch.';
          continue;
        }
        if (action == 'read_screen') {
          final accessibilityAvailable = await _screenService
              .isServiceRunning();

          if (!accessibilityAvailable) {
            previousResult =
                'ERROR: Accessibility service is not enabled. '
                'UI cannot be used.';

            consecutiveFailures++;

            results.add('read_screen ? $previousResult');

            continue;
          }

          try {
            screenContent = _aiService.useScreenCompression
                ? await _screenService.getCompressedScreenDescription(userGoal)
                : await _screenService.getScreenDescription();

            previousResult = 'Screen successfully read.';
            toolSucceeded =
                screenContent.isNotEmpty &&
                !ToolRegistry.isFailureResult(screenContent);

            results.add('read_screen ? Screen successfully read.');

            consecutiveFailures = 0;
          } catch (e) {
            previousResult = 'ERROR reading screen: $e';

            consecutiveFailures++;
          }

          continue;
        }

        // ----------------------------------------------------------------------
        // WEB SEARCH
        // ----------------------------------------------------------------------

        if (action == 'web_search') {
          final query = params['query'] as String? ?? '';

          if (query.trim().isEmpty) {
            previousResult = 'ERROR: web_search requires a query.';

            consecutiveFailures++;
            continue;
          }

          final searchResult = await _webSearchService.search(query.trim());

          previousResult = 'web_search "$query"\n$searchResult';

          if (searchResult.startsWith('Web search error:')) {
            consecutiveFailures++;
          } else if (searchResult.startsWith(
            'Web search returned no results',
          )) {
            consecutiveFailures++;
          } else {
            consecutiveFailures = 0;
            toolSucceeded = !ToolRegistry.isFailureResult(searchResult);
          }

          continue;
        }

        // -----------------------------------------------------------------------
        // WEB REQUEST
        // -----------------------------------------------------------------------

        if (action == 'web_request') {
          final method = params['method'] as String? ?? 'GET';

          final url = params['url'] as String? ?? '';

          final headers = params['headers'] is Map
              ? Map<String, dynamic>.from(params['headers'] as Map)
              : null;

          final body = params['body'];

          if (url.isEmpty) {
            previousResult = 'ERROR: web_request requires a URL.';

            consecutiveFailures++;

            results.add('web_request ? $previousResult');

            continue;
          }

          _report('?? $method $url');

          developer.log('WEB REQUEST: $method $url', name: 'PrivateAgent');

          final webResult = await _webService.request(
            method: method,
            url: url,
            headers: headers,
            body: body,
          );

          previousResult = webResult;

          results.add('web_request $method $url ?\n$webResult');

          final status = _extractHttpStatus(webResult);
          toolSucceeded = status != null && status >= 200 && status < 300;

          final failed =
              webResult.startsWith('Web request error:') ||
              (status != null && status >= 400);

          if (failed) {
            consecutiveFailures++;

            String domain = '';

            try {
              domain = Uri.parse(url).host;
            } catch (_) {
              domain = '';
            }

            String failureType = 'HTTP/request failure';

            final lowerResult = webResult.toLowerCase();

            if (lowerResult.contains('captcha') ||
                lowerResult.contains('robot') ||
                lowerResult.contains('bot detection') ||
                lowerResult.contains('access denied') ||
                lowerResult.contains('automated')) {
              failureType = 'CAPTCHA/anti-bot';
            } else if (status != null && status >= 400) {
              failureType = 'HTTP $status';
            }

            final strategy =
                'web_request'
                '${domain.isEmpty ? '' : ' $domain'}'
                ' [$failureType]';

            if (!failedStrategies.contains(strategy)) {
              failedStrategies.add(strategy);
            }

            previousResult =
                '$webResult\n\n'
                'STRATEGY FAILURE:\n'
                '$strategy\n'
                'Do NOT repeat this strategy for this domain. '
                'Choose another method.';

            _report('?? Web request failed: $strategy');

            developer.log(
              'WEB REQUEST FAILED: $strategy',
              name: 'PrivateAgent',
            );

            // IMPORTANT:
            //
            // Do NOT call RecoveryEngine here.
            //
            // This is a web strategy failure, not a UI failure.
            // The failure memory is passed to Kimi so it can
            // choose another strategy.
          } else {
            consecutiveFailures = 0;

            _report('?? Web response received.');
          }

          continue;
        }

        if (action == 'list_files' ||
            action == 'read_file' ||
            action == 'write_file' ||
            action == 'delete_file') {
          try {
            final path = params['path'] as String? ?? '';
            switch (action) {
              case 'list_files':
                final files = await _files.listFiles(recursive: true);
                previousResult = files.isEmpty
                    ? 'No files in agent_files.'
                    : files.join('\n');
                break;
              case 'read_file':
                final text = await _files.readText(path);
                previousResult = text.length > 12000
                    ? '${text.substring(0, 12000)}\n[File content truncated]'
                    : text;
                break;
              case 'write_file':
                await _files.writeText(
                  path,
                  params['content'] as String? ?? '',
                );
                previousResult = 'File written to agent_files: $path';
                break;
              case 'delete_file':
                await _files.delete(path);
                previousResult = 'File deleted from agent_files: $path';
                break;
            }
            results.add(
              action == 'read_file'
                  ? 'read_file: content returned to planner (not saved in task history).'
                  : '$action: $previousResult',
            );
            consecutiveFailures = 0;
            toolSucceeded = true;
          } catch (error) {
            toolThrew =
                call.mutation != ToolMutation.readOnly &&
                error is! FileServiceException;
            previousResult = '$action failed: $error';
            results.add(previousResult);
            consecutiveFailures++;
            failedStrategies.add('$action: $error');
          }
          continue;
        }

        // ----------------------------------------------------------------------
        // OPEN URL
        // ----------------------------------------------------------------------

        if (action == 'open_url') {
          final url = params['url'] as String? ?? '';

          if (url.isEmpty) {
            previousResult = 'ERROR: open_url requires a URL.';

            consecutiveFailures++;

            continue;
          }

          _report('?? Opening $url...');

          final openResult = await _appLauncher.openUrl(url);

          previousResult = openResult;
          toolSucceeded = openResult.startsWith('Opened');

          results.add('open_url $url ? $openResult');

          if (openResult.startsWith('Error') ||
              openResult.startsWith('Cannot')) {
            consecutiveFailures++;
          } else {
            consecutiveFailures = 0;

            // External browser/app changed the screen.
            screenContent = '';
          }

          continue;
        }

        // -----------------------------------------------------------------------
        // OPEN APP
        // -----------------------------------------------------------------------

        if (action == 'open_app') {
          final appName = params['app_name'] as String? ?? '';

          if (appName.isEmpty) {
            previousResult = 'ERROR: open_app requires app_name.';

            consecutiveFailures++;

            continue;
          }

          final accessibilityAvailable = await _screenService
              .isServiceRunning();

          if (_paused || _cancelled || _budgetExpired) continue;
          if (!accessibilityAvailable) {
            // Opening an app itself does not strictly require Accessibility.
            final openResult = await _appLauncher.openApp(appName);

            previousResult = openResult;
            toolSucceeded = openResult.startsWith('Opened');

            results.add('open_app $appName ? $openResult');

            if (openResult.startsWith('Opened')) {
              screenContent = '';
              consecutiveFailures = 0;
            } else {
              consecutiveFailures++;
            }

            continue;
          }

          _report('?? Opening $appName...');

          final openResult = await _appLauncher.openApp(appName);

          previousResult = openResult;
          toolSucceeded = openResult.startsWith('Opened');

          results.add('open_app $appName ? $openResult');

          if (openResult.startsWith('Opened')) {
            consecutiveFailures = 0;

            screenContent = '';

            executedSteps.add(ActionStep(action: action, params: params));
          } else {
            consecutiveFailures++;
          }

          continue;
        }

        // -----------------------------------------------------------------------
        // SHIZUKU
        // -----------------------------------------------------------------------

        if (action == 'run_adb_command') {
          final command = params['command'] as String? ?? '';

          if (command.isEmpty) {
            previousResult = 'ERROR: run_adb_command requires command.';

            consecutiveFailures++;

            continue;
          }

          _report('?? Running command...');

          try {
            final commandResult = await _shizukuService.runCommandWithStatus(
              command,
            );
            previousResult = commandResult.displayText;
            results.add('run_adb_command\n$previousResult');

            toolSucceeded = commandResult.succeeded;
            toolThrew = commandResult.uncertain;
            toolNeedsReview = commandResult.mayHavePartialEffects;
            if (commandResult.succeeded) {
              consecutiveFailures = 0;
            } else {
              consecutiveFailures++;
            }
          } catch (e) {
            previousResult = 'ERROR executing command: $e';
            toolThrew = true;
            toolNeedsReview = true;

            consecutiveFailures++;
          }

          continue;
        }

        // -----------------------------------------------------------------------
        // UI ACTIONS
        // -----------------------------------------------------------------------

        final isUiAction = {
          'click_text',
          'click_at',
          'type_text',
          'press_enter',
          'scroll',
          'swipe',
          'press_back',
          'press_home',
          'wait',
        }.contains(action);

        if (!isUiAction) {
          previousResult = 'ERROR: Unknown action "$action".';

          consecutiveFailures++;

          continue;
        }

        // -----------------------------------------------------------------------
        // WAIT does not require Accessibility
        // -----------------------------------------------------------------------

        if (action == 'wait') {
          final milliseconds =
              (params['milliseconds'] as num?)?.toInt() ?? 1000;

          await _remoteCancellation.delay(Duration(milliseconds: milliseconds));

          previousResult = 'Waited ${milliseconds}ms.';
          toolSucceeded = !_paused && !_cancelled && !_budgetExpired;

          results.add('wait ? ${milliseconds}ms');

          consecutiveFailures = 0;

          continue;
        }

        // -----------------------------------------------------------------------
        // UI requires Accessibility
        // -----------------------------------------------------------------------

        final accessibilityAvailable = await _screenService.isServiceRunning();

        if (_paused || _cancelled || _budgetExpired) continue;
        if (!accessibilityAvailable) {
          previousResult =
              'ERROR: Accessibility service is not enabled. '
              'Cannot execute UI action "$action".';

          consecutiveFailures++;

          results.add('$action ? $previousResult');

          continue;
        }

        // -----------------------------------------------------------------------
        // If screen has not been read, read it first.
        //
        // We intentionally do NOT execute the requested UI action blindly.
        // Kimi gets another planning cycle with actual screen data.
        // -----------------------------------------------------------------------

        if (screenContent.isEmpty) {
          previousResult =
              'UI action not executed: select read_screen first, '
              'then reconsider the action against the observed screen.';
          continue;
        }

        // -----------------------------------------------------------------------
        // Execute UI action
        // -----------------------------------------------------------------------

        bool success = false;
        String actionResult = '';

        switch (action) {
          case 'click_text':
            final text = params['text'] as String? ?? '';

            success = await _screenService.clickByText(text);

            actionResult = success
                ? 'Clicked "$text"'
                : 'Could not find "$text" to click';

            break;

          case 'click_at':
            final x = (params['x'] as num?)?.toDouble() ?? 0;

            final y = (params['y'] as num?)?.toDouble() ?? 0;

            success = await _screenService.clickAt(x, y);

            actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';

            break;

          case 'type_text':
            final text = params['text'] as String? ?? '';

            final hint = params['field_hint'] as String?;

            success = await _screenService.typeText(text, fieldHint: hint);

            actionResult = success ? 'Typed "$text"' : 'Could not type text';

            break;

          case 'press_enter':
            success = await _submitKeyboardAction();

            actionResult = success
                ? 'Submitted the focused search/form field'
                : 'Could not submit the focused field';

            break;

          case 'swipe':
            final startX = (params['startX'] as num?)?.toDouble() ?? 540;

            final startY = (params['startY'] as num?)?.toDouble() ?? 2000;

            final endX = (params['endX'] as num?)?.toDouble() ?? 540;

            final endY = (params['endY'] as num?)?.toDouble() ?? 500;

            success = await _performSwipe(startX, startY, endX, endY);

            actionResult = success
                ? 'Swiped from '
                      '($startX,$startY) to '
                      '($endX,$endY)'
                : 'Swipe failed';

            break;

          case 'scroll':
            final direction = params['direction'] as String? ?? 'down';

            success = await _performScroll(direction);

            actionResult = success
                ? 'Scrolled $direction'
                : 'Could not scroll $direction';

            break;

          case 'press_back':
            success = await _screenService.pressBack();

            actionResult = success ? 'Pressed back' : 'Could not press back';

            break;

          case 'press_home':
            success = await _screenService.pressHome();

            actionResult = success ? 'Pressed home' : 'Could not press home';

            break;
        }

        developer.log(
          '=== NATIVE EXECUTION RESULT ===\n'
          '$actionResult',
          name: 'PrivateAgent',
        );

        previousResult = actionResult;
        toolSucceeded = success;

        results.add(
          'Step ${step + 1}: '
          '$actionResult ($reasoning)',
        );

        // -----------------------------------------------------------------------
        // UI success
        // -----------------------------------------------------------------------

        if (success) {
          consecutiveFailures = 0;

          lastFailedAction = '';

          executedSteps.add(ActionStep(action: action, params: params));

          // Screen changed and current dump is now stale.
          screenContent = '';

          if (!isComplete && (step + 1) % 3 == 0) {
            await _screenService.showToast('Working... (Step ${step + 1})');
          }

          continue;
        }

        // -----------------------------------------------------------------------
        // UI failure ? RecoveryEngine
        // -----------------------------------------------------------------------

        if (action == lastFailedAction && consecutiveFailures > 0) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;

          lastFailedAction = action;
        }

        // Prevent infinite UI failure loops.
        if (consecutiveFailures >= 5) {
          results.add(
            'Agent is stuck after '
            '$consecutiveFailures consecutive failures.',
          );

          _report('Agent stuck � changing strategy.');

          // IMPORTANT:
          //
          // We don't immediately terminate.
          // We clear the screen state and allow Kimi to reconsider
          // the task with the failure result.
          screenContent = '';

          previousResult =
              'UI strategy failed repeatedly. '
              'Choose a completely different strategy.';

          consecutiveFailures = 3;

          continue;
        }

        // Recovery must be selected as the next normal checkpointed action.
        // Never run hidden press_back/scroll/shell side effects here.
        previousResult =
            '$actionResult. Re-observe and choose a recovery action.';
        screenContent = '';
        continue;
      } catch (error) {
        if (call.mutation == ToolMutation.readOnly) {
          previousResult =
              'ERROR: $action failed before returning a result: $error';
          results.add('$action: $previousResult');
          consecutiveFailures++;
        } else {
          toolThrew = true;
          toolNeedsReview = true;
          previousResult =
              '$action may have had partial effects. Do not repeat it; '
              'inspect the current state or continue with an independent strategy.';
          results.add('$action: outcome saved for review; trying alternatives.');
          failedStrategies.add('$action: outcome uncertain; do not replay');
          consecutiveFailures++;
        }
      } finally {
        // Dart runs finally on every continue and return in the dispatch.
        final needsIndependentReview =
            (toolThrew || toolNeedsReview) &&
            call.mutation != ToolMutation.readOnly;
        final classification = ToolRegistry.classifyResult(
          succeeded:
              toolSucceeded && !ToolRegistry.isFailureResult(previousResult),
          threw: toolThrew,
        );
        try {
          await _taskStore.endAction(
            _activeTaskId!,
            technicalSuccess:
                classification == ToolResultClassification.succeeded,
            uncertain: toolThrew || toolNeedsReview,
            // Preserve the uncertain checkpoint but let independent subtasks
            // continue. Their dependencies remain blocked in durable state.
            continueAfterUncertain: true,
          );
        } finally {
          _actionInFlight = false;
        }
        if (needsIndependentReview) {
          const reviewMessage =
              'This action may have changed external state. It will not be '
              'replayed; its subtask and dependents need review. Independent '
              'work may continue.';
          results.add(reviewMessage);
          _report(reviewMessage);
        }
        if (toolSucceeded) {
          consecutiveVerifierGaps = 0;
          _assistanceBatchShown = false;
        }
      }
    }

    // =========================================================================
    // MAX STEPS
    // =========================================================================
    if (_paused)
      return await _handlePause(
        userGoal,
        totalTokens,
        stepBase + _aiService.maxSteps,
        results,
        failedStrategies,
      );
    if (_cancelled)
      return await _handleCancellation(
        userGoal,
        totalTokens,
        stepBase + _aiService.maxSteps,
        results,
      );
    if (_budgetExpired || totalTokens >= maxTaskTokens) {
      return await _stopForBudget(
        totalTokens,
        stepBase + _aiService.maxSteps,
        results,
        failedStrategies,
      );
    }

    final outcome = await _subtaskOutcomeReport();
    results.add(
      'Reached the current planner window limit of ${_aiService.maxSteps} '
      'steps. Continuing from the saved checkpoint.\n$outcome',
    );

    _report('Planner window complete. Continuing automatically.\n$outcome');

    await _finishTask(
      TaskStatus.needsRevision,
      stepBase + _aiService.maxSteps,
      totalTokens,
      results,
      failedStrategies,
    );

    return outcome;
  }

  // ===========================================================================
  // CANCELLATION
  // ===========================================================================

  Future<String> _handleCancellation(
    String userGoal,
    int totalTokens,
    int step,
    List<String> results,
  ) async {
    results.add('Task cancelled by user.');

    _report('Task cancelled. Its checkpoint remains available in this chat.');

    await _notificationService.showTaskCompleteNotification(
      'Task Cancelled',
      'Task was stopped by the user.',
    );

    await _finishTask(
      TaskStatus.cancelled,
      step,
      totalTokens,
      results,
      const [],
    );

    if (await _screenService.isServiceRunning()) {
      await _screenService.showToast('Task Cancelled');
    }

    return 'Task cancelled. Its checkpoint remains available in this chat.';
  }

  Future<String> _handlePause(
    String userGoal,
    int totalTokens,
    int step,
    List<String> results,
    List<String> failedStrategies,
  ) async {
    results.add('Task paused by user.');
    _report('Task paused. You can resume it from this chat.');
    await _finishTask(
      TaskStatus.paused,
      step,
      totalTokens,
      results,
      failedStrategies,
    );
    return 'Task paused. You can resume it from this chat.';
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  void _report(String message) {
    onProgress?.call(PrivacySanitizer.sanitizeTaskTrace(message));
  }

  int _remainingOutputTokens(int used) {
    final remaining = maxTaskTokens - used;
    return remaining < _aiService.maxTokens ? remaining : _aiService.maxTokens;
  }

  Duration _retryDelay(int attempt) {
    final exponent = (attempt - 1).clamp(0, 5).toInt();
    final seconds = (1 << exponent).clamp(1, 30).toInt();
    return Duration(seconds: seconds);
  }

  Future<void> _waitForRetry(int attempt) async {
    final cancellation = _cancelCompleter ??= Completer<void>();
    await Future.any<void>([
      Future<void>.delayed(_retryDelay(attempt)),
      cancellation.future,
    ]);
    if (identical(_cancelCompleter, cancellation)) {
      _cancelCompleter = null;
    }
  }

  Future<String> _stopForBudget(
    int tokens,
    int step,
    List<String> results,
    List<String> failedStrategies,
  ) async {
    _blockedByResourceLimit = true;
    _remoteCancellation.cancel();
    const message =
        'The configured task budget was reached before completion. The '
        'checkpoint is saved and no action was replayed.';
    results.add(message);
    _report(message);
    await _finishTask(
      TaskStatus.needsRevision,
      step,
      tokens,
      results,
      failedStrategies,
    );
    return message;
  }

  Future<ToolPolicyDecision> _authorizeTool(ValidatedToolCall call) async {
    if (_remoteCancellation.isCancelled) {
      return const ToolPolicyDecision(false, 'Task stopped.');
    }
    final stopped = Completer<ToolPolicyDecision>();
    final remove = _remoteCancellation.onCancel(() {
      if (!stopped.isCompleted) {
        stopped.complete(const ToolPolicyDecision(false, 'Task stopped.'));
      }
    });
    try {
      return await Future.any([
        const ToolPolicy().authorize(call, onApproval: onApproval),
        stopped.future,
      ]);
    } finally {
      remove();
    }
  }

  Future<Set<String>?> _requestUserAnswer(
    List<TaskAssistanceItem> items,
  ) async {
    final callback = onUserQuestion;
    if (callback == null) return null;
    final stopped = Completer<Set<String>?>();
    final remove = _remoteCancellation.onCancel(() {
      if (!stopped.isCompleted) stopped.complete(null);
    });
    try {
      final response = Future<Set<String>?>.sync(
        () => callback(items),
      ).timeout(UserAssistancePolicy.timeLimit, onTimeout: () => null);
      return await Future.any([response, stopped.future]);
    } catch (_) {
      return null;
    } finally {
      remove();
    }
  }

  Future<String> _verifiedCompletionEvidenceSummary() async {
    final id = _activeTaskId;
    if (id == null) throw StateError('No active task to verify');
    final record = await _taskStore.get(id);
    if (record == null || TaskVerifier.verify(record.execution) != 'verified') {
      throw StateError('Saved task evidence is no longer verified');
    }

    final observationIds = <String>{};
    for (final subtask in record.execution.plan) {
      for (final refs in subtask.evidenceRefs.values) {
        observationIds.addAll(refs);
      }
    }
    final observations = record.execution.audit.where(
      (event) =>
          observationIds.contains(event.evidenceId) &&
          event.phase == 'after' &&
          event.technicalSuccess &&
          event.revision == record.execution.revision &&
          !event.mutation &&
          TaskVerifier.isObservationAction(event.action),
    );
    final actions = observations.map((event) => event.action).toSet().toList()
      ..sort();
    final observationCount = observations.length;
    final observationWord =
        observationCount == 1 ? 'observation' : 'observations';
    final verifiedMutationCount = record.execution.audit
        .where(
          (event) =>
              event.mutation &&
              event.phase == 'after' &&
              event.technicalSuccess &&
              event.revision == record.execution.revision &&
              const {'userConfirmed', 'observed'}.contains(event.outcome),
        )
        .map((event) => event.sequence)
        .toSet()
        .length;
    final criteriaCount = record.execution.plan.fold<int>(
      0,
      (count, subtask) => count + subtask.criteria.length,
    );
    final sourceText = actions.isEmpty ? '' : ' (${actions.join(', ')})';
    final mutationText = verifiedMutationCount == 0
        ? ''
        : '; $verifiedMutationCount external mutation outcome(s) verified';
    return 'Evidence check: $criteriaCount criteria across '
        '${record.execution.plan.length} subtasks, supported by '
        '$observationCount successful read-only $observationWord$sourceText'
        '$mutationText.';
  }

  List<String> _completionEvidenceGaps(TaskExecutionState state) {
    if (state.plan.isEmpty) {
      return const ['The task has no saved completion plan.'];
    }
    final evidence = {
      for (final event in state.audit)
        if (event.phase == 'after' &&
            event.technicalSuccess &&
            event.revision == state.revision)
          event.evidenceId: event,
    };
    final gaps = <String>[];
    if (state.inFlight != null) {
      gaps.add('An action is still in flight; its outcome is not verified.');
    }
    if (state.unverifiedMutations.isNotEmpty) {
      gaps.add(
        'An external change is still unverified. Use a trusted outcome check '
        'or independent review; never replay the change.',
      );
    }
    if (state.pendingAssistance.isNotEmpty) {
      gaps.add('A verified user-only step is still pending.');
    }
    final completed = <String>{};
    for (final subtask in state.plan) {
      if (!completed.containsAll(subtask.dependencies)) {
        gaps.add('${subtask.objective}: a dependency is not verified.');
        continue;
      }
      if (const {
            TaskSubtaskStatus.failed,
            TaskSubtaskStatus.blocked,
            TaskSubtaskStatus.needsReview,
          }.contains(subtask.status) ||
          subtask.criteria.isEmpty) {
        gaps.add('${subtask.objective}: the subtask is incomplete.');
        continue;
      }
      var valid = true;
      for (final criterion in subtask.criteria) {
        if (!TaskVerifier.hasValidCriterionEvidence(
          subtask,
          criterion,
          evidence,
        )) {
          gaps.add(
            '${subtask.objective}: $criterion needs a successful '
            'same-subtask read-only observation.',
          );
          valid = false;
        }
      }
      if (valid) completed.add(subtask.id);
    }
    if (gaps.isEmpty && TaskVerifier.verify(state) != 'verified') {
      gaps.add('The saved task state does not satisfy the completion checks.');
    }
    return gaps;
  }

  List<TaskAssistanceItem> _assistanceItems(TaskExecutionState state) {
    return <TaskAssistanceItem>[
      for (final request in state.pendingAssistance)
        TaskAssistanceItem(
          id: request.id,
          kind: TaskAssistanceKind.humanStep,
          title: request.question,
          details: 'Observed blocker: ${request.evidence}',
        ),
    ];
  }

  Future<String> _subtaskOutcomeReport() async {
    final id = _activeTaskId;
    if (id == null) return 'Task stopped with no active checkpoint.';
    final record = await _taskStore.get(id);
    if (record == null || record.execution.plan.isEmpty) {
      return 'Task is incomplete. No validated subtask plan is available; '
          'resume from the saved checkpoint when the planner is available.';
    }
    final lines = <String>[];
    for (final subtask in record.execution.plan) {
      final objective = TaskPersistencePrivacy.goalText(subtask.objective);
      final shortObjective = objective.length > 220
          ? '${objective.substring(0, 220)}…'
          : objective;
      final status = switch (subtask.status) {
        TaskSubtaskStatus.completed => 'completed',
        TaskSubtaskStatus.failed => 'failed after safe strategies were exhausted',
        TaskSubtaskStatus.blocked => 'blocked by an incomplete dependency',
        TaskSubtaskStatus.needsReview =>
          'waiting for independent review of its external outcome',
        TaskSubtaskStatus.inProgress => subtask.failureCode == 'tool_failed'
            ? 'incomplete; the latest tool attempt failed'
            : 'incomplete; more work may remain',
        TaskSubtaskStatus.pending => 'not started; available to resume',
      };
      final attempts = subtask.attempts == 1
          ? '1 tool attempt'
          : '${subtask.attempts} tool attempts';
      lines.add('- ${subtask.id}: $shortObjective — $status ($attempts).');
    }
    final completed = record.execution.plan
        .where((item) => item.status == TaskSubtaskStatus.completed)
        .length;
    final unresolvedMutationCount =
        record.execution.unverifiedMutations.length;
    final mutationNote = unresolvedMutationCount == 0
        ? ''
        : '\nUnverified external changes: $unresolvedMutationCount. '
              'They were not replayed. Independently review them in Task History '
              'before resuming dependent work.';
    return 'Task outcome: $completed/${record.execution.plan.length} '
        'subtasks verified.\n${lines.join('\n')}$mutationNote';
  }

  Future<void> _showTaskNotification(String title, String body) async {
    try {
      await _notificationService.showTaskCompleteNotification(title, body);
    } catch (error, stackTrace) {
      developer.log(
        'Task notification could not be shown',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _notifyTaskCheckpoint(TaskStatus status) async {
    switch (status) {
      case TaskStatus.needsRevision:
        await _showTaskNotification(
          'Task Checkpoint Saved',
          'The task needs review before further actions. Its checkpoint is saved.',
        );
        return;
      case TaskStatus.paused:
        await _showTaskNotification(
          'Task Paused',
          'The task is paused. Its checkpoint is available to resume.',
        );
        return;
      case TaskStatus.failed:
        await _showTaskNotification(
          'Task Error',
          'The task could not complete. Its checkpoint is available to review.',
        );
        return;
      case TaskStatus.cancelled:
        await _showTaskNotification(
          'Task Cancelled',
          'The task was stopped. Its checkpoint remains available.',
        );
        return;
      case TaskStatus.running:
      case TaskStatus.completed:
        return;
    }
  }

  Future<void> _writeTaskHistory(
    TaskRecord? record,
    TaskStatus status,
    int steps,
    int tokens,
    List<String> results,
  ) async {
    final historyStatus = switch (status) {
      TaskStatus.completed => 'Success',
      TaskStatus.failed => 'Failed',
      TaskStatus.cancelled => 'Cancelled',
      _ => null,
    };
    if (record == null || historyStatus == null) return;
    try {
      await TaskHistoryLogger.logTask(
        record.originalGoal,
        historyStatus,
        tokens,
        steps,
        results,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Task history could not be recorded',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _finishTask(
    TaskStatus status,
    int steps,
    int tokens,
    List<String> results,
    List<String> failedStrategies,
  ) async {
    final id = _activeTaskId;
    if (id == null) return;
    final record = await _taskStore.get(id);
    if (record?.execution.inFlight?.mutation == true) {
      status = TaskStatus.needsRevision;
    }
    await _taskStore.update(
      id,
      status: status,
      progress: status == TaskStatus.completed ? 1 : null,
      stepsCompleted: steps,
      tokens: tokens,
      results: results.length <= 20
          ? results
          : results.sublist(results.length - 20),
      failedStrategies: failedStrategies.isEmpty
          ? record?.failedStrategies
          : failedStrategies,
    );
    await _writeTaskHistory(record, status, steps, tokens, results);
    lastStatus = status;
    _activeTaskId = null;
  }

  Future<void> failUnexpected(Object error) async {
    final id = _activeTaskId;
    if (id == null) return;
    final record = await _taskStore.get(id);
    var status = TaskStatus.needsRevision;
    final pending = record?.execution.inFlight;
    if (pending != null) {
      final uncertainMutation = pending.mutation;
      await _taskStore.endAction(
        id,
        technicalSuccess: false,
        uncertain: uncertainMutation,
        continueAfterUncertain: true,
      );
    } else if (record?.execution.unverifiedMutations.isNotEmpty == true) {
      status = TaskStatus.needsRevision;
    }
    await _taskStore.update(id, status: status);
    lastStatus = status;
    _activeTaskId = null;
  }

  int? _extractHttpStatus(String result) {
    final match = RegExp(r'^HTTP\s+(\d+)').firstMatch(result);

    if (match == null) {
      return null;
    }

    return int.tryParse(match.group(1)!);
  }

  // ===========================================================================
  // KEYBOARD
  // ===========================================================================

  Future<bool> _submitKeyboardAction() async {
    if (_paused || _cancelled || _budgetExpired) return false;
    // Never silently escalate an approved UI operation to privileged shell.
    return _screenService.pressEnter();
  }

  // ===========================================================================
  // SCROLL
  // ===========================================================================

  Future<bool> _performScroll(String direction) async {
    if (_paused || _cancelled || _budgetExpired) return false;
    return _screenService.scroll(direction);
  }

  // ===========================================================================
  // SWIPE
  // ===========================================================================

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (_paused || _cancelled || _budgetExpired) return false;
    return _screenService.swipe(startX, startY, endX, endY);
  }
}
