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
import 'recovery_engine.dart';
import 'web_service.dart';
import '../models/saved_skill.dart';

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

  final NotificationService _notificationService =
      NotificationService();

  final SkillMemoryService _skillMemory =
      SkillMemoryService();

  final RecoveryEngine _recoveryEngine =
      RecoveryEngine();

  /// Direct Internet / HTTP access.
  ///
  /// Kept internal for this first architectural iteration so we do not
  /// need to modify ActionHandler yet.
  final WebService _webService = WebService();

  /// Callback to report progress messages to the UI.
  final void Function(String message)? onProgress;

  /// Set to true to cancel the running task.
  bool _cancelled = false;

  Completer<void>? _cancelCompleter;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
  })  : _aiService = aiService,
        _screenService = screenService,
        _appLauncher = appLauncher,
        _shizukuService = shizukuService;

  // ===========================================================================
  // CANCEL
  // ===========================================================================

  void cancel() {
    _cancelled = true;

    if (_cancelCompleter != null &&
        !_cancelCompleter!.isCompleted) {
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

1. Direct HTTP/API/web access
2. Android app/API access
3. Shizuku / shell commands
4. Screen automation as fallback

IMPORTANT:
- Do NOT open Chrome merely because the task involves the Internet.
- If information can be retrieved directly with HTTP, prefer web_request.
- Use open_url only when opening an actual webpage externally is useful.
- Use Android UI only when direct/API methods are insufficient.
- If one strategy fails, analyze the result and consider another strategy.
- Do not blindly repeat failed actions.
- The current Android screen may NOT have been read yet.
- If UI interaction is required and the screen has not been read,
  use read_screen first.
- You can combine web actions, Android actions and UI actions in one task.

AVAILABLE ACTIONS:

1. web_request

Direct HTTP/API request.

Parameters:
{
  "method": "GET|POST|PUT|PATCH|DELETE",
  "url": "https://...",
  "headers": {},
  "body": {}
}

Use this whenever direct web/API access is appropriate.

2. open_url

Open a URL externally.

Parameters:
{
  "url": "https://..."
}

3. open_app

Open an Android application.

Parameters:
{
  "app_name": "Chrome"
}

4. run_adb_command

Execute an Android shell command through the available Shizuku mechanism.

Parameters:
{
  "command": "..."
}

5. read_screen

Read the current Android accessibility screen.

Parameters:
{}

6. click_text

Click a visible UI element by text.

Parameters:
{
  "text": "exact visible text"
}

7. click_at

Click screen coordinates.

Parameters:
{
  "x": 540,
  "y": 960
}

8. type_text

Type text into the currently focused field.

Parameters:
{
  "text": "hello",
  "field_hint": "optional"
}

9. press_enter

Press the Enter/Search key.

Parameters:
{}

10. scroll

Scroll the current UI.

Parameters:
{
  "direction": "up|down"
}

11. swipe

Perform a swipe.

Parameters:
{
  "startX": 540,
  "startY": 2000,
  "endX": 540,
  "endY": 500
}

12. press_back

Press Android Back.

Parameters:
{}

13. press_home

Press Android Home.

Parameters:
{}

14. wait

Wait for an application or webpage to load.

Parameters:
{
  "milliseconds": 1000
}

15. done

Finish the task.

Parameters:
{}

RESPONSE FORMAT:

Return ONLY valid JSON.

{
  "action": "web_request",
  "params": {},
  "reasoning": "Brief reason for choosing this action.",
  "is_complete": false
}

GENERAL RULES:

- Choose exactly ONE action at a time.
- Never invent tool results.
- Base decisions on actual previous results.
- If web_request returns HTTP 4xx, HTTP 5xx, CAPTCHA,
  bot protection or unusable content, do not blindly repeat it.
  Consider another strategy.
- HTTP failure is a strategy failure, NOT a UI failure.
- If a webpage requires JavaScript or interaction that HTTP cannot provide,
  consider open_url followed by Screen Automation.
- If a task can be completed entirely using web_request, do not use UI.
- If a task can be completed entirely using Android APIs or shell,
  do not use UI.
- If UI is required, use read_screen before interacting with unknown UI.
- Do not claim success unless the user's requested objective was actually achieved.
- Keep reasoning very brief.
''';

  // ===========================================================================
  // JSON EXTRACTION
  // ===========================================================================

  String _extractJson(String text) {
    final codeBlockRegex =
        RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');

    final match =
        codeBlockRegex.firstMatch(text);

    if (match != null) {
      return match.group(1)!;
    }

    final startIndex =
        text.indexOf('{');

    final endIndex =
        text.lastIndexOf('}');

    if (startIndex != -1 &&
        endIndex != -1 &&
        endIndex > startIndex) {
      return text.substring(
        startIndex,
        endIndex + 1,
      );
    }

    return text.trim();
  }

  // ===========================================================================
  // EXECUTE TASK
  // ===========================================================================

  Future<String> executeTask(String userGoal) async {
    await ScreenAutomationService.logToNative(
      '[TaskExecutor] executeTask() CALLED with goal: $userGoal',
    );

    _cancelled = false;
    _cancelCompleter = null;

    final results = <String>[];

    results.add(
      'Starting task: $userGoal',
    );

    _report(
      'Starting task: $userGoal',
    );

    // -------------------------------------------------------------------------
    // Skill memory
    //
    // Important change:
    // Accessibility is checked only if we actually have a UI skill to replay.
    // Pure web/API tasks do not require Accessibility.
    // -------------------------------------------------------------------------

    final savedSkill =
        await _skillMemory.findSkill(userGoal);

    if (savedSkill != null &&
        savedSkill.isReliable) {
      final accessibilityAvailable =
          await _screenService.isServiceRunning();

      if (accessibilityAvailable) {
        _report(
          'Found saved skill! Replaying '
          '${savedSkill.steps.length} steps...',
        );

        final replaySuccess =
            await _replaySkill(
          savedSkill,
          results,
        );

        if (replaySuccess) {
          results.add(
            'Task complete via skill memory.',
          );

          _report(
            'Task complete (via skill memory).',
          );

          await _notificationService
              .showTaskCompleteNotification(
            'Task Completed',
            'Agent finished its goal using memory.',
          );

          await TaskHistoryLogger.logTask(
            userGoal,
            'Success',
            0,
            savedSkill.steps.length,
            results,
          );

          await _screenService.showToast(
            'Task Complete! (Memory)',
          );

          return 'Done.';
        }

        _report(
          'Replay failed, falling back to AI...',
        );

        await _skillMemory.recordFailure(
          savedSkill.id,
        );
      } else {
        _report(
          'Saved UI skill found, but Accessibility is unavailable. '
          'Falling back to general agent.',
        );
      }
    }

    // -------------------------------------------------------------------------
    // Navigation shortcuts
    //
    // We intentionally do NOT launch Chrome automatically for generic
    // "browse/search Google" requests anymore.
    // -------------------------------------------------------------------------

    final shortcut =
        _getNavigationShortcut(userGoal);

    String lastAction = '';

    int sameActionCount = 0;

    int consecutiveFailures = 0;

    String lastFailedAction = '';

    int totalTokens = 0;

    final List<ActionStep> executedSteps = [];

    if (shortcut != null &&
        shortcut.isNotEmpty) {
      final accessibilityAvailable =
          await _screenService.isServiceRunning();

      if (accessibilityAvailable) {
        results.add(
          'Using navigation shortcut: '
          '${shortcut.length} steps',
        );

        _report(
          'Using navigation shortcut...',
        );

        for (final stepAction in shortcut) {
          if (_cancelled) {
            break;
          }

          bool success = false;

          if (stepAction.action == 'open_app') {
            final appName =
                stepAction.params['app_name']
                        as String? ??
                    '';

            final res =
                await _appLauncher.openApp(
              appName,
            );

            success =
                res.startsWith('Opened');

            await Future.delayed(
              const Duration(milliseconds: 3000),
            );
          } else if (
              stepAction.action ==
                  'click_text') {
            final text =
                stepAction.params['text']
                        as String? ??
                    '';

            success =
                await _screenService.clickByText(
              text,
            );

            await Future.delayed(
              const Duration(milliseconds: 1500),
            );
          }

          if (success) {
            executedSteps.add(
              stepAction,
            );

            lastAction =
                stepAction.action;
          } else {
            break;
          }
        }
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

    for (
      int step = 0;
      step < _aiService.maxSteps;
      step++
    ) {
      // -----------------------------------------------------------------------
      // Cancellation
      // -----------------------------------------------------------------------

      if (_cancelled) {
        return await _handleCancellation(
          userGoal,
          totalTokens,
          step,
          results,
        );
      }

      // -----------------------------------------------------------------------
      // Adaptive delay
      //
      // Web/API actions do not need the old UI delays.
      // -----------------------------------------------------------------------

      if (lastAction == 'open_app') {
        await Future.delayed(
          const Duration(milliseconds: 1800),
        );
      } else if (
          lastAction == 'type_text') {
        await Future.delayed(
          const Duration(milliseconds: 1200),
        );
      } else if (
          lastAction == 'click_text' ||
          lastAction == 'click_at') {
        await Future.delayed(
          const Duration(milliseconds: 800),
        );
      } else if (
          lastAction == 'scroll' ||
          lastAction == 'swipe') {
        await Future.delayed(
          const Duration(milliseconds: 600),
        );
      }

      // -----------------------------------------------------------------------
      // Build recent results
      // -----------------------------------------------------------------------

      final recentResults =
          results.length <= 5
              ? results
              : results.sublist(
                  results.length - 5,
                );

      final previousResultText =
          previousResult.isEmpty
              ? 'None'
              : previousResult;

      String failureHint = '';

      if (consecutiveFailures >= 3) {
        failureHint = '''
WARNING:
The agent has failed $consecutiveFailures times recently.

Do NOT blindly repeat the same strategy.
Consider a different tool or method.
''';
      }

      // -----------------------------------------------------------------------
      // Planner prompt
      // -----------------------------------------------------------------------

      final prompt = '''
TASK:
$userGoal

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

$failureHint

Choose the single best next action.

Remember:
- Prefer direct HTTP/API when possible.
- Do NOT open Chrome merely to obtain web information.
- If HTTP/API is blocked, change strategy.
- If UI is necessary and CURRENT SCREEN is "Not read yet.",
  use read_screen first.
- Do not claim completion without actually completing the task.
''';

      developer.log(
        '=== AI PROMPT ===\n$prompt',
        name: 'PrivateAgent',
      );

      // -----------------------------------------------------------------------
      // AI
      // -----------------------------------------------------------------------

      String response;

      try {
        _cancelCompleter =
            Completer<void>();

        final aiFuture =
            _aiService.sendTaskMessage(
          _taskSystemPrompt,
          prompt,
        );

        final result =
            await Future.any([
          aiFuture.then(
            (r) => r,
          ),
          _cancelCompleter!.future.then(
            (_) => null,
          ),
        ]);

        if (result == null ||
            _cancelled) {
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        }

        final aiResponse =
            result as AiResponse;

        response =
            aiResponse.content;

        totalTokens +=
            aiResponse.totalTokens;

        developer.log(
          '=== RAW AI RESPONSE ===\n$response',
          name: 'PrivateAgent',
        );
      } catch (e) {
        if (_cancelled) {
          return await _handleCancellation(
            userGoal,
            totalTokens,
            step,
            results,
          );
        }

        results.add(
          'AI error: $e',
        );

        _report(
          'Error: $e',
        );

        await _notificationService
            .showTaskCompleteNotification(
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

        return 'I could not complete the task because the AI service failed.';
      }

      // -----------------------------------------------------------------------
      // Parse action
      // -----------------------------------------------------------------------

      Map<String, dynamic>? actionJson;

      try {
        final jsonStr =
            _extractJson(response);

        actionJson =
            jsonDecode(jsonStr)
                as Map<String, dynamic>;
      } catch (firstError) {
        developer.log(
          '=== JSON PARSE FAILED, RETRYING ===\n'
          'Error: $firstError\n'
          'Raw: $response',
          name: 'PrivateAgent',
        );

        _report(
          'Retrying step ${step + 1}...',
        );

        await Future.delayed(
          const Duration(seconds: 1),
        );

        try {
          final retryResponse =
              await _aiService
                  .sendTaskMessage(
            _taskSystemPrompt,
            prompt,
          );

          totalTokens +=
              retryResponse.totalTokens;

          final jsonStr =
              _extractJson(
            retryResponse.content,
          );

          actionJson =
              jsonDecode(jsonStr)
                  as Map<String, dynamic>;
        } catch (e) {
          results.add(
            'Step ${step + 1}: Error after retry: $e',
          );

          _report(
            'AI formatting error.',
          );

          await _notificationService
              .showTaskCompleteNotification(
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

          return 'I could not understand the AI response. Please try again.';
        }
      }

      final action =
          actionJson['action']
                  as String? ??
              'done';

      final params =
          actionJson['params']
                  as Map<String, dynamic>? ??
              {};

      final reasoning =
          actionJson['reasoning']
                  as String? ??
              '';

      final isComplete =
          actionJson['is_complete'] ==
              true;

      developer.log(
        '=== PARSED ACTION ===\n'
        'Action: $action\n'
        'Params: $params\n'
        'Reasoning: $reasoning\n'
        'Is Complete: $isComplete',
        name: 'PrivateAgent',
      );

      _report(
        'Step ${step + 1}: $reasoning',
      );

      // -----------------------------------------------------------------------
      // Repeat protection
      // -----------------------------------------------------------------------

      sameActionCount =
          action == lastAction
              ? sameActionCount + 1
              : 1;

      final repeatLimit =
          action == 'press_enter'
              ? 2
              : (
                  action == 'scroll' ||
                  action == 'swipe'
                )
                  ? 3
                  : 1000;

      if (sameActionCount >
          repeatLimit) {
        final blockedResult =
            'Blocked repeated $action action. '
            'Use a different strategy.';

        results.add(
          blockedResult,
        );

        _report(
          blockedResult,
        );

        previousResult =
            blockedResult;

        consecutiveFailures++;

        lastFailedAction =
            action;

        lastAction =
            action;

        continue;
      }

      lastAction =
          action;

      // -----------------------------------------------------------------------
      // DONE
      // -----------------------------------------------------------------------

      if (action == 'done' ||
          isComplete) {
        final finalText =
            reasoning.trim().isEmpty
                ? 'Done.'
                : reasoning.trim();

        results.add(
          'Task complete: $finalText',
        );

        _report(
          'Task complete: $finalText',
        );

        await _notificationService
            .showTaskCompleteNotification(
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

        // Only save UI-based skills.
        //
        // Web/API tasks should not become UI skills.
        if (executedSteps.isNotEmpty) {
          await _skillMemory.saveSkill(
            userGoal,
            executedSteps,
          );
        }

        // Toast requires Accessibility, so only use it when available.
        if (await _screenService.isServiceRunning()) {
          await _screenService.showToast(
            'Task completed',
          );
        }

        return finalText;
      }

      // -----------------------------------------------------------------------
      // READ SCREEN
      // -----------------------------------------------------------------------

      if (action == 'read_screen') {
        final accessibilityAvailable =
            await _screenService
                .isServiceRunning();

        if (!accessibilityAvailable) {
          previousResult =
              'ERROR: Accessibility service is not enabled. '
              'UI cannot be used.';

          consecutiveFailures++;

          results.add(
            'read_screen ? $previousResult',
          );

          continue;
        }

        try {
          screenContent =
              _aiService
                  .useScreenCompression
                  ? await _screenService
                      .getCompressedScreenDescription(
                      userGoal,
                    )
                  : await _screenService
                      .getScreenDescription();

          previousResult =
              'Screen successfully read.';

          results.add(
            'read_screen ? Screen successfully read.',
          );

          consecutiveFailures =
              0;
        } catch (e) {
          previousResult =
              'ERROR reading screen: $e';

          consecutiveFailures++;
        }

        continue;
      }

      // -----------------------------------------------------------------------
      // WEB REQUEST
      // -----------------------------------------------------------------------

      if (action ==
          'web_request') {
        final method =
            params['method']
                    as String? ??
                'GET';

        final url =
            params['url']
                    as String? ??
                '';

        final headers =
            params['headers'] is Map
                ? Map<String, dynamic>.from(
                    params['headers'] as Map,
                  )
                : null;

        final body =
            params['body'];

        if (url.isEmpty) {
          previousResult =
              'ERROR: web_request requires a URL.';

          consecutiveFailures++;

          results.add(
            'web_request ? $previousResult',
          );

          continue;
        }

        _report(
          '?? $method $url',
        );

        developer.log(
          'WEB REQUEST: $method $url',
          name: 'PrivateAgent',
        );

        final webResult =
            await _webService.request(
          method: method,
          url: url,
          headers: headers,
          body: body,
        );

        previousResult =
            webResult;

        results.add(
          'web_request $method $url ?\n$webResult',
        );

        final status =
            _extractHttpStatus(
          webResult,
        );

        final failed =
            webResult.startsWith(
              'Web request error:',
            ) ||
            (status != null &&
                status >= 400);

        if (failed) {
          consecutiveFailures++;

          _report(
            '?? Web request failed. '
            'Agent must choose another strategy.',
          );

          developer.log(
            'WEB REQUEST FAILED: '
            'HTTP ${status ?? "unknown"}',
            name: 'PrivateAgent',
          );

          // VERY IMPORTANT:
          //
          // Do NOT call RecoveryEngine here.
          //
          // This is a web strategy failure, not a UI failure.
          // The actual HTTP result goes back to Kimi.
        } else {
          consecutiveFailures =
              0;

          _report(
            '?? Web response received.',
          );
        }

        continue;
      }

      // -----------------------------------------------------------------------
      // OPEN URL
      // -----------------------------------------------------------------------

      if (action ==
          'open_url') {
        final url =
            params['url']
                    as String? ??
                '';

        if (url.isEmpty) {
          previousResult =
              'ERROR: open_url requires a URL.';

          consecutiveFailures++;

          continue;
        }

        _report(
          '?? Opening $url...',
        );

        final openResult =
            await _appLauncher
                .openUrl(url);

        previousResult =
            openResult;

        results.add(
          'open_url $url ? $openResult',
        );

        if (openResult.startsWith(
              'Error',
            ) ||
            openResult.startsWith(
              'Cannot',
            )) {
          consecutiveFailures++;
        } else {
          consecutiveFailures =
              0;

          // External browser/app changed the screen.
          screenContent = '';
        }

        continue;
      }

      // -----------------------------------------------------------------------
      // OPEN APP
      // -----------------------------------------------------------------------

      if (action ==
          'open_app') {
        final appName =
            params['app_name']
                    as String? ??
                '';

        if (appName.isEmpty) {
          previousResult =
              'ERROR: open_app requires app_name.';

          consecutiveFailures++;

          continue;
        }

        final accessibilityAvailable =
            await _screenService
                .isServiceRunning();

        if (!accessibilityAvailable) {
          // Opening an app itself does not strictly require Accessibility.
          final openResult =
              await _appLauncher
                  .openApp(appName);

          previousResult =
              openResult;

          results.add(
            'open_app $appName ? $openResult',
          );

          if (openResult.startsWith(
                'Opened',
              )) {
            screenContent = '';
            consecutiveFailures =
                0;
          } else {
            consecutiveFailures++;
          }

          continue;
        }

        _report(
          '?? Opening $appName...',
        );

        final openResult =
            await _appLauncher
                .openApp(appName);

        previousResult =
            openResult;

        results.add(
          'open_app $appName ? $openResult',
        );

        if (openResult.startsWith(
          'Opened',
        )) {
          consecutiveFailures =
              0;

          screenContent = '';

          executedSteps.add(
            ActionStep(
              action: action,
              params: params,
            ),
          );
        } else {
          consecutiveFailures++;
        }

        continue;
      }

      // -----------------------------------------------------------------------
      // SHIZUKU
      // -----------------------------------------------------------------------

      if (action ==
          'run_adb_command') {
        final command =
            params['command']
                    as String? ??
                '';

        if (command.isEmpty) {
          previousResult =
              'ERROR: run_adb_command requires command.';

          consecutiveFailures++;

          continue;
        }

        _report(
          '?? Running command...',
        );

        try {
          final commandResult =
              await _shizukuService
                  .runCommand(command);

          previousResult =
              commandResult;

          results.add(
            'run_adb_command $command ?\n$commandResult',
          );

          final normalized =
              commandResult.toLowerCase();

          final failed =
              normalized.contains(
                    'not running',
                  ) ||
                  normalized.contains(
                    'permission denied',
                  ) ||
                  normalized.startsWith(
                    'error',
                  );

          if (failed) {
            consecutiveFailures++;
          } else {
            consecutiveFailures =
                0;
          }
        } catch (e) {
          previousResult =
              'ERROR executing command: $e';

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
        previousResult =
            'ERROR: Unknown action "$action".';

        consecutiveFailures++;

        continue;
      }

      // -----------------------------------------------------------------------
      // WAIT does not require Accessibility
      // -----------------------------------------------------------------------

      if (action ==
          'wait') {
        final milliseconds =
            (params['milliseconds']
                    as num?)
                ?.toInt() ??
            1000;

        await Future.delayed(
          Duration(
            milliseconds:
                milliseconds,
          ),
        );

        previousResult =
            'Waited ${milliseconds}ms.';

        results.add(
          'wait ? ${milliseconds}ms',
        );

        consecutiveFailures =
            0;

        continue;
      }

      // -----------------------------------------------------------------------
      // UI requires Accessibility
      // -----------------------------------------------------------------------

      final accessibilityAvailable =
          await _screenService
              .isServiceRunning();

      if (!accessibilityAvailable) {
        previousResult =
            'ERROR: Accessibility service is not enabled. '
            'Cannot execute UI action "$action".';

        consecutiveFailures++;

        results.add(
          '$action ? $previousResult',
        );

        continue;
      }

      // -----------------------------------------------------------------------
      // If screen has not been read, read it first.
      //
      // We intentionally do NOT execute the requested UI action blindly.
      // Kimi gets another planning cycle with actual screen data.
      // -----------------------------------------------------------------------

      if (screenContent.isEmpty) {
        try {
          screenContent =
              _aiService
                  .useScreenCompression
                  ? await _screenService
                      .getCompressedScreenDescription(
                      userGoal,
                    )
                  : await _screenService
                      .getScreenDescription();

          previousResult =
              'Screen read successfully. '
              'The UI action must be reconsidered using this screen.';

          results.add(
            'read_screen ? Screen successfully read.',
          );

          consecutiveFailures =
              0;

          // Do not execute the stale action.
          continue;
        } catch (e) {
          previousResult =
              'ERROR reading screen: $e';

          consecutiveFailures++;

          continue;
        }
      }

      // -----------------------------------------------------------------------
      // Execute UI action
      // -----------------------------------------------------------------------

      bool success = false;
      String actionResult = '';

      switch (action) {
        case 'click_text':
          final text =
              params['text']
                      as String? ??
                  '';

          success =
              await _screenService
                  .clickByText(text);

          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';

          break;

        case 'click_at':
          final x =
              (params['x'] as num?)
                      ?.toDouble() ??
                  0;

          final y =
              (params['y'] as num?)
                      ?.toDouble() ??
                  0;

          success =
              await _screenService
                  .clickAt(
            x,
            y,
          );

          actionResult = success
              ? 'Clicked at ($x, $y)'
              : 'Click failed';

          break;

        case 'type_text':
          final text =
              params['text']
                      as String? ??
                  '';

          final hint =
              params['field_hint']
                  as String?;

          success =
              await _screenService
                  .typeText(
            text,
            fieldHint: hint,
          );

          actionResult = success
              ? 'Typed "$text"'
              : 'Could not type text';

          break;

        case 'press_enter':
          success =
              await _submitKeyboardAction();

          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';

          break;

        case 'swipe':
          final startX =
              (params['startX']
                          as num?)
                      ?.toDouble() ??
                  540;

          final startY =
              (params['startY']
                          as num?)
                      ?.toDouble() ??
                  2000;

          final endX =
              (params['endX']
                          as num?)
                      ?.toDouble() ??
                  540;

          final endY =
              (params['endY']
                          as num?)
                      ?.toDouble() ??
                  500;

          success =
              await _performSwipe(
            startX,
            startY,
            endX,
            endY,
          );

          actionResult =
              success
                  ? 'Swiped from '
                      '($startX,$startY) to '
                      '($endX,$endY)'
                  : 'Swipe failed';

          break;

        case 'scroll':
          final direction =
              params['direction']
                      as String? ??
                  'down';

          success =
              await _performScroll(
            direction,
          );

          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';

          break;

        case 'press_back':
          success =
              await _screenService
                  .pressBack();

          actionResult =
              success
                  ? 'Pressed back'
                  : 'Could not press back';

          break;

        case 'press_home':
          success =
              await _screenService
                  .pressHome();

          actionResult =
              success
                  ? 'Pressed home'
                  : 'Could not press home';

          break;
      }

      developer.log(
        '=== NATIVE EXECUTION RESULT ===\n'
        '$actionResult',
        name: 'PrivateAgent',
      );

      previousResult =
          actionResult;

      results.add(
        'Step ${step + 1}: '
        '$actionResult ($reasoning)',
      );

      // -----------------------------------------------------------------------
      // UI success
      // -----------------------------------------------------------------------

      if (success) {
        consecutiveFailures =
            0;

        lastFailedAction =
            '';

        executedSteps.add(
          ActionStep(
            action: action,
            params: params,
          ),
        );

        // Screen changed and current dump is now stale.
        screenContent = '';

        if (!isComplete &&
            (step + 1) % 3 == 0) {
          await _screenService
              .showToast(
            'Working... (Step ${step + 1})',
          );
        }

        continue;
      }

      // -----------------------------------------------------------------------
      // UI failure ? RecoveryEngine
      // -----------------------------------------------------------------------

      if (action ==
              lastFailedAction &&
          consecutiveFailures > 0) {
        consecutiveFailures++;
      } else {
        consecutiveFailures =
            1;

        lastFailedAction =
            action;
      }

      // Prevent infinite UI failure loops.
      if (consecutiveFailures >= 5) {
        results.add(
          'Agent is stuck after '
          '$consecutiveFailures consecutive failures.',
        );

        _report(
          'Agent stuck — changing strategy.',
        );

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

      final recovery =
          await _recoveryEngine
              .diagnose(
        action,
        screenContent,
      );

      _report(
        'Recovering: ${recovery.description}',
      );

      if (recovery.action ==
          'wait') {
        await Future.delayed(
          const Duration(seconds: 2),
        );
      } else if (
          recovery.action ==
              'press_back') {
        await _screenService
            .pressBack();
      } else if (
          recovery.action ==
              'scroll') {
        final dir =
            recovery.params[
                    'direction'] ??
                'down';

        if (dir == 'down') {
          await _shizukuService
              .runCommand(
            'input swipe 540 1800 540 600 600',
          );
        } else {
          await _shizukuService
              .runCommand(
            'input swipe 540 600 540 1800 600',
          );
        }
      } else if (
          recovery.action ==
              'press_home') {
        await _screenService
            .pressHome();
      }

      results.add(
        'Recovery step: '
        '${recovery.description}',
      );

      // Recovery changed the UI.
      screenContent = '';
    }

    // =========================================================================
    // MAX STEPS
    // =========================================================================

    results.add(
      'Reached maximum steps '
      '(${_aiService.maxSteps}). '
      'Task may be incomplete.',
    );

    _report(
      'Reached maximum steps.',
    );

    await _notificationService
        .showTaskCompleteNotification(
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

    if (await _screenService.isServiceRunning()) {
      await _screenService.showToast(
        'Reached maximum steps.',
      );
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
    results.add(
      'Task cancelled by user.',
    );

    _report(
      'Task cancelled.',
    );

    await _notificationService
        .showTaskCompleteNotification(
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

    if (await _screenService.isServiceRunning()) {
      await _screenService.showToast(
        'Task Cancelled',
      );
    }

    return 'Task cancelled.';
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  void _report(String message) {
    onProgress?.call(message);
  }

  int? _extractHttpStatus(
    String result,
  ) {
    final match =
        RegExp(
          r'^HTTP\s+(\d+)',
        ).firstMatch(result);

    if (match == null) {
      return null;
    }

    return int.tryParse(
      match.group(1)!,
    );
  }

  // ===========================================================================
  // KEYBOARD
  // ===========================================================================

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) {
      return true;
    }

    final shizukuAvailable =
        await _shizukuService
            .checkAvailability();

    if (!shizukuAvailable) {
      return false;
    }

    final result =
        await _shizukuService.runCommand(
      'input keyevent 66',
    );

    final normalized =
        result.toLowerCase();

    return !normalized.contains(
          'not running',
        ) &&
        !normalized.contains(
          'permission denied',
        ) &&
        !normalized.startsWith(
          'error',
        );
  }

  // ===========================================================================
  // SCROLL
  // ===========================================================================

  Future<bool> _performScroll(
    String direction,
  ) async {
    if (await _screenService
        .scroll(direction)) {
      return true;
    }

    final isDown =
        direction.toLowerCase() ==
            'down';

    return _performSwipe(
      540,
      isDown ? 1800 : 600,
      540,
      isDown ? 600 : 1800,
    );
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
    if (await _screenService.swipe(
      startX,
      startY,
      endX,
      endY,
    )) {
      return true;
    }

    final shizukuAvailable =
        await _shizukuService
            .checkAvailability();

    if (!shizukuAvailable) {
      return false;
    }

    final result =
        await _shizukuService.runCommand(
      'input swipe '
      '${startX.toInt()} '
      '${startY.toInt()} '
      '${endX.toInt()} '
      '${endY.toInt()} 600',
    );

    final normalized =
        result.toLowerCase();

    return !normalized.contains(
          'not running',
        ) &&
        !normalized.contains(
          'permission denied',
        ) &&
        !normalized.startsWith(
          'error',
        );
  }

  // ===========================================================================
  // SKILL REPLAY
  // ===========================================================================

  Future<bool> _replaySkill(
    SavedSkill skill,
    List<String> results,
  ) async {
    for (
      int i = 0;
      i < skill.steps.length;
      i++
    ) {
      if (_cancelled) {
        return false;
      }

      final step =
          skill.steps[i];

      _report(
        'Replaying step '
        '${i + 1}/${skill.steps.length}: '
        '${step.action}',
      );

      int delay = 1200;

      if (step.action ==
          'open_app') {
        delay = 3000;
      } else if (
          step.action ==
              'type_text') {
        delay = 2000;
      } else if (
          step.action ==
                  'click_text' ||
              step.action ==
                  'click_at') {
        delay = 1500;
      } else if (
          step.action ==
              'scroll') {
        delay = 1000;
      }

      await Future.delayed(
        Duration(
          milliseconds: delay,
        ),
      );

      bool success = false;

      String actionResult = '';

      switch (step.action) {
        case 'click_text':
          final text =
              step.params['text']
                      as String? ??
                  '';

          success =
              await _screenService
                  .clickByText(text);

          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';

          break;

        case 'click_at':
          final x =
              (step.params['x']
                          as num?)
                      ?.toDouble() ??
                  0;

          final y =
              (step.params['y']
                          as num?)
                      ?.toDouble() ??
                  0;

          success =
              await _screenService
                  .clickAt(
            x,
            y,
          );

          actionResult = success
              ? 'Clicked at ($x, $y)'
              : 'Click failed';

          break;

        case 'type_text':
          final text =
              step.params['text']
                      as String? ??
                  '';

          final hint =
              step.params['field_hint']
                  as String?;

          success =
              await _screenService
                  .typeText(
            text,
            fieldHint: hint,
          );

          actionResult = success
              ? 'Typed "$text"'
              : 'Could not type text';

          break;

        case 'press_enter':
          success =
              await _submitKeyboardAction();

          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';

          break;

        case 'swipe':
          final startX =
              (step.params['startX']
                          as num?)
                      ?.toDouble() ??
                  540;

          final startY =
              (step.params['startY']
                          as num?)
                      ?.toDouble() ??
                  2000;

          final endX =
              (step.params['endX']
                          as num?)
                      ?.toDouble() ??
                  540;

          final endY =
              (step.params['endY']
                          as num?)
                      ?.toDouble() ??
                  500;

          success =
              await _performSwipe(
            startX,
            startY,
            endX,
            endY,
          );

          actionResult =
              success
                  ? 'Swiped from '
                      '($startX,$startY) to '
                      '($endX,$endY)'
                  : 'Swipe failed';

          break;

        case 'scroll':
          final direction =
              step.params['direction']
                      as String? ??
                  'down';

          success =
              await _performScroll(
            direction,
          );

          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';

          break;

        case 'press_back':
          success =
              await _screenService
                  .pressBack();

          actionResult =
              success
                  ? 'Pressed back'
                  : 'Could not press back';

          break;

        case 'press_home':
          success =
              await _screenService
                  .pressHome();

          actionResult =
              success
                  ? 'Pressed home'
                  : 'Could not press home';

          break;

        case 'open_app':
          final appName =
              step.params['app_name']
                      as String? ??
                  '';

          actionResult =
              await _appLauncher
                  .openApp(appName);

          success =
              actionResult.startsWith(
            'Opened',
          );

          break;

        case 'wait':
          await Future.delayed(
            const Duration(seconds: 1),
          );

          actionResult =
              'Waited';

          success = true;

          break;

        case 'done':
          success = true;
          actionResult =
              'Done step reached';

          break;

        default:
          success = false;

          actionResult =
              'Unknown action: '
              '${step.action}';
      }

      results.add(
        'Memory Replay Step '
        '${i + 1}: $actionResult',
      );

      developer.log(
        '=== MEMORY REPLAY RESULT ===\n'
        '$actionResult',
        name: 'PrivateAgent',
      );

      if (!success) {
        return false;
      }
    }

    return true;
  }

  // ===========================================================================
  // NAVIGATION SHORTCUTS
  // ===========================================================================

  List<ActionStep>? _getNavigationShortcut(
    String goal,
  ) {
    final lower =
        goal.toLowerCase().trim();

    // These are explicit Android settings tasks.
    if (lower.contains('dark mode') ||
        lower.contains('dark theme')) {
      return [
        ActionStep(
          action: 'open_app',
          params: {
            'app_name': 'Settings',
          },
        ),
        ActionStep(
          action: 'click_text',
          params: {
            'text': 'Display',
          },
        ),
      ];
    }

    if (lower.contains('wifi') ||
        lower.contains('wi-fi')) {
      return [
        ActionStep(
          action: 'open_app',
          params: {
            'app_name': 'Settings',
          },
        ),
        ActionStep(
          action: 'click_text',
          params: {
            'text': 'Network & internet',
          },
        ),
      ];
    }

    if (lower.contains('bluetooth')) {
      return [
        ActionStep(
          action: 'open_app',
          params: {
            'app_name': 'Settings',
          },
        ),
        ActionStep(
          action: 'click_text',
          params: {
            'text': 'Connected devices',
          },
        ),
      ];
    }

    // IMPORTANT:
    //
    // We intentionally removed broad patterns such as:
    //
    // 'browse' -> Chrome
    // 'search google' -> Chrome
    //
    // Those caused Internet tasks to be forced into UI automation.
    //
    // Explicit app-opening requests can still use the shortcut.

    final explicitOpen =
        RegExp(
          r'^(open|abrir|abre)\s+(.+)$',
          caseSensitive: false,
        ).firstMatch(
      lower,
    );

    if (explicitOpen != null) {
      final app =
          explicitOpen.group(2)?.trim();

      if (app != null &&
          app.isNotEmpty) {
        return [
          ActionStep(
            action: 'open_app',
            params: {
              'app_name':
                  app[0].toUpperCase() +
                      app.substring(1),
            },
          ),
        ];
      }
    }

    return null;
  }
}