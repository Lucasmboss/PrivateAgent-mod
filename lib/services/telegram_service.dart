import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import '../privacy_sanitizer.dart';

class TelegramService {
  final ActionHandler _actionHandler;
  final AiService _aiService;
  
  String _botToken = '';
  String _allowedChatId = '';
  bool _handlingMessage = false;
  bool _isEnabled = false;
  int _lastUpdateId = 0;
  bool _isPolling = false;
  Timer? _pollingTimer;

  TelegramService(this._actionHandler, this._aiService);

  String get botToken => _botToken;
  bool get isEnabled => _isEnabled;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString('telegram_bot_token') ?? '';
    _isEnabled = prefs.getBool('telegram_enabled') ?? false;
    _allowedChatId = prefs.getString('telegram_allowed_chat_id')?.trim() ?? '';

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    }
  }

  Future<void> saveSettings({required String botToken, required bool isEnabled,
      String? allowedChatId}) async {
    _botToken = botToken;
    _isEnabled = isEnabled;
    final prefs = await SharedPreferences.getInstance();
    _allowedChatId = allowedChatId?.trim() ??
        prefs.getString('telegram_allowed_chat_id')?.trim() ?? '';
    if (allowedChatId != null) {
      await prefs.setString('telegram_allowed_chat_id', _allowedChatId);
    }
    await prefs.setString('telegram_bot_token', _botToken);
    await prefs.setBool('telegram_enabled', _isEnabled);

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    } else {
      stopPolling();
    }
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _pollUpdates();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
  }

  Future<void> _pollUpdates() async {
    if (!_isPolling || _botToken.isEmpty) return;

    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/getUpdates');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'offset': _lastUpdateId + 1,
          'timeout': 30, // Long polling timeout
          'allowed_updates': ['message'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final results = data['result'] as List;
          for (final update in results) {
            _lastUpdateId = update['update_id'];
            if (update['message'] != null && update['message']['text'] != null) {
              final text = update['message']['text'];
              final chatId = update['message']['chat']['id'];
              
              // Process message asynchronously so we don't block the polling loop
              _handleIncomingMessage(chatId.toString(), text);
            }
          }
        }
      }
    } catch (e) {
      print('Telegram polling failed.');
    }

    // Continue polling
    if (_isPolling) {
      _pollingTimer = Timer(const Duration(seconds: 1), _pollUpdates);
    }
  }

  Future<void> _handleIncomingMessage(String chatId, String text) async {
    // Never enroll a caller automatically. Re-read explicit settings so revoking
    // access applies to subsequent messages without restarting polling.
    final prefs = await SharedPreferences.getInstance();
    _allowedChatId = prefs.getString('telegram_allowed_chat_id')?.trim() ?? '';
    if (!isAuthorizedChat(chatId, _allowedChatId) || !_isEnabled || _handlingMessage) return;
    _handlingMessage = true;
    // Acknowledge receipt
    await _sendMessage(chatId, '🤖 Received: "$text". Working on it...');

    try {
      // 1. Send text to AI
      final aiResponse = await _aiService.sendMessage(text);
      final current = await SharedPreferences.getInstance();
      _allowedChatId = current.getString('telegram_allowed_chat_id')?.trim() ?? '';
      if (!_isEnabled || !isAuthorizedChat(chatId, _allowedChatId)) return;
      
      // 2. Parse the action
      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        // 3. Execute the action
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          // Telegram text is not a trustworthy interactive approval channel.
          onApproval: (_) async => false,
          onProgress: (msg) {
            // Send progress updates back to telegram
            _sendMessage(chatId, '⏳ $msg');
          },
        );
        await _sendMessage(chatId, '${result.success ? '✅' : '⛔'} ${result.details ?? "Stopped"}');
      } else {
        // It's a plain text response
        await _sendMessage(chatId, '💬 $aiResponse');
      }
    } catch (e) {
      await _sendMessage(chatId, '❌ Request failed.');
    } finally {
      _handlingMessage = false;
    }
  }

  Future<void> _sendMessage(String chatId, String text) async {
    final prefs = await SharedPreferences.getInstance();
    _allowedChatId = prefs.getString('telegram_allowed_chat_id')?.trim() ?? '';
    if (_botToken.isEmpty || !isAuthorizedChat(chatId, _allowedChatId)) return;
    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/sendMessage');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': chatId,
          'text': PrivacySanitizer.sanitizeText(text),
        }),
      );
    } catch (e) {
      print('Failed to send Telegram message.');
    }
  }

  void dispose() {
    stopPolling();
  }

  static bool isAuthorizedChat(String chatId, String configuredChatId) =>
      RegExp(r'^-?[0-9]+$').hasMatch(configuredChatId) &&
      configuredChatId.isNotEmpty && chatId == configuredChatId;
}
