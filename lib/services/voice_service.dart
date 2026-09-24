import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';

enum VoicePlaybackState { idle, speaking, paused }

class VoiceService {
  static const String speechOutputPreferenceKey = 'voice_output_enabled';
  static const MethodChannel _nativeChannel = MethodChannel(
    'com.privateagent/native_voice',
  );
  static const EventChannel _nativeEvents = EventChannel(
    'com.privateagent/native_voice_events',
  );

  final stt.SpeechToText _speech = stt.SpeechToText();
  final StreamController<VoicePlaybackState> _playbackEvents =
      StreamController<VoicePlaybackState>.broadcast();
  bool _isInitialized = false;
  bool _isListening = false;
  bool _nativeSpeechAvailable = false;
  bool _nativeTtsAvailable = false;
  bool _nativeTtsReady = false;
  Completer<void>? _nativeTtsReadyCompleter;
  bool _speechPluginInitialized = false;
  bool _nativeListening = false;
  bool _nativeStartPending = false;
  bool _usingNativeSpeech = false;
  bool _pluginListening = false;
  bool _isHoldToTalkSession = false;
  bool _holdToTalk = false;
  int _listenGeneration = 0;
  Timer? _fallbackRestartTimer;
  final List<String> _speechSegments = [];
  String _fallbackCurrentPartial = '';
  StreamSubscription<dynamic>? _nativeSubscription;
  Function(String)? _nativeResult;
  Function(String)? _onPartialResult;
  Function()? _nativeDone;
  Function(String)? _nativeError;
  VoicePlaybackState _playbackState = VoicePlaybackState.idle;

  bool get isListening => _isListening;
  VoicePlaybackState get playbackState => _playbackState;
  Stream<VoicePlaybackState> get playbackEvents => _playbackEvents.stream;

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
        _nativeTtsReady = result?['ttsReady'] == true;
        if (_nativeTtsReady) _completeNativeTtsReady();
        if (_nativeTtsAvailable && !_nativeTtsReady) {
          _nativeTtsReadyCompleter ??= Completer<void>();
        }
      } on PlatformException {
        _nativeSpeechAvailable = false;
        _nativeTtsAvailable = false;
      }
    }

    _isInitialized = true;
  }

  /// Start listening for speech. Returns transcribed text via callback.
  Future<bool> startListening({
    required Function(String) onResult,
    required Function() onDone,
    required Function(String) onError,
    Function(String)? onPartialResult,
    bool holdToTalk = false,
  }) async {
    if (_isListening) return false;
    final generation = ++_listenGeneration;
    _nativeResult = onResult;
    _onPartialResult = onPartialResult;
    _nativeDone = onDone;
    _nativeError = onError;
    _isHoldToTalkSession = holdToTalk;
    _holdToTalk = holdToTalk;
    _speechSegments.clear();
    _fallbackCurrentPartial = '';
    _nativeListening = false;
    _nativeStartPending = false;
    _usingNativeSpeech = false;
    _pluginListening = false;
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
    if (generation != _listenGeneration || !_isListening) return false;
    if (holdToTalk && !_holdToTalk) {
      _finishListening(generation: generation);
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
      if (holdToTalk && !_holdToTalk) {
        _finishListening(generation: generation);
        return false;
      }
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
      bool? started;
      _nativeStartPending = true;
      try {
        started = await _nativeChannel.invokeMethod<bool>('startListening', {
          'language': 'es-AR',
          'holdToTalk': holdToTalk,
        });
      } on PlatformException {
        _nativeSpeechAvailable = false;
      } finally {
        _nativeStartPending = false;
      }
      if (generation != _listenGeneration || !_isListening) return false;
      if (started == true) {
        _usingNativeSpeech = true;
        _nativeListening = true;
        if (_isHoldToTalkSession && !_holdToTalk) {
          unawaited(_nativeChannel.invokeMethod('stopListening'));
        }
        return true;
      }
    }
    if (generation != _listenGeneration || !_isListening) return false;
    if (holdToTalk && !_holdToTalk) {
      _finishListening(generation: generation);
      return false;
    }

    try {
      if (!_speechPluginInitialized) {
        _speechPluginInitialized = await _speech.initialize(
          onError: (error) {
            final activeGeneration = _listenGeneration;
            _pluginListening = false;
            if (_isHoldToTalkSession && _holdToTalk && !error.permanent) {
              _appendSpeechSegment(_fallbackCurrentPartial);
              _fallbackCurrentPartial = '';
              _scheduleFallbackRestart(activeGeneration);
            } else {
              _finishListening(
                generation: activeGeneration,
                error: error.errorMsg,
              );
            }
          },
        );
      }
      if (generation != _listenGeneration || !_isListening) return false;
      if (!_speechPluginInitialized) {
        _finishListening(
          generation: generation,
          error: 'Speech recognition is unavailable on this device.',
        );
        return false;
      }

      _pluginListening = true;
      await _listenWithPlugin(generation);
      if (generation != _listenGeneration || !_isListening) return false;
      if (_isHoldToTalkSession && !_holdToTalk) {
        await stopPushToTalk();
      }
      return true;
    } catch (_) {
      _finishListening(
        generation: generation,
        error: 'Could not start speech recognition.',
      );
      return false;
    }
  }

  Future<void> _listenWithPlugin(int generation) async {
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (generation != _listenGeneration || !_isListening) return;
        final recognizedWords = result.recognizedWords.trim();

        if (_isHoldToTalkSession) {
          if (!result.finalResult) {
            if (recognizedWords.isNotEmpty) {
              _fallbackCurrentPartial = recognizedWords;
              _onPartialResult?.call(_composeFallbackTranscript());
            }
            return;
          }

          _appendSpeechSegment(
            recognizedWords.isNotEmpty
                ? recognizedWords
                : _fallbackCurrentPartial,
          );
          _fallbackCurrentPartial = '';
          _onPartialResult?.call(_composeFallbackTranscript());
          _pluginListening = false;
          if (_holdToTalk) {
            _scheduleFallbackRestart(generation);
          } else {
            _completeHoldToTalk(generation);
          }
          return;
        }

        if (!result.finalResult) {
          if (recognizedWords.isNotEmpty) {
            _onPartialResult?.call(recognizedWords);
          }
          return;
        }

        if (recognizedWords.isNotEmpty) {
          _nativeResult?.call(recognizedWords);
        }
        _finishListening(generation: generation);
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: _isHoldToTalkSession
            ? stt.ListenMode.dictation
            : stt.ListenMode.confirmation,
        partialResults: _isHoldToTalkSession,
      ),
    );
  }

  void _scheduleFallbackRestart(int generation) {
    _fallbackRestartTimer?.cancel();
    _fallbackRestartTimer = Timer(const Duration(milliseconds: 250), () {
      if (generation != _listenGeneration || !_isListening || !_holdToTalk) {
        return;
      }
      unawaited(() async {
        try {
          _pluginListening = true;
          await _listenWithPlugin(generation);
          if (generation != _listenGeneration || !_isListening) return;
          if (!_holdToTalk) await stopPushToTalk();
        } catch (_) {
          _finishListening(
            generation: generation,
            error: 'Could not continue speech recognition.',
          );
        }
      }());
    });
  }

  void _appendSpeechSegment(String text) {
    final segment = text.trim();
    if (segment.isEmpty) return;
    if (_speechSegments.isEmpty || _speechSegments.last != segment) {
      _speechSegments.add(segment);
    }
  }

  String _composeFallbackTranscript() {
    return [
      ..._speechSegments,
      _fallbackCurrentPartial,
    ].map((part) => part.trim()).where((part) => part.isNotEmpty).join(' ');
  }

  void _completeHoldToTalk(int generation) {
    if (generation != _listenGeneration || !_isListening) return;
    final transcript = _composeFallbackTranscript();
    if (transcript.isNotEmpty) _nativeResult?.call(transcript);
    _finishListening(generation: generation);
  }

  /// Stop listening
  Future<void> stopListening() async {
    ++_listenGeneration;
    _fallbackRestartTimer?.cancel();
    _fallbackRestartTimer = null;
    _isHoldToTalkSession = false;
    _holdToTalk = false;
    _nativeListening = false;
    _nativeStartPending = false;
    _usingNativeSpeech = false;
    _pluginListening = false;
    final onDone = _nativeDone;
    _isListening = false;
    _nativeResult = null;
    _onPartialResult = null;
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

  /// End a press-and-hold session and submit its accumulated transcript.
  Future<void> stopPushToTalk() async {
    if (!_isHoldToTalkSession || !_isListening) return;
    _holdToTalk = false;
    _fallbackRestartTimer?.cancel();
    _fallbackRestartTimer = null;
    final generation = _listenGeneration;

    if (_nativeListening) {
      try {
        await _nativeChannel.invokeMethod('stopListening');
      } catch (_) {
        _finishListening(
          generation: generation,
          error: 'Could not finish speech recognition.',
        );
      }
      return;
    }

    if (_nativeStartPending) return;
    if (!_pluginListening) {
      if (!_usingNativeSpeech) _completeHoldToTalk(generation);
      return;
    }
    try {
      await _speech.stop();
    } catch (_) {
      // Use the latest partial transcript if the plugin cannot stop cleanly.
    }
    _pluginListening = false;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _completeHoldToTalk(generation);
  }

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_isInitialized) await init();
    if (!Platform.isAndroid || !_nativeTtsAvailable) {
      throw StateError('Google Text-to-Speech is not available.');
    }
    if (!_nativeTtsReady) {
      final ready = _nativeTtsReadyCompleter ??= Completer<void>();
      await ready.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    if (!_nativeTtsReady) {
      throw StateError('Google Text-to-Speech is not ready.');
    }
    final started = await _nativeChannel.invokeMethod<bool>('speak', {
      'text': text,
      'language': 'es-AR',
    });
    if (started != true) {
      throw StateError('Google Text-to-Speech could not start.');
    }
  }

  Future<void> pauseSpeaking() async {
    if (!_nativeTtsAvailable) return;
    await _nativeChannel.invokeMethod<bool>('pauseSpeaking');
    _setPlaybackState(VoicePlaybackState.paused);
  }

  Future<void> resumeSpeaking() async {
    if (!_nativeTtsAvailable) return;
    final resumed = await _nativeChannel.invokeMethod<bool>('resumeSpeaking');
    if (resumed != true) {
      throw StateError('Google Text-to-Speech could not resume.');
    }
    _setPlaybackState(VoicePlaybackState.speaking);
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
    _setPlaybackState(VoicePlaybackState.idle);
  }

  void dispose() {
    ++_listenGeneration;
    _fallbackRestartTimer?.cancel();
    _fallbackRestartTimer = null;
    _isListening = false;
    _isHoldToTalkSession = false;
    _holdToTalk = false;
    _nativeListening = false;
    _nativeStartPending = false;
    _usingNativeSpeech = false;
    _pluginListening = false;
    _nativeSubscription?.cancel();
    _nativeResult = null;
    _onPartialResult = null;
    _nativeDone = null;
    _nativeError = null;
    if (_nativeSpeechAvailable) {
      unawaited(
        _nativeChannel.invokeMethod('stopListening').catchError((Object _) {}),
      );
    }
    if (_nativeTtsAvailable) {
      unawaited(
        _nativeChannel.invokeMethod('stopSpeaking').catchError((Object _) {}),
      );
    }
    if (_speechPluginInitialized) _speech.stop();
    _playbackEvents.close();
  }

  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final type = rawEvent['type']?.toString();
    if (type == 'ttsReady') {
      _nativeTtsAvailable = rawEvent['available'] == true;
      _nativeTtsReady = _nativeTtsAvailable;
      _completeNativeTtsReady();
    } else if (type == 'speaking' || type == 'speechResumed') {
      _setPlaybackState(VoicePlaybackState.speaking);
    } else if (type == 'speechPaused') {
      _setPlaybackState(VoicePlaybackState.paused);
    } else if (type == 'speechStopped' ||
        type == 'speechCompleted' ||
        type == 'speechFailed') {
      _setPlaybackState(VoicePlaybackState.idle);
    } else if (type == 'partial') {
      final text = rawEvent['text']?.toString() ?? '';
      if (text.isNotEmpty) _onPartialResult?.call(text);
    } else if (type == 'final') {
      final text = rawEvent['text']?.toString() ?? '';
      _nativeListening = false;
      if (text.isNotEmpty) _nativeResult?.call(text);
      _finishListening();
    } else if (type == 'stopped') {
      _nativeListening = false;
      _finishListening();
    } else if (type == 'error') {
      final code = rawEvent['code']?.toString() ?? '';
      if (!code.startsWith('tts_')) {
        _nativeListening = false;
        _finishListening(
          error:
              rawEvent['message']?.toString() ?? 'Speech recognition failed.',
        );
      }
    }
  }

  void _setPlaybackState(VoicePlaybackState state) {
    if (_playbackState == state) return;
    _playbackState = state;
    if (!_playbackEvents.isClosed) _playbackEvents.add(state);
  }

  void _completeNativeTtsReady() {
    final ready = _nativeTtsReadyCompleter;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  void _finishListening({int? generation, String? error}) {
    if (generation != null && generation != _listenGeneration) return;
    _isListening = false;
    _isHoldToTalkSession = false;
    _holdToTalk = false;
    _nativeListening = false;
    _nativeStartPending = false;
    _usingNativeSpeech = false;
    _pluginListening = false;
    _fallbackRestartTimer?.cancel();
    _fallbackRestartTimer = null;
    final onDone = _nativeDone;
    final onError = _nativeError;
    _nativeResult = null;
    _onPartialResult = null;
    _nativeDone = null;
    _nativeError = null;
    if (error != null) onError?.call(error);
    onDone?.call();
  }
}
