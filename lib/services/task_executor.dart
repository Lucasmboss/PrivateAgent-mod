
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
