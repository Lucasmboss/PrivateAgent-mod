import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shizuku_api/shizuku_api.dart';

class ShizukuCommandResult {
  const ShizukuCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.wasDispatched,
    this.error,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final bool wasDispatched;
  final String? error;

  bool get succeeded => wasDispatched && exitCode == 0;
  bool get uncertain => wasDispatched && exitCode == null;
  bool get knownFailure =>
      wasDispatched && exitCode != null && exitCode != 0;
  bool get mayHavePartialEffects => uncertain || knownFailure;

  factory ShizukuCommandResult.fromPlatformMap(Map<dynamic, dynamic> values) {
    final rawExitCode = values['exitCode'];
    final rawError = values['error'];
    return ShizukuCommandResult(
      stdout: values['stdout'] is String ? values['stdout'] as String : '',
      stderr: values['stderr'] is String ? values['stderr'] as String : '',
      exitCode: rawExitCode is int ? rawExitCode : null,
      wasDispatched: values['wasDispatched'] == true,
      error: rawError is String && rawError.isNotEmpty ? rawError : null,
    );
  }

  String get displayText {
    final sections = <String>[];
    if (stdout.trim().isNotEmpty) sections.add('stdout:\n${stdout.trim()}');
    if (stderr.trim().isNotEmpty) sections.add('stderr:\n${stderr.trim()}');
    if (exitCode != null) sections.add('Exit code: $exitCode');
    if (error != null) sections.add('Command error: $error');
    if (mayHavePartialEffects) {
      sections.add(
        'The command may have had partial effects. Review device state before retrying.',
      );
    }
    if (sections.isEmpty) {
      if (succeeded) return 'Command completed (exit code 0; no output).';
      if (!wasDispatched) return error ?? 'Command was not dispatched.';
      return 'Command returned no output and no exit status. '
          'Its effects may be partial; review device state before retrying.';
    }
    return sections.join('\n');
  }
}

class ShizukuService {
  static const MethodChannel _commandChannel = MethodChannel(
    'com.privateagent/shizuku_commands',
  );

  final ShizukuApi _shizuku = ShizukuApi();
  bool _isAvailable = false;
  bool _hasPermission = false;

  bool get isAvailable => _isAvailable;
  bool get hasPermission => _hasPermission;

  /// Check if Shizuku is installed and running
  Future<bool> checkAvailability() async {
    try {
      _isAvailable = await _shizuku.pingBinder() ?? false;
      if (_isAvailable) {
        _hasPermission = await _shizuku.checkPermission() ?? false;
      } else {
        _hasPermission = false;
      }
      return _isAvailable;
    } catch (e) {
      _isAvailable = false;
      _hasPermission = false;
      return false;
    }
  }

  /// Request Shizuku permission
  Future<bool> requestPermission() async {
    if (!_isAvailable) return false;
    try {
      _hasPermission = await _shizuku.requestPermission() ?? false;
      return _hasPermission;
    } catch (e) {
      return false;
    }
  }

  /// Run an ADB shell command via Shizuku
  Future<String> runCommand(String command) async {
    return (await runCommandWithStatus(command)).displayText;
  }

  /// Run one command and preserve the native process exit status.
  Future<ShizukuCommandResult> runCommandWithStatus(String command) async {
    if (command.trim().isEmpty) {
      return const ShizukuCommandResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        wasDispatched: false,
        error: 'Command is empty.',
      );
    }
    if (!Platform.isAndroid) {
      return const ShizukuCommandResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        wasDispatched: false,
        error: 'Shizuku commands are only available on Android.',
      );
    }
    if (!await checkAvailability()) {
      return const ShizukuCommandResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        wasDispatched: false,
        error: 'Shizuku is not running.',
      );
    }
    if (!_hasPermission && !await requestPermission()) {
      return const ShizukuCommandResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        wasDispatched: false,
        error: 'Shizuku permission was not granted.',
      );
    }
    try {
      final values = await _commandChannel.invokeMapMethod<dynamic, dynamic>(
        'runCommandWithStatus',
        {'command': command},
      );
      if (values == null) {
        return const ShizukuCommandResult(
          stdout: '',
          stderr: '',
          exitCode: null,
          wasDispatched: true,
          error: 'The native command adapter returned no result.',
        );
      }
      return ShizukuCommandResult.fromPlatformMap(values);
    } catch (e) {
      return ShizukuCommandResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        wasDispatched: true,
        error: e.toString(),
      );
    }
  }

  /// Toggle WiFi via Shizuku
  Future<String> toggleWifi(bool enable) async {
    return runCommand('svc wifi ${enable ? 'enable' : 'disable'}');
  }

  /// Toggle Bluetooth via Shizuku
  Future<String> toggleBluetooth(bool enable) async {
    return runCommand(
      'cmd bluetooth_manager ${enable ? 'enable' : 'disable'}',
    );
  }

  /// Force stop an app
  Future<String> forceStopApp(String packageName) async {
    return runCommand('am force-stop $packageName');
  }

  /// Clear app data
  Future<String> clearAppData(String packageName) async {
    return runCommand('pm clear $packageName');
  }
}
