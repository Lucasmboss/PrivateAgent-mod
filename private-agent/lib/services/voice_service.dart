import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  StreamSubscription<dynamic>? _nativeSubscription;
  Function(String)? _nativeResult;
  Function()? _nativeDone;

  bool get isListening => _isListening;

  Future<void> init() async {
    if (_isInitialized) return;

    if (Platform.isAndroid) {
      _nativeSubscription = _nativeEvents.receiveBroadcastStream().listen(
        _handleNativeEvent,
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

    if (!_nativeSpeechAvailable) {
      _isInitialized = await _speech.initialize(
        onError: (error) {
          _isListening = false;
        },
      );
    } else {
      _isInitialized = true;
    }

    // Keep the existing plugin configured as a compatibility fallback even
    // when Google TTS is installed but still warming up.
    await _tts.setLanguage('es-AR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Start listening for speech. Returns transcribed text via callback.
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return;

    if (_nativeSpeechAvailable) {
      _nativeResult = onResult;
      _nativeDone = onDone;
      try {
        final started = await _nativeChannel.invokeMethod<bool>(
          'startListening',
          {'language': 'es-AR'},
        );
        if (started == true) {
          _isListening = true;
          return;
        }
      } on PlatformException {
        // Fall back to the existing plugin if Google Speech Services refuses
        // to start on this device.
      }
      _nativeResult = null;
      _nativeDone = null;
    }

    _isListening = true;

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          onResult(result.recognizedWords);
          onDone();
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: false,
      ),
    );
  }

  /// Stop listening
  Future<void> stopListening() async {
    _isListening = false;
    if (_nativeSpeechAvailable) {
      try {
        await _nativeChannel.invokeMethod('stopListening');
      } on PlatformException {
        // The native engine may already have ended the recognition session.
      }
      _nativeResult = null;
      _nativeDone = null;
    }
    await _speech.stop();
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
      } on PlatformException {
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
      } on PlatformException {
        // Nothing to stop if native TTS is already idle.
      }
    }
    await _tts.stop();
  }

  void dispose() {
    _nativeSubscription?.cancel();
    if (_nativeSpeechAvailable) {
      unawaited(_nativeChannel.invokeMethod('stopListening'));
    }
    if (_nativeTtsAvailable) {
      unawaited(_nativeChannel.invokeMethod('stopSpeaking'));
    }
    _speech.stop();
    _tts.stop();
  }

  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final type = rawEvent['type']?.toString();
    if (type == 'final') {
      final text = rawEvent['text']?.toString() ?? '';
      _isListening = false;
      if (text.isNotEmpty) _nativeResult?.call(text);
      _nativeDone?.call();
      _nativeResult = null;
      _nativeDone = null;
    } else if (type == 'end' || type == 'stopped') {
      _isListening = false;
      _nativeDone?.call();
      _nativeResult = null;
      _nativeDone = null;
    } else if (type == 'error') {
      _isListening = false;
      _nativeDone?.call();
      _nativeResult = null;
      _nativeDone = null;
    }
  }
}
