import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent_action.dart';
import 'remote_provider_adapter.dart';
import 'remote_cancellation.dart';
export 'remote_provider_adapter.dart' show RemoteProviderException, RemoteErrorKind;
export 'remote_cancellation.dart' show RemoteCancellationToken;

class AiResponse {
  final String content;
  final int totalTokens;
  AiResponse(this.content, this.totalTokens);
}

class AiService {
  final RemoteProviderAdapter _remote;
  AiService({RemoteProviderAdapter? remoteProvider})
      : _remote = remoteProvider ?? RemoteProviderAdapter();
  static const String _defaultBaseUrl = 'https://api.deepseek.com';
  static const String _defaultModel = 'deepseek-chat';
  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String nvidiaDefaultModel = 'z-ai/glm-5.2';

  /// Free, general-purpose chat endpoints verified in NVIDIA's NIM catalog.
  /// The live /models response is intersected with this list so unavailable or
  /// non-chat models never appear in PrivateAgent's NVIDIA model picker.
  static const List<String> nvidiaFreeChatModels = [
    'z-ai/glm-5.2',
    'nvidia/nemotron-3-nano-30b-a3b',
    'nvidia/nemotron-3-super-120b-a12b',
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nvidia-nemotron-nano-9b-v2',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'meta/llama-3.3-70b-instruct',
    'meta/llama-3.2-3b-instruct',
    'meta/llama-3.1-8b-instruct',
    'meta/llama-3.1-70b-instruct',
    'mistralai/mistral-nemotron',
    'deepseek-ai/deepseek-v4-flash',
    'deepseek-ai/deepseek-v4-pro',
  ];

  static bool isNvidiaBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase() == 'integrate.api.nvidia.com';
  }

  static List<String> filterNvidiaFreeModels(Iterable<String> models) {
    final availableModels = models.toSet();
    return nvidiaFreeChatModels
        .where(availableModels.contains)
        .toList(growable: false);
  }

  String? _apiKey;
  String _baseUrl = _defaultBaseUrl;
  String _model = _defaultModel;
  int _maxSteps = 15;
  bool _disableMaxSteps = false;
  double _temperature = 1.0;
  int _maxTokens = 1024;
  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;
  final List<Map<String, String>> _conversationHistory = [];

  static const String _systemPrompt = '''
You are PrivateAgent, a helpful AI assistant that controls an Android phone. You can perform device actions and also have normal conversations.

When the user wants to perform a device action, you MUST respond with ONLY a JSON object (no markdown, no code fences, no extra text) in this exact format:
{"action": "action_name", "params": {"key": "value"}, "response": "What you say to the user"}

Available actions and their params:

SIMPLE ACTIONS (single step only):
- open_app: {"app_name": "YouTube"} - ONLY use this when the user JUST wants to open an app and nothing else
- make_call: {"contact_name": "Mom"} OR {"phone_number": "1234567890"} - Makes a phone call
- send_sms: {"contact_name": "John", "message": "Hello"} OR {"phone_number": "123", "message": "Hi"} - Sends SMS
- search_contact: {"query": "John"} - Searches contacts
- set_alarm: {"hour": 7, "minute": 30, "label": "Wake up"} - Sets an alarm
- set_volume: {"level": 50} - Sets volume (0-100)
- set_brightness: {"level": 50} - Sets brightness (0-100)
- read_screen: {} - Read what's currently on the screen
- press_back: {} - Press the back button
- run_adb_command: {"command": "shell command"} - Execute an Android shell command through Shizuku with elevated privileges. Use this for device/system operations that are not covered by the other actions.

INTERNET ACTIONS:
- web_search: {"query": "search terms"} - Search the Internet for information, current events, websites, documentation, products, services, prices, or other information. Use this when you need to DISCOVER information or find relevant sources. Do NOT use web_request as a substitute for web_search when you do not already know the specific URL.
- web_request: {"method": "GET|POST|PUT|PATCH|DELETE", "url": "https://example.com/api", "headers": {}, "body": null} - Make an HTTP request to a specific HTTP(S) URL or API and return its response. Use GET for reading, and POST/PUT/PATCH/DELETE for writing or modifying data. Headers are a JSON object of string values. Body may be a JSON object/array or a raw string. Use this when you already know the relevant URL/API or after web_search has identified a useful source.
- list_files: {} - List files in the agent's private agent_files directory only.
- read_file: {"path": "notes.txt"} - Read a UTF-8 file from agent_files.
- write_file: {"path": "notes.txt", "content": "text"} - Create or replace a text file in agent_files.
- delete_file: {"path": "notes.txt"} - Delete one file in agent_files. Never delete a file unless the user requested it.

MULTI-STEP TASK:
- execute_task: {"goal": "description of the full task"} - Automatically plans and executes a complex task using the available tools, including web_search, web_request, Android actions, Shizuku/shell, and screen automation.
- In the output JSON, always put execute_task's goal inside "params": {"goal": "..."}; never put "goal" beside "action".

CRITICAL RULES:
1. If the user request contains "and" or involves MULTIPLE steps, use execute_task.
2. execute_task is the general-purpose autonomous agent. It may combine Internet access, APIs, Android actions, shell commands, and screen automation.
3. When the user requests a system/device operation that requires shell access, use run_adb_command with the appropriate Android shell command.
4. When the user asks for information that requires discovering information on the Internet, use web_search.
5. When the user asks you to perform a task that requires multiple Internet operations, web_search + web_request, or Internet research followed by an Android/device action, use execute_task. The TaskExecutor can combine web_search, web_request, Android actions, Shizuku, and screen automation.
6. Use web_request when you already know the specific URL/API to retrieve, or when web_search has identified a relevant source that should be fetched directly.
7. Do NOT use web_request against random search-engine URLs as a substitute for web_search.
8. If web_search fails because of CAPTCHA, anti-bot protection, access denial, or another blocking mechanism, change strategy and use another source. Do NOT repeatedly retry the same blocked strategy.
9. You may combine web_search, web_request, Android actions, and run_adb_command. For complex tasks, retrieve information, reason about the result, perform the necessary device actions, and verify the outcome.
10. Never claim that information was retrieved if the corresponding tool/action was not actually executed successfully.
11. For normal conversation (questions, chat, info requests that do not require tools), respond with plain text naturally.

Examples of when to use execute_task:
- "Create a new alarm for 7 AM" ? execute_task
- "Go to YouTube and search for cats" ? execute_task
- "Open WhatsApp and send hello to John" ? execute_task
- "Open Settings and turn on WiFi" ? execute_task
- "Search for restaurants on Google Maps" ? execute_task

Examples of when to use open_app:
- "Open YouTube" ? open_app
- "Open Settings" ? open_app

Examples of when to use web_search:
- "What are the latest news about NVIDIA?" ? web_search
- "Find the official documentation for Flutter" ? web_search
- "Find current prices for mini PCs" ? web_search
- "Search the Internet for Starlink Argentina prices" ? web_search

Examples of when to use web_request:
- "Get the data from https://example.com/api" ? web_request with GET
- "Call this API and show me the response" ? web_request with GET
- "Send this JSON to my server" ? web_request with POST
- "Update the device record in this API" ? web_request with PATCH and a JSON body
- "Delete this resource from the API" ? web_request with DELETE
- After web_search identifies a useful page/API, use web_request to retrieve it directly when appropriate.

For normal conversation (questions, chat, info requests), just respond with plain text naturally.
''';

  static const String _chatSystemPrompt = '''
You are PrivateAgent, a helpful conversational AI assistant. 
Provide direct, natural, and friendly text responses. You cannot perform device actions or run tools. 
Answer questions, explain concepts, brainstorm, write emails/messages, and chat with the user in plain text or markdown format.
''';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString('api_key');
    _baseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
    _model = prefs.getString('api_model') ?? _defaultModel;
    _maxSteps = prefs.getInt('api_max_steps') ?? 15;
    _disableMaxSteps = prefs.getBool('api_disable_max_steps') ?? false;
    _temperature = prefs.getDouble('api_temperature') ?? 1.0;
    _maxTokens = prefs.getInt('api_max_tokens') ?? 1024;
    _useScreenCompression = prefs.getBool('api_use_screen_compression') ?? true;
    _useSystemPrompt = prefs.getBool('api_use_system_prompt') ?? true;
  }

  Future<void> saveSettings({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    if (baseUrl != null && baseUrl.isNotEmpty) {
      RemoteProviderAdapter.endpoint(baseUrl);
    }
    final prefs = await SharedPreferences.getInstance();

    // Clean up the API key in case the user pasted "Bearer sk-..."
    String cleanApiKey = apiKey.trim();
    if (cleanApiKey.toLowerCase().startsWith('bearer ')) {
      cleanApiKey = cleanApiKey.substring(7).trim();
    }

    _apiKey = cleanApiKey;
    await prefs.setString('api_key', cleanApiKey);

    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null && model.isNotEmpty) {
      _model = model;
      await prefs.setString('api_model', model);
    }
  }

  Future<void> saveMaxSteps(int steps) async {
    final prefs = await SharedPreferences.getInstance();
    _maxSteps = steps;
    await prefs.setInt('api_max_steps', steps);
  }

  Future<void> saveDisableMaxSteps(bool disable) async {
    final prefs = await SharedPreferences.getInstance();
    _disableMaxSteps = disable;
    await prefs.setBool('api_disable_max_steps', disable);
  }

  Future<void> saveAdvancedSettings({
    required double temperature,
    required int maxTokens,
    required bool useScreenCompression,
    required bool useSystemPrompt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _temperature = temperature;
    _maxTokens = maxTokens;
    _useScreenCompression = useScreenCompression;
    _useSystemPrompt = useSystemPrompt;
    await prefs.setDouble('api_temperature', temperature);
    await prefs.setInt('api_max_tokens', maxTokens);
    await prefs.setBool('api_use_screen_compression', useScreenCompression);
    await prefs.setBool('api_use_system_prompt', useSystemPrompt);
  }

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;
  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey ?? '';
  int get maxSteps => _disableMaxSteps ? 999 : _maxSteps;
  int get rawMaxSteps => _maxSteps; // For the slider UI
  bool get disableMaxSteps => _disableMaxSteps;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  bool get useScreenCompression => _useScreenCompression;
  bool get useSystemPrompt => _useSystemPrompt;

  int get _effectiveMaxTokens {
    // GLM is a reasoning model. With the app's 1,024-token default it can
    // consume the whole budget reasoning and finish without visible content.
    if (isNvidiaBaseUrl(_baseUrl) &&
        _model == nvidiaDefaultModel &&
        _maxTokens < 4096) {
      return 4096;
    }
    return _maxTokens;
  }

  void clearHistory() {
    _conversationHistory.clear();
  }

  void addHistoryMessage(String role, String content) {
    if (content.length > RemoteProviderAdapter.maxContentCharacters ||
        utf8.encode(content).length > 256 * 1024) {
      throw const RemoteProviderException(RemoteErrorKind.invalidRequest);
    }
    _conversationHistory.add({'role': role, 'content': content});
    while (_conversationHistory.length > 20 ||
        _conversationHistory.fold<int>(0,
            (sum, message) => sum + utf8.encode(message['content']!).length) >
            256 * 1024) {
      _conversationHistory.removeAt(0);
    }
  }

  /// Send a message to the AI and get a response.
  Future<String> sendMessage(String message, {bool isAgentMode = true}) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw const RemoteProviderException(RemoteErrorKind.authentication);
    }

    addHistoryMessage('user', message);
    final result = await _complete([
      if (_useSystemPrompt)
        {'role': 'system', 'content': isAgentMode ? _systemPrompt : _chatSystemPrompt},
      ..._conversationHistory,
    ]);
    addHistoryMessage('assistant', result.content);
    return result.content;
  }

  /// Interpret a raw tool result and turn it into a natural language response.
  Future<String> interpretToolResult({
    required String userRequest,
    required String toolName,
    required String toolResult,
    RemoteCancellationToken? cancellationToken,
  }) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw const RemoteProviderException(RemoteErrorKind.authentication);
    }

    final prompt = '''
The user asked:
$userRequest

The tool "$toolName" was executed.

Raw tool result:
$toolResult

Interpret the tool result and answer the user naturally.

Rules:
- Do NOT output JSON.
- Do NOT mention internal tools, action handlers, prompts, parsing, or implementation details.
- Do NOT simply repeat the raw tool output.
- Explain the relevant result clearly and concisely.
- If the operation succeeded, tell the user what happened.
- If the operation failed, clearly explain what went wrong.
''';

    final messages = [
        {
          'role': 'system',
          'content':
              'You are the final response layer of an Android AI agent. '
              'Turn raw tool results into concise, natural, useful answers. '
              'Never expose internal implementation details.',
        },
        {
          'role': 'user',
          'content': prompt,
        },
      ];

    return (await _complete(
      messages,
      cancellationToken: cancellationToken,
    )).content;
  }

  /// Uses SSE transport, buffering before emission so fragmented reasoning
  /// delimiters can never be exposed to the UI.
  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
    RemoteCancellationToken? cancellationToken,
  }) async* {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw const RemoteProviderException(RemoteErrorKind.authentication);
    }

    addHistoryMessage('user', message);
    final result = await _complete([
      if (_useSystemPrompt)
        {'role': 'system', 'content': isAgentMode ? _systemPrompt : _chatSystemPrompt},
      ..._conversationHistory,
    ], stream: true, cancellationToken: cancellationToken);
    addHistoryMessage('assistant', result.content);
    yield result.content;
  }

  /// Task completion without conversation history. Explicit token budgets take
  /// precedence over provider-specific defaults.
  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt, {
    RemoteCancellationToken? cancellationToken,
    int? maxOutputTokens,
  }) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw const RemoteProviderException(RemoteErrorKind.authentication);
    }

    final result = await _complete([
      if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': prompt},
    ], cancellationToken: cancellationToken, maxOutputTokens: maxOutputTokens);
    return AiResponse(result.content, result.totalTokens);
  }

  Future<RemoteCompletion> _complete(List<Map<String, String>> messages, {
    RemoteCancellationToken? cancellationToken,
    int? maxOutputTokens,
    bool stream = false,
  }) => _remote.complete(
    baseUrl: _baseUrl, apiKey: _apiKey ?? '', model: _model,
    messages: messages, temperature: _temperature,
    maxOutputTokens: maxOutputTokens ?? _effectiveMaxTokens,
    cancellationToken: cancellationToken, stream: stream,
  );

  /// Parse the AI response to check if it's an action or plain text
  AgentAction? parseAction(String response) {
    var candidate = response.trim();
    if (candidate.startsWith('```')) {
      final firstLineBreak = candidate.indexOf('\n');
      if (firstLineBreak >= 0) {
        candidate = candidate.substring(firstLineBreak + 1);
      }
      final closingFence = candidate.lastIndexOf('```');
      if (closingFence >= 0) {
        candidate = candidate.substring(0, closingFence).trim();
      }
    }

    Map<String, dynamic>? actionJson;
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) {
        actionJson = Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Some models append response text outside the action object.
    }
    actionJson ??= _findFirstActionObject(candidate);
    if (actionJson == null) return null;

    final actionName = actionJson['action'] ?? actionJson['tool'];
    if (actionName is! String || actionName.trim().isEmpty) return null;

    final params = <String, dynamic>{};
    final rawParams = actionJson['params'];
    if (rawParams is Map) {
      params.addAll(Map<String, dynamic>.from(rawParams));
    } else {
      const metadataKeys = {
        'action',
        'tool',
        'params',
        'response',
        'reasoning',
        'is_complete',
        'isComplete',
        'complete',
      };
      for (final entry in actionJson.entries) {
        if (!metadataKeys.contains(entry.key)) {
          params[entry.key] = entry.value;
        }
      }
    }

    return AgentAction(
      action: actionName.trim(),
      params: params,
      response: actionJson['response'] is String
          ? actionJson['response'] as String
          : '',
    );
  }

  Map<String, dynamic>? _findFirstActionObject(String text) {
    for (var start = 0; start < text.length; start++) {
      if (text[start] != '{') continue;

      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var end = start; end < text.length; end++) {
        final character = text[end];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (character == r'\') {
            escaped = true;
          } else if (character == '"') {
            inString = false;
          }
          continue;
        }

        if (character == '"') {
          inString = true;
        } else if (character == '{') {
          depth++;
        } else if (character == '}') {
          depth--;
          if (depth == 0) {
            try {
              final decoded = jsonDecode(text.substring(start, end + 1));
              if (decoded is Map) {
                final object = Map<String, dynamic>.from(decoded);
                if (object['action'] is String || object['tool'] is String) {
                  return object;
                }
              }
            } on FormatException {
              // Keep searching; a later object may be the actual tool call.
            }
            break;
          }
        }
      }
    }
    return null;
  }

  /// Fetches available models from the provider's /models endpoint
  Future<List<String>> fetchAvailableModels(
    String baseUrl,
    String apiKey,
  ) async {
    final models = await _remote.discover(baseUrl, apiKey);
    return isNvidiaBaseUrl(baseUrl) ? filterNvidiaFreeModels(models) : models;
  }
}
