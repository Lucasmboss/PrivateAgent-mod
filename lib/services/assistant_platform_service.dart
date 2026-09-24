import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class GoogleVoiceStatus {
  final bool speechAvailable;
  final bool ttsAvailable;
  final String speechEngine;
  final String ttsEngine;

  const GoogleVoiceStatus({
    this.speechAvailable = false,
    this.ttsAvailable = false,
    this.speechEngine = '',
    this.ttsEngine = '',
  });

  bool get anyAvailable => speechAvailable || ttsAvailable;

  factory GoogleVoiceStatus.fromMap(Map<dynamic, dynamic>? value) {
    return GoogleVoiceStatus(
      speechAvailable: value?['speechAvailable'] == true,
      ttsAvailable: value?['ttsAvailable'] == true,
      speechEngine: value?['speechEngine']?.toString() ?? '',
      ttsEngine: value?['ttsEngine']?.toString() ?? '',
    );
  }
}

/// Android bridge for the system assistant role and assistant invocations.
///
/// Android always requires the user to approve the default-assistant role in
/// system UI; the app cannot silently replace the current assistant.
class AssistantPlatformService {
  static const MethodChannel _channel = MethodChannel(
    'com.privateagent/assistant',
  );
  static const MethodChannel _voiceChannel = MethodChannel(
    'com.privateagent/native_voice',
  );
  static const EventChannel _assistantEvents = EventChannel(
    'com.privateagent/assistant_events',
  );

  static Stream<dynamic> get assistantInvocations {
    if (!_isAndroid) return const Stream<dynamic>.empty();
    return _assistantEvents.receiveBroadcastStream();
  }

  static Future<bool> isDefaultAssistant() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isDefaultAssistant') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> requestDefaultAssistant() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestDefaultAssistant') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> openAssistantSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAssistantSettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> setAssistantOverlayExpanded(bool expanded) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('setAssistantOverlayExpanded', {
            'expanded': expanded,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> dismissAssistant() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('dismissAssistant') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> consumeAssistantInvocation() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeAssistantInvocation') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> isGoogleVoiceAvailable() async {
    final status = await googleVoiceStatus();
    return status.anyAvailable;
  }

  static Future<GoogleVoiceStatus> googleVoiceStatus() async {
    if (!_isAndroid) return const GoogleVoiceStatus();
    try {
      final result = await _voiceChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getGoogleVoiceStatus',
      );
      return GoogleVoiceStatus.fromMap(result);
    } on PlatformException {
      return const GoogleVoiceStatus();
    }
  }

  static bool get _isAndroid => Platform.isAndroid;
}
