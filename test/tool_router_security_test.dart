import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/agent_action.dart';
import 'package:private_agent/models/task_record.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/app_launcher_service.dart';
import 'package:private_agent/services/notification_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';
import 'package:private_agent/services/shizuku_service.dart';
import 'package:private_agent/services/task_executor.dart';
import 'package:private_agent/services/task_store.dart';
import 'package:private_agent/services/telegram_service.dart';
import 'package:private_agent/services/tool_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Planner extends AiService {
  final Future<AiResponse> Function(RemoteCancellationToken?, int?) answer;
  _Planner(this.answer);
  @override
  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt, {
    RemoteCancellationToken? cancellationToken, int? maxOutputTokens,
  }) => answer(cancellationToken, maxOutputTokens);
}

class _NoopNotificationService extends NotificationService {
  @override
  Future<void> showTaskCompleteNotification(String title, String body) async {}
}

class _FakeShizukuService extends ShizukuService {
  _FakeShizukuService(this.result);

  final ShizukuCommandResult result;
  String? lastCommand;

  @override
  Future<ShizukuCommandResult> runCommandWithStatus(String command) async {
    lastCommand = command;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('explicit host veto blocks direct action dispatch', () async {
    final handler = ActionHandler();
    for (final action in [
      AgentAction(action: 'click_element', params: {'text': 'Send'}, response: ''),
      AgentAction(action: 'delete_file', params: {'path': 'notes'}, response: ''),
      AgentAction(action: 'run_adb_command', params: {'command': 'echo approved'}, response: ''),
    ]) {
      final result = await handler.execute(
        action,
        userRequest: 'yes approved delete remove',
        onApproval: (_) async => false,
      );
      expect(result.success, isFalse);
      expect(result.details, contains('denied'));
    }
  });

  test('router rechecks pause after consent returns', () async {
    final handler = ActionHandler();
    final result = await handler.execute(
      AgentAction(action: 'click_element', params: {'text': 'Send'}, response: ''),
      onApproval: (_) async {
        handler.pauseTask();
        return true;
      },
    );
    expect(result.success, isFalse);
    expect(result.details, contains('paused or cancelled'));
  });

  test('Telegram requires exact explicit chat ID, not first caller', () {
    expect(TelegramService.isAuthorizedChat('42', ''), isFalse);
    expect(TelegramService.isAuthorizedChat('42', '43'), isFalse);
    expect(TelegramService.isAuthorizedChat('42', '42'), isTrue);
    expect(TelegramService.isAuthorizedChat('-10042', '-10042'), isTrue);
    expect(TelegramService.isAuthorizedChat('42', '*'), isFalse);
  });

  group('checkpointed executor gates', () {
    late Directory directory;
    late TaskStore store;
    // Task history uses path_provider; keep its writes inside the test folder.
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('router-security-');
      store = TaskStore(directory: directory);
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return directory.path;
            }
            return null;
          });
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      await directory.delete(recursive: true);
    });

    TaskExecutor executor(
      AiService ai, {
      ToolApprovalCallback? approve,
      ShizukuService? shizuku,
      int tokens = 100,
      Duration duration = const Duration(minutes: 1),
    }) => TaskExecutor(
      aiService: ai,
      screenService: ScreenAutomationService(),
      appLauncher: AppLauncherService(),
      shizukuService: shizuku ?? ShizukuService(),
      notificationService: _NoopNotificationService(),
      taskStore: store,
      onApproval: approve,
      maxTaskTokens: tokens,
      maxTaskDuration: duration,
    );

    test('explicit host veto never creates success evidence or action checkpoint', () async {
      final engine = executor(
        _Planner((_, __) async =>
            AiResponse('{"action":"click_element","params":{"text":"Send"}}', 1)),
        approve: (_) async => false,
      );
      expect(await engine.executeTask('Send it'), contains('denied'));
      final record = (await store.list()).single;
      expect(record.status, TaskStatus.needsRevision);
      expect(record.execution.audit, isEmpty);
      expect(record.execution.inFlight, isNull);
    });

    test('pause during approval prevents dispatch and persists paused', () async {
      late TaskExecutor engine;
      engine = executor(_Planner((_, __) async =>
          AiResponse('{"action":"type_on_screen","params":{"text":"secret"}}', 1)),
          approve: (_) async {
            engine.pause();
            return true;
          });
      await engine.executeTask('Type');
      final record = (await store.list()).single;
      expect(record.status, TaskStatus.paused);
      expect(record.execution.audit, isEmpty);
    });

    test('token budget blocks tool dispatch and clamps requested output', () async {
      int? requested;
      final engine = executor(_Planner((_, max) async {
        requested = max;
        return AiResponse('{"action":"read_screen","params":{}}', 5);
      }), tokens: 5);
      expect(await engine.executeTask('Read'), contains('budget exhausted'));
      expect(requested, 5);
      final record = (await store.list()).single;
      expect(record.tokens, 5);
      expect(record.status, TaskStatus.needsRevision);
      expect(record.execution.audit, isEmpty);
    });

    test('expired elapsed budget makes no remote call', () async {
      var calls = 0;
      final engine = executor(_Planner((_, __) async {
        calls++;
        return AiResponse('{}', 1);
      }), duration: Duration.zero);
      expect(await engine.executeTask('Read'), contains('budget exhausted'));
      expect(calls, 0);
      expect((await store.list()).single.status, TaskStatus.needsRevision);
    });

    test('pause cancels in-flight provider request', () async {
      final started = Completer<RemoteCancellationToken>();
      final engine = executor(_Planner((token, _) {
        started.complete(token!);
        final stopped = Completer<AiResponse>();
        token.onCancel(() => stopped.completeError(StateError('cancelled')));
        return stopped.future;
      }));
      final running = engine.executeTask('Read');
      final token = await started.future;
      engine.pause();
      await running;
      expect(token.isCancelled, isTrue);
      expect((await store.list()).single.status, TaskStatus.paused);
    });

    test('cancel cancels in-flight provider request and persists cancelled', () async {
      final started = Completer<RemoteCancellationToken>();
      final engine = executor(_Planner((token, _) {
        started.complete(token!);
        final stopped = Completer<AiResponse>();
        token.onCancel(() => stopped.completeError(StateError('cancelled')));
        return stopped.future;
      }));
      final running = engine.executeTask('Read');
      final token = await started.future;
      engine.cancel();
      expect(await running, contains('Task cancelled'));
      expect(token.isCancelled, isTrue);
      expect((await store.list()).single.status, TaskStatus.cancelled);
    });

    test('retry receives same cancellable token and remaining output budget', () async {
      var calls = 0;
      RemoteCancellationToken? firstToken;
      final startedRetry = Completer<RemoteCancellationToken>();
      final engine = executor(_Planner((token, max) {
        calls++;
        if (calls == 1) {
          firstToken = token;
          return Future.value(AiResponse('not json', 3));
        }
        expect(max, 7);
        expect(identical(token, firstToken), isTrue);
        startedRetry.complete(token!);
        final cancelled = Completer<AiResponse>();
        token.onCancel(() => cancelled.completeError(StateError('cancelled')));
        return cancelled.future;
      }), tokens: 10);
      final running = engine.executeTask('Read');
      final token = await startedRetry.future;
      engine.pause();
      await running;
      expect(token.isCancelled, isTrue);
      final record = (await store.list()).single;
      expect(record.status, TaskStatus.paused);
      expect(record.tokens, 3);
      expect(record.execution.audit, isEmpty);
    });

    test(
      'successful shell exit records technical success without aborting',
      () async {
        final shizuku = _FakeShizukuService(
          const ShizukuCommandResult(
            stdout: 'uptime output\nuid=2000(shell)',
            stderr: '',
            exitCode: 0,
            wasDispatched: true,
          ),
        );
        final engine = executor(
          _Planner(
            (_, __) async => AiResponse(
              '{"action":"run_adb_command","command":"uptime; id",'
              '"reasoning":"Read device status"}',
              1,
            ),
          ),
          shizuku: shizuku,
          tokens: 2,
        );

        await engine.executeTask('Read device status');

        final record = (await store.list()).single;
        expect(shizuku.lastCommand, 'uptime; id');
        expect(record.execution.audit.last.phase, 'after');
        expect(record.execution.audit.last.technicalSuccess, isTrue);
        expect(record.execution.inFlight, isNull);
      },
    );

    test('uncertain action blocks its dependencies but independent work continues', () async {
      final shizuku = _FakeShizukuService(
        const ShizukuCommandResult(
          stdout: 'partial output',
          stderr: '',
          exitCode: null,
          wasDispatched: true,
        ),
      );
      var calls = 0;
      final engine = executor(_Planner((_, __) async {
        calls++;
        return AiResponse(switch (calls) {
          1 =>
            '{"action":"plan","params":{"subtasks":['
            '{"id":"change","objective":"Change device state",'
            '"dependencies":[],"criteria":["Requested state changed"]},'
            '{"id":"independent","objective":"Read independent status",'
            '"dependencies":[],"criteria":["Status was checked"]},'
            '{"id":"dependent","objective":"Continue after the change",'
            '"dependencies":["change"],"criteria":["Dependent work completed"]}'
            ']}}',
          2 =>
            '{"action":"run_adb_command","command":"change-device-state",'
            '"subtask_id":"change","reasoning":"Run the requested change"}',
          3 =>
            '{"action":"read_screen","params":{},'
            '"subtask_id":"independent","reasoning":"Check independent status"}',
          4 =>
            '{"action":"subtask_failed","params":{"subtask_id":"independent",'
            '"failure_code":"strategies_exhausted",'
            '"attempted_strategies":["read_screen"],'
            '"remaining_strategies":[]}}',
          _ => '{"action":"done","params":{}}',
        }, 1);
      }),
        shizuku: shizuku,
      );

      final message = await engine.executeTask('Change device state');

      final record = (await store.list()).single;
      expect(calls, 5);
      expect(message, contains('subtasks verified'));
      expect(record.status, TaskStatus.needsRevision);
      expect(record.execution.inFlight, isNull);
      expect(record.execution.unverifiedMutations, isNotEmpty);
      expect(
        record.execution.audit.any(
          (event) =>
              event.action == 'run_adb_command' &&
              event.phase == 'uncertain' &&
              event.subtaskId == 'change',
        ),
        isTrue,
      );
      expect(
        record.execution.audit.any(
          (event) =>
              event.action == 'read_screen' &&
              event.phase == 'after' &&
              event.subtaskId == 'independent',
        ),
        isTrue,
      );
      final subtasks = {
        for (final subtask in record.execution.plan) subtask.id: subtask,
      };
      expect(subtasks['change']!.status, TaskSubtaskStatus.needsReview);
      expect(subtasks['independent']!.status, TaskSubtaskStatus.failed);
      expect(subtasks['dependent']!.status, TaskSubtaskStatus.blocked);
    });

    test('direct shell routing reports exit-code success', () async {
      final shizuku = _FakeShizukuService(
        const ShizukuCommandResult(
          stdout: 'uptime output',
          stderr: '',
          exitCode: 0,
          wasDispatched: true,
        ),
      );
      final handler = ActionHandler(shizukuService: shizuku);

      final result = await handler.execute(
        AgentAction(
          action: 'run_adb_command',
          params: {'command': 'uptime'},
          response: '',
        ),
      );

      expect(shizuku.lastCommand, 'uptime');
      expect(result.success, isTrue);
      expect(result.details, contains('Exit code: 0'));
    });

    test('resumed task keeps cumulative usage budget', () async {
      final previous = await store.create(goal: 'Read', status: TaskStatus.paused);
      await store.update(previous.identifier, tokens: 95);
      int? requested;
      final engine = executor(_Planner((_, max) async {
        requested = max;
        return AiResponse('{"action":"read_screen","params":{}}', 5);
      }));
      await engine.executeTask('Read', resumeTaskId: previous.identifier);
      final record = (await store.list()).single;
      expect(requested, 5);
      expect(record.tokens, 100);
      expect(record.status, TaskStatus.needsRevision);
      expect(record.execution.audit, isEmpty);
    });

    test('resumed task receives a fresh bounded planner-step window', () async {
      final previous = await store.create(
        goal: 'Read',
        status: TaskStatus.needsRevision,
      );
      await store.update(
        previous.identifier,
        stepsCompleted: AiService().maxSteps,
      );
      var calls = 0;
      final engine = executor(_Planner((_, __) async {
        calls++;
        return AiResponse('{"action":"done","params":{}}', 1);
      }));

      await engine.executeTask('Read', resumeTaskId: previous.identifier);

      final record = (await store.list()).single;
      final maxSteps = AiService().maxSteps;
      expect(calls, maxSteps);
      expect(record.stepsCompleted, maxSteps * 2);
      expect(record.status, TaskStatus.needsRevision);
    });

    test('planner outage retries before pausing the checkpoint', () async {
      var calls = 0;
      final engine = executor(_Planner((_, __) async {
        calls++;
        if (calls == 1) throw StateError('temporary planner outage');
        return AiResponse('{"action":"done","params":{}}', 1);
      }));

      await engine.executeTask('Read');

      expect(calls, AiService().maxSteps);
      final record = (await store.list()).single;
      expect(record.stepsCompleted, AiService().maxSteps);
      expect(engine.lastStatus, TaskStatus.needsRevision);
    });

    test('legacy subtask and audit JSON default new metadata safely', () {
      final subtask = TaskSubtask.fromJson({
        'id': 'legacy',
        'objective': 'Old saved subtask',
        'dependencies': <String>[],
        'criteria': <String>['criterion'],
      });
      final audit = ActionAudit.fromJson({
        'sequence': 1,
        'action': 'read_screen',
        'phase': 'after',
        'timestamp': '2025-01-01T00:00:00.000',
        'mutation': false,
        'technicalSuccess': true,
        'revision': 0,
      });

      expect(subtask.status, TaskSubtaskStatus.pending);
      expect(subtask.attempts, 0);
      expect(audit.subtaskId, isNull);
    });
  });
}