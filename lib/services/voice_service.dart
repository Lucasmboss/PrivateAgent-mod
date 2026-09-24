import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  static const MethodChannel _nativeChannel = MethodChannel(
    'com.privateagent/native_voice',
  );
  static const EventChannel _nativeEvents = EventChannel(
    'com.privateagent/native_voice_events',
  );

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isListening = false;
  bool _nativeSpeechAvailable = false;
  bool _nativeTtsAvailable = false;
  bool _speechPluginInitialized = false;
  int _listenGeneration = 0;
  StreamSubscription<dynamic>? _nativeSubscription;
  Function(String)? _nativeResult;
  Function()? _nativeDone;
  Function(String)? _nativeError;

  bool get isListening => _isListening;

  Future<void> init() async {
    if (_isInitialized) return;

    if (Platform.isAndroid) {
      _nativeSubscription = _nativeEvents.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (_) {
          _nativeSpeechAvailable = false;
          _nativeTtsAvailable = false;
          _finishListening(error: 'Voice service connection failed.');
        },
      );
      try {
        final result = await _nativeChannel.invokeMethod<Map<dynamic, dynamic>>(
          'initialize',
        );
        _nativeSpeechAvailable = result?['speechAvailable'] == true;
        _nativeTtsAvailable = result?['ttsInstalled'] == true;
      } on PlatformException {
        _nativeSpeechAvailable = false;
        _nativeTtsAvailable = false;
      }
    }

    try {
      await _tts.setLanguage('es-AR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {
      // Keep recognition usable if the compatibility TTS engine is unavailable.
    }
    _isInitialized = true;
  }

  /// Start listening for speech. Returns transcribed text via callback.
  Future<bool> startListening({
    required Function(String) onResult,
    required Function() onDone,
    required Function(String) onError,
  }) async {
    final generation = ++_listenGeneration;
    _nativeResult = onResult;
    _nativeDone = onDone;
    _nativeError = onError;
    _isListening = true;
    try {
      if (!_isInitialized) await init();
    } catch (_) {
      _finishListening(
        generation: generation,
        error: 'Voice services could not be initialized.',
      );
      return false;
    }

    if (Platform.isAndroid) {
      PermissionStatus microphonePermission;
      try {
        microphonePermission = await Permission.microphone.request();
      } catch (_) {
        _finishListening(
          generation: generation,
          error: 'Could not request microphone permission.',
        );
        return false;
      }
      if (generation != _listenGeneration) return false;
      if (!microphonePermission.isGranted) {
        _finishListening(
          generation: generation,
          error: microphonePermission.isPermanentlyDenied
              ? 'Microphone access is blocked. Enable it in Android Settings.'
              : 'Microphone permission is required for voice input.',
        );
        return false;
      }
    }

    if (_nativeSpeechAvailable) {
      try {
        final started = await _nativeChannel.invokeMethod<bool>(
          'startListening',
          {'language': 'es-AR'},
        );
        if (generation != _listenGeneration) return false;
        if (started == true) return true;
      } on PlatformException {
        _nativeSpeechAvailable = false;
      }
    }
    if (generation != _listenGeneration) return false;

    try {
      if (!_speechPluginInitialized) {
        _speechPluginInitialized = await _speech.initialize(
          onError: (error) {
            _finishListening(
              generation: _listenGeneration,
              error: error.errorMsg,
            );
          },
        );
      }
      if (generation != _listenGeneration) return false;
      if (!_speechPluginInitialized) {
        _finishListening(
          generation: generation,
          error: 'Speech recognition is unavailable on this device.',
        );
        return false;
      }

      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          if (generation != _listenGeneration || !result.finalResult) return;
          if (result.recognizedWords.isNotEmpty) {
            onResult(result.recognizedWords);
          }
          _finishListening(generation: generation);
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.confirmation,
          partialResults: false,
        ),
      );
      return true;
    } catch (_) {
      _finishListening(
        generation: generation,
        error: 'Could not start speech recognition.',
      );
      return false;
    }
  }

  /// Stop listening
  Future<void> stopListening() async {
    ++_listenGeneration;
    final onDone = _nativeDone;
    _isListening = false;
    _nativeResult = null;
    _nativeDone = null;
    _nativeError = null;
    if (_nativeSpeechAvailable) {
      try {
        await _nativeChannel.invokeMethod('stopListening');
      } catch (_) {
        // The native engine may already have ended the recognition session.
      }
    }
    if (_speechPluginInitialized) {
      try {
        await _speech.stop();
      } catch (_) {
        // The fallback recognizer may already be idle.
      }
    }
    onDone?.call();
  }

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    if (_nativeTtsAvailable) {
      try {
        final started = await _nativeChannel.invokeMethod<bool>('speak', {
          'text': text,
          'language': 'es-AR',
        });
        if (started == true) return;
      } catch (_) {
        // Fall back to Flutter TTS if the Google engine is unavailable.
      }
    }
    await _tts.speak(text);
  }

  /// Stop speaking
  Future<void> stopSpeaking() async {
    if (_nativeTtsAvailable) {
      try {
        await _nativeChannel.invokeMethod('stopSpeaking');
      } catch (_) {
        // Nothing to stop if native TTS is already idle.
      }
    }
    await _tts.stop();
  }

  void dispose() {
    ++_listenGeneration;
    _isListening = false;
    _nativeSubscription?.cancel();
    _nativeResult = null;
    _nativeDone = null;
    _nativeError = null;
    if (_nativeSpeechAvailable) {
      unawaited(
        _nativeChannel
            .invokeMethod('stopListening')
            .catchError((Object _) {}),
      );
    }
    if (_nativeTtsAvailable) {
      unawaited(
        _nativeChannel
            .invokeMethod('stopSpeaking')
            .catchError((Object _) {}),
      );
    }
    if (_speechPluginInitialized) _speech.stop();
    _tts.stop();
  }

  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final type = rawEvent['type']?.toString();
    if (type == 'final') {
      final text = rawEvent['text']?.toString() ?? '';
      if (text.isNotEmpty) _nativeResult?.call(text);
      _finishListening();
    } else if (type == 'stopped') {
      _finishListening();
    } else if (type == 'error') {
      final code = rawEvent['code']?.toString() ?? '';
      if (!code.startsWith('tts_')) {
        _finishListening(
          error: rawEvent['message']?.toString() ??
              'Speech recognition failed.',
        );
      }
    }
  }

  void _finishListening({int? generation, String? error}) {
    if (generation != null && generation != _listenGeneration) return;
    _isListening = false;
    final onDone = _nativeDone;
    final onError = _nativeError;
    _nativeResult = null;
    _nativeDone = null;
    _nativeError = null;
    if (error != null) onError?.call(error);
    onDone?.call();
  }
}
