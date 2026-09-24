import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';
import '../models/agent_action.dart';
import '../models/task_record.dart';
import '../services/ai_service.dart';
import '../services/action_handler.dart';
import '../services/tool_policy.dart';
import '../privacy_sanitizer.dart';
import '../services/task_store.dart';
import '../services/voice_service.dart';
import '../services/assistant_platform_service.dart';
import '../widgets/message_bubble.dart';
import '../services/telegram_service.dart';
import '../services/chat_history_service.dart';
import '../services/notification_service.dart';
import 'settings_screen.dart';
import 'task_history_screen.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../main.dart';
import '../config/feature_flags.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AiService _aiService = AiService();
  final ActionHandler _actionHandler = ActionHandler();
  final VoiceService _voiceService = VoiceService();
  final NotificationService _notificationService = NotificationService();
  late final TelegramService _telegramService;

  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isListening = false;
  bool _servicesReady = false;
  bool _assistantInvocationQueued = false;
  bool _isTaskExecutorActive = false;
  bool _stopRequested = false;
  bool _lastStopWasPause = false;
  RemoteCancellationToken? _activeResponseCancellation;
  StreamSubscription<dynamic>? _assistantInvocationSubscription;
  String _taskStateLabel = 'Thinking...';
  int _approvalGeneration = 0;
  BuildContext? _approvalDialogContext;

  void _stopActiveTask({required bool pause}) {
    if (_stopRequested) return;
    final canPause = pause && _isTaskExecutorActive;
    _approvalGeneration++;
    _stopRequested = true;
    _lastStopWasPause = canPause;
    _activeResponseCancellation?.cancel();
    if (canPause) {
      _actionHandler.pauseTask();
    } else {
      _actionHandler.cancelTask();
    }
    _dismissApproval();
    if (mounted) {
      setState(() {
        _taskStateLabel = canPause
            ? (_actionHandler.isActionInFlight
                  ? 'Pausing after the current action…'
                  : 'Pausing task…')
            : (_actionHandler.isActionInFlight
                  ? 'Stopping after the current action…'
                  : 'Stopping…');
      });
    }
  }

  void _dismissApproval() {
    final dialog = _approvalDialogContext;
    _approvalDialogContext = null;
    if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
  }

  Future<bool> _requestToolApproval(ToolApprovalRequest request) async {
    if (!mounted || _appLifecycleState != AppLifecycleState.resumed)
      return false;
    final generation = _approvalGeneration;
    setState(() => _taskStateLabel = 'Waiting for approval');
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        _approvalDialogContext = dialogContext;
        return AlertDialog(
          title: const Text('Approve this action?'),
          content: SingleChildScrollView(
            child: Text(
              '${request.summary}\n\n${request.preview}\n\n'
              'Approval applies only to this action. When unsure, deny.',
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Deny'),
            ),
            TextButton(
              onPressed: () => _stopActiveTask(
                pause: _isTaskExecutorActive,
              ),
              child: Text(
                _isTaskExecutorActive ? 'Pause task' : 'Stop request',
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Approve once'),
            ),
          ],
        );
      },
    );
    _approvalDialogContext = null;
    final allowed =
        approved == true &&
        mounted &&
        generation == _approvalGeneration &&
        _appLifecycleState == AppLifecycleState.resumed;
    if (mounted && generation == _approvalGeneration) {
      setState(
        () => _taskStateLabel = allowed
            ? 'Running approved action'
            : 'Approval denied',
      );
    }
    return allowed;
  }

  // Custom switch state: 'chat' or 'agent'. Agent is the safe product default.
  String _mode = 'agent';

  // Chat Session state tracking
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
  String _sessionTitle = '';

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  Timer? _overlayHistoryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _telegramService = TelegramService(_actionHandler, _aiService);
    _assistantInvocationSubscription = AssistantPlatformService
        .assistantInvocations
        .listen((_) {
          unawaited(_handleAssistantInvocation());
        });
    _initServices();
    _startOverlayHistorySync();
    // Register as the handler for overlay bubble tasks
    onOverlayTask = (task) => _sendMessage(task);
  }

  Future<void> _initServices() async {
    await TaskStore().recoverInterrupted();
    await _aiService.init();
    await _notificationService.requestPermission();
    await _voiceService.init();
    await _telegramService.init();
    await _actionHandler.shizuku.checkAvailability();

    _servicesReady = true;
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final assistantInvocation =
        await AssistantPlatformService.consumeAssistantInvocation();
    final shouldActivateAssistant =
        assistantInvocation || _assistantInvocationQueued;
    _assistantInvocationQueued = false;

    if (shouldActivateAssistant) {
      await _activateAssistantInvocation();
      return;
    }

    final savedMode = prefs.getString('interaction_mode');
    if (savedMode == 'chat' || savedMode == 'agent') {
      setState(() => _mode = savedMode!);
    }
  }

  Future<void> _handleAssistantInvocation() async {
    if (!_servicesReady) {
      _assistantInvocationQueued = true;
      return;
    }

    final invoked = await AssistantPlatformService.consumeAssistantInvocation();
    if (invoked) await _activateAssistantInvocation();
  }

  Future<void> _activateAssistantInvocation() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('interaction_mode', 'agent');
    if (mounted) setState(() => _mode = 'agent');

    // Android's default-assistant entry point opens the audited Agent UI and
    // starts the same native Google voice path as the microphone button.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted && !_isLoading && !_isListening) {
      await _toggleVoice();
    }
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;

    // Set first user message as session title if not set
    if (_sessionTitle.isEmpty) {
      final firstUserMsg = _messages.firstWhere(
        (m) => m.isUser,
        orElse: () => ChatMessage(role: 'user', content: 'New Chat'),
      );
      _sessionTitle = firstUserMsg.content.length > 28
          ? '${firstUserMsg.content.substring(0, 25)}...'
          : firstUserMsg.content;
    }

    final session = ChatSession(
      id: _sessionId,
      title: _sessionTitle,
      timestamp: DateTime.now(),
      messages: _messages.map((m) => m.toJson()).toList(),
    );

    await ChatHistoryService.saveSession(session);
  }

  Future<void> _sendMessage(
    String text, {
    bool speakActionResponse = false,
  }) async {
    if (!mounted || _isLoading || text.trim().isEmpty) return;
    final generation = _approvalGeneration;
    final responseCancellation = RemoteCancellationToken();
    _activeResponseCancellation = responseCancellation;
    _stopRequested = false;
    _lastStopWasPause = false;
    _isTaskExecutorActive = false;

    final userMessage = ChatMessage(role: 'user', content: text.trim());
    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
      _taskStateLabel = 'Thinking...';
    });
    _updateOverlayState();
    _textController.clear();
    _scrollToBottom();
    await _saveSession();

    // Add empty placeholder assistant message for streaming
    final assistantMessage = ChatMessage(role: 'assistant', content: '');
    setState(() {
      _messages.add(assistantMessage);
    });
    final assistantIndex = _messages.length - 1;
    var assistantBubbleVisible = true;
    void showStoppedMessage() {
      final message = _lastStopWasPause
          ? 'Paused before a resumable Agent task started. Send the request again to continue.'
          : 'Stopped before another action was started.';
      setState(() {
        if (assistantBubbleVisible && assistantIndex < _messages.length) {
          _messages.removeAt(assistantIndex);
        }
        assistantBubbleVisible = false;
        _messages.add(ChatMessage(role: 'assistant', content: message));
      });
    }

    try {
      final isAgent = _mode == 'agent';
      final stream = _aiService
          .sendMessageStream(
            text.trim(),
            isAgentMode: isAgent,
            cancellationToken: responseCancellation,
          )
          .timeout(
            const Duration(seconds: 90),
            onTimeout: (sink) {
              sink.addError(
                TimeoutException(
                  'The model did not return visible text within 90 seconds.',
                ),
              );
              sink.close();
            },
          );
      String accumulated = '';

      await for (final chunk in stream) {
        accumulated += chunk;
        if (mounted) {
          setState(() {
            _messages[assistantIndex] = ChatMessage(
              role: 'assistant',
              content: accumulated,
            );
          });
          _scrollToBottom();
        }
      }
      await _saveSession();

      // Check if it's an action
      final action = _aiService.parseAction(accumulated);
      if (!mounted) return;
      if (generation != _approvalGeneration) {
        if (_stopRequested) showStoppedMessage();
        return;
      }

      if (action != null) {
        // If it's an action, we remove the raw JSON message from display
        setState(() {
          _messages.removeAt(assistantIndex);
        });
        assistantBubbleVisible = false;

        await _showTaskProgressOverlay('Starting: ${text.trim()}');
        if (!mounted) return;
        if (generation != _approvalGeneration) {
          if (_stopRequested) showStoppedMessage();
          return;
        }
        _isTaskExecutorActive = action.action == 'execute_task';
        if (_isTaskExecutorActive) {
          setState(() => _taskStateLabel = 'Starting task…');
        }

        // Execute the action (pass aiService for multi-step tasks)
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onApproval: _requestToolApproval,
          userRequest: text.trim(),
          onProgress: (msg) {
            if (msg.contains('budget exhausted') ||
                msg.startsWith('Task paused') ||
                msg.startsWith('Task cancelled') ||
                msg.startsWith('Action denied')) {
              _dismissApproval();
            }
            developer.log('Task progress: $msg', name: 'PrivateAgent');
            _sendOverlayEvent('OVERLAY_PROGRESS', msg);
            if (mounted) {
              setState(() {
                if (msg.startsWith('Task paused')) {
                  _taskStateLabel = 'Paused';
                } else if (msg.startsWith('Task cancelled')) {
                  _taskStateLabel = 'Cancelled';
                } else if (!_stopRequested) {
                  _taskStateLabel = msg;
                }
                _messages.add(
                  ChatMessage(role: 'assistant', content: '⏳ $msg'),
                );
              });
              _scrollToBottom();
            }
          },
        );
        _isTaskExecutorActive = false;
        _dismissApproval();
        if (!mounted) return;

        String finalResponse;

        developer.log(
          'INTERPRETATION START: ${action.action}',
          name: 'PrivateAgent',
        );

        try {
          if (!result.success) {
            finalResponse = result.details ?? 'Task did not complete.';
          } else {
            finalResponse = await _aiService.interpretToolResult(
              userRequest: text.trim(),
              toolName: action.action,
              toolResult: result.details ?? 'Done.',
              cancellationToken: responseCancellation,
            );
          }
        } catch (e) {
          developer.log(
            'Tool result interpretation failed: $e',
            name: 'PrivateAgent',
          );

          finalResponse = result.success
              ? (result.details ?? 'Done.')
              : '? ${result.details ?? 'Unknown error'}';
        }

        setState(() {
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: finalResponse,
              actionResult: result,
            ),
          );
        });
        _sendOverlayEvent('OVERLAY_TASK_FINISHED', finalResponse);
        if (speakActionResponse) {
          unawaited(_speakVoiceResponse(finalResponse));
        }
        if (action.action != 'execute_task') {
          await _notificationService.showTaskCompleteNotification(
            result.success ? 'Task Completed' : 'Task Failed',
            finalResponse,
          );
        }
        await _saveSession();
      } else {
        // Plain text response, we already rendered it, just speak it
        unawaited(_speakVoiceResponse(accumulated));
      }
    } catch (e) {
      if (mounted) {
        if (_stopRequested) {
          showStoppedMessage();
        } else {
          setState(() {
            if (assistantBubbleVisible && assistantIndex < _messages.length) {
              _messages.removeAt(assistantIndex);
            }
            assistantBubbleVisible = false;
            _messages.add(
              ChatMessage(
                role: 'assistant',
                content: 'Error: ${e.toString().replaceFirst('Exception: ', '')}',
              ),
            );
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isTaskExecutorActive = false;
          _stopRequested = false;
          _lastStopWasPause = false;
        });
        _scrollToBottom();
        _updateOverlayState();
      }
      if (identical(_activeResponseCancellation, responseCancellation)) {
        _activeResponseCancellation = null;
      }
    }
  }

  Future<void> _resumeTask(TaskRecord task) async {
    if (_isLoading) return;
    _stopRequested = false;
    _lastStopWasPause = false;
    setState(() {
      _isLoading = true;
      _isTaskExecutorActive = true;
      _taskStateLabel = 'Resuming task...';
    });
    try {
      final result = await _actionHandler.execute(
        AgentAction(
          action: 'execute_task',
          params: {'goal': task.goal, 'resume_task_id': task.identifier},
          response: '',
        ),
        aiService: _aiService,
        onApproval: _requestToolApproval,
        onProgress: (message) {
          if (message.contains('budget exhausted') ||
              message.startsWith('Task paused') ||
              message.startsWith('Task cancelled') ||
              message.startsWith('Action denied')) {
            _dismissApproval();
          }
          if (mounted) {
            setState(
              () {
                if (message.startsWith('Task paused')) {
                  _taskStateLabel = 'Paused';
                } else if (message.startsWith('Task cancelled')) {
                  _taskStateLabel = 'Cancelled';
                } else if (!_stopRequested) {
                  _taskStateLabel = message;
                }
                _messages.add(
                  ChatMessage(role: 'assistant', content: '⏳ $message'),
                );
              },
            );
            _scrollToBottom();
          }
        },
      );
      _dismissApproval();
      if (mounted) {
        setState(
          () => _messages.add(
            ChatMessage(
              role: 'assistant',
              content: result.details ?? 'Task stopped.',
              actionResult: result,
            ),
          ),
        );
        await _saveSession();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isTaskExecutorActive = false;
          _stopRequested = false;
          _lastStopWasPause = false;
        });
      }
    }
  }

  Future<void> _showTaskProgressOverlay(String message) async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;

    // Never cover PrivateAgent itself. The lifecycle observer will create the
    // overlay after an automated action moves this app to the background.
    if (_appLifecycleState != AppLifecycleState.paused) return;

    if (!await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'PrivateAgent',
        overlayContent: 'Performing task...',
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // Keep the overlay minimized during automation. The user can still tap the
    // bubble to open the full conversation whenever they choose.
    _sendOverlayEvent('OVERLAY_TASK_STARTED', message);
  }

  void _sendOverlayEvent(String type, String message) {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final safeMessage = PrivacySanitizer.sanitizeTaskTrace(
      message,
    ).replaceAll('|', ' ');
    unawaited(
      FlutterOverlayWindow.shareData(
        '$type|$safeMessage',
      ).timeout(const Duration(seconds: 2)).catchError((Object _) {}),
    );
  }

  Future<void> _sendOverlayHistorySnapshot() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final history = base64Encode(
      utf8.encode(
        jsonEncode(_messages.map((message) => message.toJson()).toList()),
      ),
    );
    try {
      await FlutterOverlayWindow.shareData(
        'OVERLAY_HISTORY|$history',
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _speakVoiceResponse(String text) async {
    try {
      await _voiceService.speak(text);
    } catch (error) {
      developer.log('Voice output failed: $error', name: 'PrivateAgent');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voice output could not be played.')),
      );
    }
  }

  Future<void> _toggleVoice() async {
    if (_isListening) {
      await _voiceService.stopListening();
      setState(() => _isListening = false);
      return;
    }

    setState(() => _isListening = true);

    final started = await _voiceService.startListening(
      onResult: (text) {
        unawaited(_sendMessage(text, speakActionResponse: true));
      },
      onDone: () {
        if (mounted) {
          setState(() => _isListening = false);
        }
      },
      onError: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    if (!started && mounted && _isListening) {
      setState(() => _isListening = false);
    }
  }

  void _startNewChat() {
    setState(() {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionTitle = '';
      _messages.clear();
      _aiService.clearHistory();
    });
  }

  void _loadChatSession(ChatSession session) {
    setState(() {
      _sessionId = session.id;
      _sessionTitle = session.title;
      _messages.clear();
      for (final m in session.messages) {
        _messages.add(ChatMessage.fromJson(m));
      }

      _aiService.clearHistory();
      for (final m in _messages) {
        if (m.actionResult != null) continue;
        _aiService.addHistoryMessage(m.role, m.content);
      }
    });
    _scrollToBottom();
  }

  @override
  void dispose() {
    _approvalGeneration++;
    _actionHandler.cancelTask();
    WidgetsBinding.instance.removeObserver(this);
    _overlayHistoryTimer?.cancel();
    _assistantInvocationSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _voiceService.dispose();
    _telegramService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _approvalDialogContext != null) {
      _approvalGeneration++;
      _dismissApproval();
    }
    setState(() {
      _appLifecycleState = state;
    });
    if (state == AppLifecycleState.resumed) {
      _startOverlayHistorySync();
      unawaited(_handleAppForegrounded());
    } else {
      _overlayHistoryTimer?.cancel();
      _updateOverlayState();
    }
  }

  void _startOverlayHistorySync() {
    _overlayHistoryTimer?.cancel();
    if (!FeatureFlags.floatingOverlayEnabled) return;
    unawaited(_importOverlayChatHistory());
    _overlayHistoryTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (_appLifecycleState == AppLifecycleState.resumed) {
        unawaited(_importOverlayChatHistory());
      }
    });
  }

  Future<void> _handleAppForegrounded() async {
    await _updateOverlayState();
    await _importOverlayChatHistory();
  }

  Future<void> _importOverlayChatHistory() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (_importingOverlayHistory) return;
    _importingOverlayHistory = true;
    try {
      final handoff = await ChatHistoryService.consumeOverlayMessages();
      if (!mounted || handoff.isEmpty) return;

      final imported = handoff.map(ChatMessage.fromJson).toList();
      for (final message in imported) {
        if (message.actionResult == null) {
          _aiService.addHistoryMessage(message.role, message.content);
        }
      }
      setState(() {
        _messages.addAll(imported);
      });
      _scrollToBottom();
      await _saveSession();
    } finally {
      _importingOverlayHistory = false;
    }
  }

  int _overlayUpdateGeneration = 0;
  bool _importingOverlayHistory = false;

  Future<void> _updateOverlayState() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final generation = ++_overlayUpdateGeneration;
    final isBackground = _appLifecycleState == AppLifecycleState.paused;
    final shouldBeActive = isBackground;

    bool granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted || generation != _overlayUpdateGeneration) return;

    bool active = await FlutterOverlayWindow.isActive();
    if (generation != _overlayUpdateGeneration) return;
    if (shouldBeActive && !active) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState != AppLifecycleState.paused) return;
      if (await FlutterOverlayWindow.isActive()) return;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: "PrivateAgent",
        overlayContent: _isLoading
            ? "Performing task..."
            : "Floating Assistant",
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
        // Give the overlay isolate time to attach its listener, then send the
        // full active conversation. A second snapshot makes cold starts
        // reliable without duplicating messages because the overlay replaces
        // its list atomically.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _sendOverlayHistorySnapshot();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
          await _sendOverlayHistorySnapshot();
        }
      }
    } else if (shouldBeActive && active && _isLoading) {
      await _sendOverlayHistorySnapshot();
    } else if (!shouldBeActive && active) {
      try {
        await FlutterOverlayWindow.shareData(
          'OVERLAY_RESET|',
        ).timeout(const Duration(milliseconds: 150));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState == AppLifecycleState.paused) return;
      await FlutterOverlayWindow.closeOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0C0A15)
          : const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 20,
              color: isDark ? Colors.white : const Color(0xFF1E293B),
            ),
            children: [
              TextSpan(
                text: 'Private',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: -0.5,
                ),
              ),
              const TextSpan(
                text: 'Agent',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: _isLoading ? null : _startNewChat,
          ),
          // Settings Action
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
              await _actionHandler.shizuku.checkAvailability();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      drawer: _buildDrawer(context, isDark),
      body: Stack(
        children: [
          // Background mesh glows
          _buildBackgroundGlows(isDark),

          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(color: Colors.transparent),
            ),
          ),

          Column(
            children: [
              // Pill selector switcher
              _buildModeSelector(isDark),

              // API key warning banner
              if (!_aiService.isConfigured)
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.orangeAccent.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'API not configured. Tap Settings to add details.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SettingsScreen(
                                aiService: _aiService,
                                shizukuService: _actionHandler.shizuku,
                                screenAutomationService:
                                    _actionHandler.screenAutomation,
                                telegramService: _telegramService,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        child: const Text('Configure'),
                      ),
                    ],
                  ),
                ),

              // Chat content area
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(isDark)
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          return MessageBubble(message: _messages[index]);
                        },
                      ),
              ),

              // Think loading indicator
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.indigoAccent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _taskStateLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFF9E9BAC)
                                : const Color(0xFF6C6A7C),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_isTaskExecutorActive)
                        TextButton.icon(
                          onPressed: _stopRequested
                              ? null
                              : () => _stopActiveTask(pause: true),
                          icon: const Icon(
                            Icons.pause_circle_outline,
                            size: 16,
                          ),
                          label: const Text('Pause'),
                        ),
                      TextButton.icon(
                        onPressed: _stopRequested
                            ? null
                            : () => _stopActiveTask(pause: false),
                        icon: const Icon(
                          Icons.stop_circle_rounded,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        label: Text(
                          _stopRequested ? 'Stopping…' : 'Stop',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),

              // Custom Input bar
              _buildInputBar(isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context, bool isDark) {
    final drawerBg = isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC);
    final textStyle = TextStyle(
      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
      fontWeight: FontWeight.w600,
      fontSize: 13.5,
    );
    final headerStyle = TextStyle(
      color: isDark ? Colors.white : const Color(0xFF1E293B),
      fontSize: 17,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
    );

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          // Drawer Header
          Container(
            padding: const EdgeInsets.only(
              top: 60,
              bottom: 20,
              left: 24,
              right: 24,
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_rounded,
                  color: Theme.of(context).primaryColor,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Text('PrivateAgent', style: headerStyle),
              ],
            ),
          ),

          // New Chat Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.pop(context); // Close drawer
                    _startNewChat();
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_comment_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'New Chat',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          // Section CHAT HISTORY
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'CHAT HISTORY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).primaryColor,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),

          // Chat Sessions List
          Expanded(
            child: FutureBuilder<List<ChatSession>>(
              future: ChatHistoryService.loadSessions(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Center(
                    child: Text(
                      'No recent chats',
                      style: TextStyle(
                        color: isDark ? Colors.grey[800] : Colors.grey[400],
                        fontSize: 12,
                      ),
                    ),
                  );
                }

                final sessions = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isCurrent = session.id == _sessionId;

                    return Container(
                      margin: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? Theme.of(
                                context,
                              ).colorScheme.primary.withOpacity(0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isCurrent
                            ? Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withOpacity(0.15),
                              )
                            : null,
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 0,
                        ),
                        dense: true,
                        leading: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 15,
                          color: isCurrent
                              ? Theme.of(context).colorScheme.primary
                              : (isDark ? Colors.grey[600] : Colors.grey[500]),
                        ),
                        title: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle.copyWith(
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isCurrent
                                ? (isDark
                                      ? Colors.white
                                      : const Color(0xFF1E293B))
                                : null,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: Colors.redAccent.withOpacity(0.7),
                          ),
                          onPressed: () async {
                            await ChatHistoryService.deleteSession(session.id);
                            if (isCurrent) {
                              _startNewChat();
                            }
                            (context as Element)
                                .markNeedsBuild(); // Re-trigger build refresh
                          },
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _loadChatSession(session);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          // Section TASKS & SETTINGS
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.history_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Task History', style: textStyle),
            onTap: () async {
              Navigator.pop(context);
              final task = await Navigator.push<TaskRecord>(
                context,
                MaterialPageRoute(builder: (_) => const TaskHistoryScreen()),
              );
              if (task != null && mounted) await _resumeTask(task);
            },
          ),
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.settings_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Settings', style: textStyle),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBackgroundGlows(bool isDark) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            top: -150,
            left: -50,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0.24)
                        : const Color(0xFF4F46E5).withOpacity(0.12),
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0)
                        : const Color(0xFF4F46E5).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 50,
            right: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0.18)
                        : const Color(0xFF0EA5E9).withOpacity(0.09),
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0)
                        : const Color(0xFF0EA5E9).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector(bool isDark) {
    final activeBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: activeBg,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.06),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModeButton(
              'chat',
              'Chat',
              Icons.chat_bubble_outline_rounded,
              isDark,
            ),
            _buildModeButton(
              'agent',
              'Agent',
              Icons.smart_toy_outlined,
              isDark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton(
    String modeId,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _mode == modeId;

    return GestureDetector(
      onTap: () {
        setState(() {
          _mode = modeId;
        });
        SharedPreferences.getInstance().then(
          (prefs) => prefs.setString('interaction_mode', modeId),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? Colors.white
                  : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569)),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : (isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF475569)),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final time = DateTime.now();
    String timeGreeting = 'Hello';
    if (time.hour >= 5 && time.hour < 12) {
      timeGreeting = 'Hello, good morning.';
    } else if (time.hour >= 12 && time.hour < 17) {
      timeGreeting = 'Hello, good afternoon.';
    } else if (time.hour >= 17 && time.hour < 22) {
      timeGreeting = 'Hello, good evening.';
    } else {
      timeGreeting = 'Hello.';
    }

    final suggestions = _mode == 'chat'
        ? [
            'Write a professional email',
            'Explain quantum computing simply',
            'Brainstorm mobile app ideas',
            'Write a poem about robots',
          ]
        : [
            'Open YouTube and search for cats',
            'Call Mom',
            'Set volume to 80%',
            'What\'s on my screen?',
          ];

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    timeGreeting,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                      letterSpacing: -1.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'How can I help you?',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: -1.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SUGGESTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569),
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = suggestions[index];
                  return Container(
                    margin: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      onTap: () => _sendMessage(suggestion),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF151D30)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF243049).withOpacity(0.4)
                                : const Color(0xFFE2E8F0),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(
                                isDark ? 0.1 : 0.02,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            suggestion,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFFF8FAFC)
                                  : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          // Glowing Voice Mic button
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isListening
                  ? Colors.redAccent
                  : Theme.of(context).cardTheme.color,
              border: Border.all(
                color: _isListening
                    ? Colors.redAccent
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
                if (_isListening)
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
              ],
            ),
            child: IconButton(
              icon: Icon(
                _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: _isListening
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
              onPressed: _isLoading ? null : _toggleVoice,
            ),
          ),
          const SizedBox(width: 10),

          // Custom Text input container
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.08),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: _isListening
                            ? 'Listening...'
                            : 'Type a command...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey[600] : Colors.grey[400],
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        border: InputBorder.none,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _isLoading
                          ? null
                          : (text) => _sendMessage(text),
                    ),
                  ),

                  // Solid Send button
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.send_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      onPressed: _isLoading
                          ? null
                          : () => _sendMessage(_textController.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
