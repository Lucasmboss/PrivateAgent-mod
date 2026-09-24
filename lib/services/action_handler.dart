import '../models/agent_action.dart';
import '../models/chat_message.dart';
import 'app_launcher_service.dart';
import 'contacts_service.dart';
import 'communication_service.dart';
import 'alarm_service.dart';
import 'system_control_service.dart';
import 'shizuku_service.dart';
import 'screen_automation_service.dart';
import 'task_executor.dart';
import 'ai_service.dart';
import 'web_service.dart';
import 'web_search_service.dart';
import 'file_service.dart';
import '../models/task_record.dart';
import 'tool_registry.dart';
import 'tool_policy.dart';
import '../privacy_sanitizer.dart';

class ActionHandler {
  final AppLauncherService _appLauncher = AppLauncherService();
  final ContactsService _contacts = ContactsService();
  final CommunicationService _communication = CommunicationService();
  final AlarmService _alarm = AlarmService();
  final SystemControlService _systemControl = SystemControlService();
  final ShizukuService _shizuku = ShizukuService();
  final WebService _web = WebService();
  final WebSearchService _webSearch = WebSearchService();
  final FileService _files = FileService();
  final ScreenAutomationService _screenAutomation = ScreenAutomationService();

  ShizukuService get shizuku => _shizuku;
  ScreenAutomationService get screenAutomation => _screenAutomation;

  /// The currently running task executor, if any
  TaskExecutor? _currentExecutor;
  int _stopGeneration = 0;

  /// Execute an action and return the result
  Future<AgentActionResult> execute(
    AgentAction action, {
    AiService? aiService,
    void Function(String)? onProgress,
    String? userRequest,
    ToolApprovalCallback? onApproval,
  }) async {
    final generation = _stopGeneration;
    try {
      final call = const ToolRegistry().validate(action.action, action.params);
      if (call.name == 'plan' || call.name == 'done') {
        throw StateError('Internal planning actions require an active task.');
      }
      if (const ToolPolicy().requiresApproval(call)) {
        onProgress?.call('Waiting for approval: ${call.name}');
      }
      final decision = await const ToolPolicy().authorize(call, onApproval: onApproval);
      if (generation != _stopGeneration || !decision.allowed) {
        final details = generation != _stopGeneration
            ? 'Action paused or cancelled before execution.'
            : 'Action denied: ${decision.reason}';
        onProgress?.call(details);
        return AgentActionResult(actionType: call.name, success: false, details: details);
      }
      action = AgentAction(action: call.name, params: call.params, response: action.response);
      String result;
      bool taskSucceeded = false;

      switch (action.action) {
        case 'open_app':
          result = await _appLauncher.openApp(
            action.params['app_name'] as String? ?? '',
          );
          break;

        case 'launch_package':
          final packageName = action.params['package_name'] as String? ?? '';
          result = await _appLauncher.openPackage(packageName);
          break;

        case 'make_call':
          result = await _communication.makeCall(
            contactName: action.params['contact_name'] as String?,
            phoneNumber: action.params['phone_number'] as String?,
          );
          break;

        case 'send_sms':
          result = await _communication.sendSms(
            contactName: action.params['contact_name'] as String?,
            phoneNumber: action.params['phone_number'] as String?,
            message: action.params['message'] as String? ?? '',
          );
          break;

        case 'search_contact':
          result = await _contacts.searchAndFormat(
            action.params['query'] as String? ?? '',
          );
          break;

        case 'set_alarm':
          result = await _alarm.setAlarm(
            hour: (action.params['hour'] as num?)?.toInt() ?? 0,
            minute: (action.params['minute'] as num?)?.toInt() ?? 0,
            label: action.params['label'] as String?,
          );
          break;

        case 'set_timer':
          result = await _alarm.setTimer(
            seconds: (action.params['seconds'] as num?)?.toInt() ?? 60,
            label: action.params['label'] as String?,
          );
          break;

        case 'set_volume':
          result = await _systemControl.setVolume(
            (action.params['level'] as num?)?.toInt() ?? 50,
          );
          break;

        case 'set_brightness':
          result = await _systemControl.setBrightness(
            (action.params['level'] as num?)?.toInt() ?? 50,
          );
          break;

        case 'run_adb_command':
          result = await _shizuku.runCommand(
            action.params['command'] as String? ?? '',
          );
          break;

        case 'web_search':
          final query = action.params['query'] as String? ?? '';

          if (query.trim().isEmpty) {
            result = 'Web search error: empty query.';
            break;
          }

          result = await _webSearch.search(query);
          break;

        case 'web_request':
          final method = action.params['method'] as String? ?? 'GET';
          final url = action.params['url'] as String? ?? '';

          final headers = action.params['headers'] is Map
              ? Map<String, dynamic>.from(action.params['headers'] as Map)
              : null;

          final body = action.params['body'];

          result = await _web.request(
            method: method,
            url: url,
            headers: headers,
            body: body,
          );
          break;

        case 'list_files':
          final files = await _files.listFiles(recursive: true);
          result = files.isEmpty ? 'No files in agent_files.' : files.join('\n');
          break;

        case 'read_file':
          result = await _files.readText(action.params['path'] as String? ?? '');
          if (result.length > 12000) {
            result = '${result.substring(0, 12000)}\n[File content truncated]';
          }
          break;

        case 'write_file':
          await _files.writeText(
            action.params['path'] as String? ?? '',
            action.params['content'] as String? ?? '',
          );
          result = 'File written to agent_files.';
          break;

        case 'delete_file':
          await _files.delete(action.params['path'] as String? ?? '');
          result = 'File deleted from agent_files.';
          break;

        case 'send_email':
          result = await _communication.sendEmail(
            to: action.params['to'] as String? ?? '',
            subject: action.params['subject'] as String?,
            body: action.params['body'] as String?,
          );
          break;

        case 'open_url':
          result = await _appLauncher.openUrl(
            action.params['url'] as String? ?? '',
          );
          break;

        // ??? Screen Automation Actions ????????????????????????

        case 'read_screen':
          result = await _screenAutomation.getScreenDescription();
          break;

        case 'click_text':
          final text = action.params['text'] as String? ?? '';
          final success = await _screenAutomation.clickByText(text);
          result = success ? 'Clicked "$text"' : 'Could not find "$text" to click';
          break;

        case 'type_text':
          final text = action.params['text'] as String? ?? '';
          final hint = action.params['field_hint'] as String?;
          final success = await _screenAutomation.typeText(text, fieldHint: hint);
          result = success ? 'Typed "$text"' : 'Could not type into field';
          break;

        case 'scroll':
          final direction = action.params['direction'] as String? ?? 'down';
          final success = await _screenAutomation.scroll(direction);
          result = success ? 'Scrolled $direction' : 'Could not scroll';
          break;

        case 'click_at':
          final success = await _screenAutomation.clickAt(
              (action.params['x'] as num).toDouble(), (action.params['y'] as num).toDouble());
          result = success ? 'Clicked screen position.' : 'Could not click screen position.';
          break;
        case 'swipe':
          final success = await _screenAutomation.swipe(
              (action.params['startX'] as num).toDouble(), (action.params['startY'] as num).toDouble(),
              (action.params['endX'] as num).toDouble(), (action.params['endY'] as num).toDouble());
          result = success ? 'Swiped screen.' : 'Could not swipe screen.';
          break;
        case 'press_enter':
          final success = await _screenAutomation.pressEnter();
          result = success ? 'Pressed enter.' : 'Could not press enter.';
          break;
        case 'press_home':
          final success = await _screenAutomation.pressHome();
          result = success ? 'Pressed home.' : 'Could not press home.';
          break;
        case 'wait':
          await Future<void>.delayed(Duration(milliseconds: action.params['milliseconds'] as int));
          result = 'Wait completed.';
          break;

        case 'press_back':
          final success = await _screenAutomation.pressBack();
          result = success ? 'Pressed back' : 'Could not press back';
          break;

        // ??? Multi-Step Task Execution ????????????????????????

        case 'execute_task':
          final goal = action.params['goal'] as String? ?? action.response;
          if (aiService == null) {
            result = 'AI service not available for task execution.';
            break;
          }
          if (_currentExecutor != null) {
            throw StateError('A task is already running.');
          }
          _currentExecutor = TaskExecutor(
            aiService: aiService,
            screenService: _screenAutomation,
            appLauncher: _appLauncher,
            shizukuService: _shizuku,
            onProgress: onProgress,
            onApproval: onApproval,
          );
          try {
            result = await _currentExecutor!.executeTask(
              goal,
              resumeTaskId: action.params['resume_task_id'] as String?,
            );
            taskSucceeded =
                _currentExecutor!.lastStatus == TaskStatus.completed;
          } catch (error) {
            await _currentExecutor!.failUnexpected(error);
            rethrow;
          } finally {
            _currentExecutor = null;
          }
          break;

        default:
          throw StateError('Tool is not supported by this router.');
      }

      final requestSucceeded = action.action == 'execute_task'
          ? taskSucceeded
          : action.action == 'web_request'
              ? WebService.isSuccessfulResponse(result)
               : action.action == 'run_adb_command'
                   ? false // No exit-code evidence is available from this adapter.
                   : !ToolRegistry.isFailureResult(result) &&
                       !RegExp(r'^(error|could not|cannot|no phone|shizuku |web search error:|ai service not available)', caseSensitive: false)
                       .hasMatch(result.trim());

      return AgentActionResult(
        actionType: action.action,
        success: requestSucceeded,
        details: result,
      );
    } catch (e) {
      return AgentActionResult(
        actionType: action.action,
        success: false,
        details: PrivacySanitizer.sanitizeTaskTrace('Error: $e'),
      );
    }
  }

  /// Cancel the currently running task
  void cancelTask() {
    _stopGeneration++;
    _currentExecutor?.cancel();
  }

  void pauseTask() {
    _stopGeneration++;
    _currentExecutor?.pause();
  }
}
