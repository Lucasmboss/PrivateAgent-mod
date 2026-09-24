import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'ai_service.dart';
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
import '../privacy_sanitizer.dart';
import 'task_store.dart';
import '../models/task_record.dart';
import '../models/saved_skill.dart';

typedef TaskUserQuestionCallback = Future<String?> Function(String question);

/// Executes autonomous multi-step tasks using multiple strategies.
///
/// Strategy priority:
/// 1. Direct HTTP/API
/// 2. Android app/API access
/// 3. Shizuku / shell
/// 4. Screen automation fallback
///
/// The LLM decides which strategy is appropriate for each step.
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

  final WebSearchService _webSearchService = WebSearchService();

  /// Callback to report progress messages to the UI.
  final void Function(String message)? onProgress;
  final ToolApprovalCallback? onApproval;
  final TaskUserQuestionCallback? onUserQuestion;
  final int maxTaskTokens;
  final Duration maxTaskDuration;
  RemoteCancellationToken _remoteCancellation = RemoteCancellationToken();
  Timer? _budgetTimer;
  bool _budgetExpired = false;

  /// Set to true to cancel the running task.
  bool _cancelled = false;
  bool _paused = false;
  bool _actionInFlight = false;

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

Ask the user for a reply when the task is blocked by sign-in or a meaningful
preference/choice that cannot be safely inferred.

Parameters:
{
  "question": "A short, specific question"
}

Never ask for passwords, tokens, verification codes, or other credentials.
The user's reply is information, not approval for a sensitive action.
If there is no reply within 90 seconds, choose a safe default or alternative.
Never bypass sign-in, safety checks, or per-action approvals.

17. done

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
  "reasoning": "Brief reason for choosing this action.",
  "is_complete": false
}

GENERAL RULES:

- Before starting tools, you may use action "plan" with params.subtasks: an
  ordered array of {id, objective, dependencies: [earlier IDs], criteria: [text]}.
  Changing a plan invalidates prior evidence. Do not re-plan merely to finish.
- Completion requires action "done" and params.evidence:
  {subtaskId: {criterionText: ["action-N"]}} using persisted successful evidence.
  A bare done/is_complete is not proof. Mutations require trusted outcome review.

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
- Use ask_user only when a required preference or user-only step blocks safe
  progress. After a reply, continue the task; do not treat the reply as consent
  for sensitive actions. If the user does not reply, use a safe alternative or
  report the blocker. Never request credentials in chat.
- Do not claim success unless the user's requested objective was actually achieved.
- Keep reasoning very brief.
''';

  // ===========================================================================
  // JSON EXTRACTION
  // ===========================================================================

  String _extractJson(String text) {
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');

    final match = codeBlockRegex.firstMatch(text);

    if (match != null) {
      return match.group(1)!;
    }

    final startIndex = text.indexOf('{');

    final endIndex = text.lastIndexOf('}');

    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }

    return text.trim();
  }

  // ===========================================================================
  // EXECUTE TASK
  // ===========================================================================

  Future<String> executeTask(String userGoal, {String? resumeTaskId}) async {
    if (_activeTaskId != null) throw StateError('Executor already running');
    try {
      return await _executeTask(userGoal, resumeTaskId: resumeTaskId);
    } catch (error) {
      await failUnexpected(error);
      rethrow;
    } finally {
      _cancelCompleter = null;
      _budgetTimer?.cancel();
    }
  }

  Future<String> _executeTask(String userGoal, {String? resumeTaskId}) async {
    _cancelled = false;
    _paused = false;
    _budgetExpired = false;
    _remoteCancellation = RemoteCancellationToken();
    _cancelCompleter = null;
    lastStatus = null;
    await ScreenAutomationService.logToNative(
      '[TaskExecutor] executeTask() started',
    );
    final previousTask = resumeTaskId == null
        ? null
        : await _taskStore.get(resumeTaskId);
    final task = previousTask == null
        ? resumeTaskId == null
              ? await _taskStore.create(goal: userGoal)
              : throw StateError('Task not found')
        : await _taskStore.claim(resumeTaskId!, userGoal);
    _activeTaskId = task.identifier;
    // Wall-clock lifetime is cumulative across resumes, including time paused.
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
        'Resuming task. Previous results: ${previousTask.results}',
        'Previously failed strategies: ${previousTask.failedStrategies.join(', ')}',
      ]);
    }

    _report('Starting task: $userGoal');

    // Every operation goes through the checkpointed planner and policy gate.
    String lastAction = '';

    int sameActionCount = 0;

    int consecutiveFailures = 0;
    int userQuestionsAsked = 0;
    bool userQuestionTimedOut = false;

    String lastFailedAction = '';

    final List<String> failedStrategies = List<String>.from(
      previousTask?.failedStrategies ?? const [],
    );

    int totalTokens = previousTask?.tokens ?? 0;

    final List<ActionStep> executedSteps = [];

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

    for (int step = 0; step < _aiService.maxSteps; step++) {
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
        progress: (previousTask?.progress ?? 0) > step / _aiService.maxSteps
            ? previousTask!.progress
            : step / _aiService.maxSteps,
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
${step + 1}/${_aiService.maxSteps}

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

        totalTokens += aiResponse.totalTokens;
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

        results.add('AI error: $e');

        _report('Error: $e');

        await _notificationService.showTaskCompleteNotification(
          'Task Error',
          'AI encountered an error.',
        );

        await TaskHistoryLogger.logTask(
          userGoal,
          'Failed',
          totalTokens,
          step,
          results,
        );
        await _finishTask(
          TaskStatus.failed,
          step,
          totalTokens,
          results,
          failedStrategies,
        );

        return 'I could not complete the task because the AI service failed.';
      }

      // -----------------------------------------------------------------------
      // Parse action
      // -----------------------------------------------------------------------

      Map<String, dynamic>? actionJson;
      if (_budgetExpired || totalTokens >= maxTaskTokens) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }

      try {
        final jsonStr = _extractJson(response);

        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
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

          final jsonStr = _extractJson(retryResponse.content);

          actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
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
          results.add('Step ${step + 1}: Error after retry: $e');

          _report('AI formatting error.');

          await _notificationService.showTaskCompleteNotification(
            'Task Error',
            'AI formatting error.',
          );

          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _finishTask(
            TaskStatus.failed,
            step,
            totalTokens,
            results,
            failedStrategies,
          );

          return 'I could not understand the AI response. Please try again.';
        }
      }

      // ----------------------------------------------------------------------
      // NORMALIZE TOOL CALL
      // ----------------------------------------------------------------------

      String action = '';

      Map<String, dynamic> params = {};

      // Preferred format:
      // {
      //   "action": "web_request",
      //   "params": {...}
      // }
      final rawAction = actionJson['action'];

      final rawParams = actionJson['params'];

      if (rawAction is String && rawAction.trim().isNotEmpty) {
        action = rawAction.trim();

        if (rawParams is Map) {
          params = Map<String, dynamic>.from(rawParams);
        }
      }

      // Alternative tool-call format:
      // {
      //   "tool": "web_request",
      //   "url": "...",
      //   "method": "GET",
      //   "headers": {...}
      // }
      if (action.isEmpty) {
        final rawTool = actionJson['tool'];

        if (rawTool is String && rawTool.trim().isNotEmpty) {
          action = rawTool.trim();

          final toolParams = <String, dynamic>{};

          for (final entry in actionJson.entries) {
            if (const [
              'tool',
              'reasoning',
              'is_complete',
            ].contains(entry.key)) {
              continue;
            }

            toolParams[entry.key] = entry.value;
          }

          params = toolParams;
        }
      }

      // Missing actions are invalid, never implicit completion.

      final reasoning = actionJson['reasoning'] as String? ?? '';

      final isComplete = actionJson['is_complete'] == true;
      developer.log('Selected action: $action', name: 'PrivateAgent');

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
      if (_budgetExpired || totalTokens >= maxTaskTokens) {
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
      if (const ToolPolicy().requiresApproval(call)) {
        _report('Waiting for approval: $action');
      }
      final decision = await _authorizeTool(call);
      // Approval may take arbitrarily long; no checkpoint or side effect before
      // checking every stop condition again.
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
      if (_budgetExpired || totalTokens >= maxTaskTokens) {
        return await _stopForBudget(
          totalTokens,
          step,
          results,
          failedStrategies,
        );
      }
      if (!decision.allowed) {
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
        final verified = await _taskStore.verifyCompletion(
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
        if (verified.execution.verification != 'verified') {
          const message =
              'Task stopped with partial or unverified results. '
              'Completion criteria lack verified evidence; successful tool execution '
              'does not confirm the requested outcome.';
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
        final finalText = reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();

        results.add('Task complete: $finalText');

        _report('Task complete: $finalText');

        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          finalText,
        );

        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          totalTokens,
          step,
          results,
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
        final rawPlan = params['subtasks'];
        if (rawPlan is! List) throw const FormatException('Missing subtasks');
        await _taskStore.setPlan(
          _activeTaskId!,
          rawPlan
              .map((s) => TaskSubtask.fromJson(Map<String, dynamic>.from(s)))
              .toList(),
        );
        previousResult =
            'Structured plan saved; prior criterion evidence invalidated.';
        continue;
      }

      if (action == 'ask_user') {
        if (userQuestionTimedOut || userQuestionsAsked >= 3) {
          previousResult =
              'No further user questions are available. Choose a '
              'safe default or alternative, or explain the remaining blocker.';
          continue;
        }
        userQuestionsAsked++;
        final question = params['question'] as String;
        _report('Waiting for your reply (up to 90 seconds).');
        final reply = await _requestUserAnswer(question);
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
        if (_budgetExpired || totalTokens >= maxTaskTokens) {
          return await _stopForBudget(
            totalTokens,
            step,
            results,
            failedStrategies,
          );
        }
        if (reply == null || reply.trim().isEmpty) {
          userQuestionTimedOut = true;
          previousResult =
              'No reply was provided; the user chose the safe fallback, the '
              'wait expired, or replies are unavailable here. Choose a safe '
              'default or unauthenticated alternative if possible. Never bypass '
              'sign-in, safety checks, or per-action approval. If blocked, explain why.';
        } else {
          previousResult =
              'The user replied: ${jsonEncode(reply.trim())}. '
              'This is information or a preference, not approval for a sensitive action.';
        }
        // Deliberately do not checkpoint or persist the user's free-text answer.
        continue;
      }

      await _taskStore.beginAction(
        _activeTaskId!,
        action,
        mutation: call.mutation != ToolMutation.readOnly,
      );
      _actionInFlight = true;
      bool toolSucceeded = false;
      bool toolThrew = false;
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
            toolThrew = call.mutation != ToolMutation.readOnly;
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
            final commandResult = await _shizukuService.runCommand(command);

            previousResult = commandResult;

            results.add('run_adb_command $command ?\n$commandResult');

            final normalized = commandResult.toLowerCase();

            final failed =
                normalized.contains('not running') ||
                normalized.contains('permission denied') ||
                normalized.startsWith('error');
            // Shell strings do not provide a trustworthy exit status.
            toolSucceeded = false;
            toolThrew =
                true; // Preserve uncertain mutation for explicit review.

            if (failed) {
              consecutiveFailures++;
            } else {
              consecutiveFailures = 0;
            }
          } catch (e) {
            previousResult = 'ERROR executing command: $e';
            toolThrew = true;

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
      } catch (_) {
        toolThrew = true;
        rethrow;
      } finally {
        // Dart runs finally on every continue and return in the dispatch.
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
            uncertain: toolThrew,
          );
        } finally {
          _actionInFlight = false;
        }
        if (toolThrew) {
          throw StateError(
            'Tool outcome is uncertain; review required before continuing',
          );
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
        _aiService.maxSteps,
        results,
        failedStrategies,
      );
    if (_cancelled)
      return await _handleCancellation(
        userGoal,
        totalTokens,
        _aiService.maxSteps,
        results,
      );
    if (_budgetExpired || totalTokens >= maxTaskTokens) {
      return await _stopForBudget(
        totalTokens,
        _aiService.maxSteps,
        results,
        failedStrategies,
      );
    }

    results.add(
      'Reached maximum steps '
      '(${_aiService.maxSteps}). '
      'Task may be incomplete.',
    );

    _report('Reached maximum steps.');

    await _notificationService.showTaskCompleteNotification(
      'Task Stopped',
      'Reached maximum steps '
          '(${_aiService.maxSteps}).',
    );

    await TaskHistoryLogger.logTask(
      userGoal,
      'Failed',
      totalTokens,
      _aiService.maxSteps,
      results,
    );
    await _finishTask(
      TaskStatus.needsRevision,
      _aiService.maxSteps,
      totalTokens,
      results,
      failedStrategies,
    );

    if (await _screenService.isServiceRunning()) {
      await _screenService.showToast('Reached maximum steps.');
    }

    return 'I could not complete the task within the allowed steps.';
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

    _report('Task cancelled.');

    await _notificationService.showTaskCompleteNotification(
      'Task Cancelled',
      'Task was stopped by the user.',
    );

    await TaskHistoryLogger.logTask(
      userGoal,
      'Cancelled',
      totalTokens,
      step,
      results,
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

    return 'Task cancelled.';
  }

  Future<String> _handlePause(
    String userGoal,
    int totalTokens,
    int step,
    List<String> results,
    List<String> failedStrategies,
  ) async {
    results.add('Task paused by user.');
    _report('Task paused. You can resume it from Task History.');
    await _finishTask(
      TaskStatus.paused,
      step,
      totalTokens,
      results,
      failedStrategies,
    );
    return 'Task paused. You can resume it from Task History.';
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

  Future<String> _stopForBudget(
    int tokens,
    int step,
    List<String> results,
    List<String> failedStrategies,
  ) async {
    _remoteCancellation.cancel();
    const message =
        'Task budget exhausted. Results preserved; revision required.';
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

  Future<String?> _requestUserAnswer(String question) async {
    final callback = onUserQuestion;
    if (callback == null) return null;
    final stopped = Completer<String?>();
    final remove = _remoteCancellation.onCancel(() {
      if (!stopped.isCompleted) stopped.complete(null);
    });
    try {
      final response = Future<String?>.sync(
        () => callback(question),
      ).timeout(const Duration(seconds: 90), onTimeout: () => null);
      return await Future.any([response, stopped.future]);
    } catch (_) {
      return null;
    } finally {
      remove();
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
      tokens: tokens,
      results: results.length <= 20
          ? results
          : results.sublist(results.length - 20),
      failedStrategies: failedStrategies.isEmpty
          ? record?.failedStrategies
          : failedStrategies,
    );
    lastStatus = status;
    _activeTaskId = null;
  }

  Future<void> failUnexpected(Object error) async {
    final id = _activeTaskId;
    if (id == null) return;
    final record = await _taskStore.get(id);
    final status = record?.execution.inFlight?.mutation == true
        ? TaskStatus.needsRevision
        : TaskStatus.failed;
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
